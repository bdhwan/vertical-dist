#!/usr/bin/env bash
#
# Vertical OTA 업데이터 — 인터넷이 될 때만, 완전히 받고 검증한 뒤에만 교체한다.
#
# 설계 원칙(불필요한 로직 없음):
#  - 별도 인터넷 체크를 하지 않는다. **릴리스 조회 자체가 인터넷 체크**다.
#    실패 = 현장(인터넷 없음) → 즉시 조용히 종료. 네트워크 왕복 1회로 끝난다.
#  - 버전이 같으면 그 자리에서 끝낸다. 다운로드도, 압축 해제도 하지 않는다.
#  - 실패는 전부 "아무것도 안 한 상태"로 귀결된다. current 는 마지막까지 안 건드린다.
#
set -uo pipefail

REPO="${VERTICAL_REPO:-bdhwan/vertical-dist}"
ROOT="${VERTICAL_ROOT:-/opt/vertical}"
HEALTH="${VERTICAL_HEALTH:-http://127.0.0.1:3000/youtube/status}"
PM2_APP="${VERTICAL_PM2_APP:-rtsp-api-server}"
KEEP=3

RELEASES="$ROOT/releases"
CURRENT="$ROOT/current"
APK_DIR="$ROOT/apk"
LOCK="$ROOT/.update.lock"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { log "ERROR: $*"; exit 1; }

# 중복 실행 차단 — 타이머와 수동 버튼이 겹칠 수 있다.
exec 9>"$LOCK" 2>/dev/null || die "lock 파일 생성 불가: $LOCK"
flock -n 9 || { log "이미 실행 중 — 종료"; exit 0; }

mkdir -p "$RELEASES" "$APK_DIR"

# ── 1. 최신 릴리스 조회 (= 인터넷 체크) ──────────────────────────
# 실패하면 현장이다. 로그만 남기고 정상 종료(0)한다 — 타이머가 실패로 기록하지 않게.
meta=$(curl -sf --max-time 8 \
        -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null) || {
  log "릴리스 조회 실패 — 인터넷 없음(현장)으로 판단, 종료"; exit 0; }

latest=$(printf '%s' "$meta" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("tag_name",""))' 2>/dev/null)
[ -n "$latest" ] || { log "tag_name 없음 — 종료"; exit 0; }

cur=""
[ -L "$CURRENT" ] && cur=$(basename "$(readlink -f "$CURRENT")")

# ── 2. 이미 최신이면 여기서 끝 (다운로드 없음) ───────────────────
if [ "$cur" = "$latest" ]; then
  log "이미 최신 ($latest) — 종료"; exit 0
fi
log "새 버전: ${cur:-없음} → $latest"

# ── 3. 촬영 중이면 다음 기회에 ──────────────────────────────────
# 상태 조회가 안 되면(서버 다운 등) 촬영 중이 아니라고 보고 진행한다.
rec=$(curl -sf --max-time 3 "$HEALTH" 2>/dev/null \
      | python3 -c 'import sys,json;print(json.load(sys.stdin).get("recording",False))' 2>/dev/null)
if [ "$rec" = "True" ]; then
  log "촬영 중 — 건너뜀"; exit 0
fi

# ── 4. manifest 로 자산 URL·해시 확보 ───────────────────────────
url_of() { printf '%s' "$meta" | python3 -c "
import sys,json
n=sys.argv[1]
for a in json.load(sys.stdin).get('assets',[]):
    if a['name']==n: print(a['browser_download_url']); break
" "$1" 2>/dev/null; }

tmp=$(mktemp -d "$ROOT/.dl.XXXXXX") || die "임시 디렉터리 실패"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

murl=$(url_of manifest.json)
[ -n "$murl" ] || { log "manifest.json 자산 없음 — 종료"; exit 0; }
curl -sfL --max-time 20 -o "$tmp/manifest.json" "$murl" || { log "manifest 다운로드 실패 — 종료"; exit 0; }

get() { python3 -c "
import sys,json
d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split('.'): d=d.get(k,{})
print(d if isinstance(d,str) else '')
" "$tmp/manifest.json" "$1" 2>/dev/null; }

srv_file=$(get server.file);  srv_sha=$(get server.sha256)
apk_file=$(get app.file);     apk_sha=$(get app.sha256)

# ── 5. 완전히 받고 해시 검증 (여기까지 실패해도 현재 버전 무영향) ──
fetch() {  # $1=파일명 $2=기대해시
  local u; u=$(url_of "$1") || return 1
  [ -n "$u" ] || return 1
  curl -sfL --max-time 300 -o "$tmp/$1" "$u" || return 1
  [ -n "$2" ] || return 0
  local got; got=$(sha256sum "$tmp/$1" | cut -d' ' -f1)
  [ "$got" = "$2" ] || { log "해시 불일치: $1"; return 1; }
}

[ -n "$srv_file" ] && { fetch "$srv_file" "$srv_sha" || { log "서버 자산 실패 — 종료"; exit 0; }; }
[ -n "$apk_file" ] && { fetch "$apk_file" "$apk_sha" || log "APK 실패(서버는 계속)"; }

# ── 6. 빌드 (실패해도 current 그대로) ───────────────────────────
if [ -n "$srv_file" ]; then
  dest="$RELEASES/$latest"
  rm -rf "$dest"; mkdir -p "$dest"
  tar -xzf "$tmp/$srv_file" -C "$dest" --strip-components=1 2>/dev/null \
    || tar -xzf "$tmp/$srv_file" -C "$dest" || { log "압축 해제 실패"; rm -rf "$dest"; exit 0; }

  log "빌드 중…"
  ( cd "$dest" && npm ci --omit=dev >/dev/null 2>&1 && npm run build >/dev/null 2>&1 ) || {
    log "빌드 실패 — 폐기, 현재 버전 유지"; rm -rf "$dest"; exit 0; }

  # ── 7. 원자적 교체 → 헬스체크 → 실패 시 롤백 ──────────────────
  prev=""
  [ -L "$CURRENT" ] && prev=$(readlink -f "$CURRENT")

  ln -sfn "$dest" "$CURRENT.new" && mv -Tf "$CURRENT.new" "$CURRENT" || die "링크 교체 실패"
  pm2 restart "$PM2_APP" >/dev/null 2>&1

  ok=0
  for _ in $(seq 1 15); do
    sleep 2
    curl -sf --max-time 3 -o /dev/null "$HEALTH" 2>/dev/null && { ok=1; break; }
  done

  if [ "$ok" != "1" ]; then
    log "헬스체크 실패 — 롤백"
    if [ -n "$prev" ] && [ -d "$prev" ]; then
      ln -sfn "$prev" "$CURRENT.new" && mv -Tf "$CURRENT.new" "$CURRENT"
      pm2 restart "$PM2_APP" >/dev/null 2>&1
      log "롤백 완료: $(basename "$prev")"
    else
      log "롤백 대상 없음 (최초 설치)"
    fi
    rm -rf "$dest"
    exit 1
  fi
  log "서버 갱신 완료: $latest"
fi

# ── 8. APK 배치 (폰이 Pi 에서 받아간다) ─────────────────────────
if [ -n "$apk_file" ] && [ -f "$tmp/$apk_file" ]; then
  install -m 644 "$tmp/$apk_file" "$APK_DIR/vertical.apk"
  install -m 644 "$tmp/manifest.json" "$APK_DIR/manifest.json"
  log "APK 배치 완료 ($apk_file)"
fi

# ── 9. 오래된 릴리스 정리 ───────────────────────────────────────
ls -1dt "$RELEASES"/*/ 2>/dev/null | tail -n +$((KEEP+1)) | xargs -r rm -rf
log "완료: $latest"
