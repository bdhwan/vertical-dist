#!/usr/bin/env bash
#
# Vertical OTA 업데이터 v2 (라즈베리파이) — 현장 LAN 의 뷰어에서만 받는다. GitHub 경로는 없다.
# 설계: local-rtsp-player/docs/ops/ota-unified-design.md (개정 2)
#
#   update.sh stage   받기·확인·풀기·의존성까지(돌고 있는 서버에 영향 없음) → 상태 ready
#   update.sh apply   current 링크 교체 → pm2 재시작 → 헬스체크 → 실패 시 롤백
#                     → 성공하면 릴리스의 ota/(update.sh·systemd 유닛)로 업데이터 자신도 갱신
#   update.sh status  상태 파일 출력
#
# 원칙
#  - 받기는 자동(뷰어 알림 /update/notify → vertical-update.service, 그리고 1시간 타이머).
#  - 설치는 사람만(뷰어 [설치] → /update/install → vertical-apply.service). stage 는 절대 교체하지 않는다.
#  - 받을 곳: $ROOT/ota-source 한 줄(뷰어 주소, 예: http://<뷰어IP>:3100/ota/). 없으면 할 일 없음.
#  - manifest.json 의 server.size·sha256 으로 덜 받힘·깨짐만 확인한다(서명 검증 없음 — 사용자 결정).
#  - 버전: sort -V 로 지금보다 "엄격히 높을" 때만. 다운그레이드·같은 버전 재설치 없음.
#  - 진행 상태는 $ROOT/ota-state.json 에 쓴다 → 서버 /check 의 ota.
#    state: idle | downloading:N | verifying | extracting | installing | ready | restarting | health | failed:<사유>
#
set -uo pipefail

ROOT="${VERTICAL_ROOT:-/opt/vertical}"
PM2_APP="${VERTICAL_PM2_APP:-rtsp-api-server}"
CHECK_URL="${VERTICAL_CHECK_URL:-http://127.0.0.1:3000/check}"
HEALTH_SECS="${VERTICAL_HEALTH_SECS:-30}"
KEEP="${VERTICAL_KEEP:-3}"

BIN="$ROOT/bin/update.sh"   # 유닛이 실행하는 고정 위치(git clone 이 아니다 — 릴리스가 갱신한다)
RELEASES="$ROOT/releases"
CURRENT="$ROOT/current"
STATE="$ROOT/ota-state.json"
SOURCE_FILE="$ROOT/ota-source"
NOTIFY_FILE="$ROOT/ota-notify.json"
DL="$ROOT/.ota-dl"
LOCK="$ROOT/.update.lock"

log() { printf '[%s] %s %s\n' "$(date '+%F %T')" "${MODE:-}" "$*"; }

# ── 상태 파일 ─────────────────────────────────────────────────────
# set_state key=value ...  — 기존 내용에 합쳐 원자적으로 쓴다. 값 null 은 JSON null, json:… 은 JSON 그대로.
set_state() {
  python3 -I - "$STATE" "$$" "$@" <<'PY' 2>/dev/null || true
import json, os, sys, time
f, pid, kv = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
try:
    d = json.load(open(f))
    if not isinstance(d, dict): d = {}
except Exception:
    d = {}
for a in kv:
    k, _, v = a.partition("=")
    if v == "null": d[k] = None
    elif v.startswith("json:"): d[k] = json.loads(v[5:])
    else: d[k] = v
d["pid"] = pid
d["updated_at"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
tmp = f + ".tmp"
with open(tmp, "w") as o:
    json.dump(d, o, ensure_ascii=False); o.write("\n")
os.replace(tmp, f)
PY
}
get_state() {  # $1=키 — 없으면 빈 문자열
  python3 -I -c '
import json,sys
try: v=json.load(open(sys.argv[1])).get(sys.argv[2])
except Exception: v=None
print("" if v is None else v)' "$STATE" "$1" 2>/dev/null
}

cur_version() { [ -L "$CURRENT" ] && basename "$(readlink -f "$CURRENT")" || true; }

# a 가 b 보다 엄격히 높은가(sort -V). b 가 비었으면 참.
newer() {
  [ -n "$1" ] || return 1
  [ -n "$2" ] || return 0
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | tail -n1)" = "$1" ]
}

fail() {  # $1=사유(짧은 영문 토큰) $2=로그 메시지
  log "실패: $1 — ${2:-}"
  set_state "state=failed:$1" "message=${2:-$1}"
  exit 1
}

lock_or() {  # $1=잠금 실패 시 종료 코드
  exec 9>"$LOCK" 2>/dev/null || { log "lock 파일 생성 불가: $LOCK"; exit 1; }
  flock -n 9 || { log "다른 update.sh 가 실행 중 — 종료"; exit "$1"; }
}

# ── stage ─────────────────────────────────────────────────────────
download() {  # $1=URL $2=받을 파일 $3=기대 크기 — 이어받기, 1초마다 진행률
  local url="$1" out="$2" size="$3" tries=0 rc pid have pct
  while :; do
    tries=$((tries+1))
    have=$(stat -c %s "$out" 2>/dev/null || echo 0)
    [ "$have" -gt "$size" ] && { rm -f "$out"; have=0; }
    [ "$have" -eq "$size" ] && return 0
    curl -sfL --connect-timeout 8 --speed-time 30 --speed-limit 1024 --max-time 1800 \
         -C - -o "$out" "$url" &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
      have=$(stat -c %s "$out" 2>/dev/null || echo 0)
      pct=$(( size > 0 ? have * 100 / size : 0 )); [ "$pct" -gt 99 ] && pct=99
      set_state "state=downloading:$pct"
      sleep 1
    done
    wait "$pid"; rc=$?
    [ "$rc" -eq 0 ] && return 0
    # 33 = 서버가 Range 를 모른다 → 처음부터
    [ "$rc" -eq 33 ] && rm -f "$out"
    log "다운로드 끊김(curl $rc, 시도 $tries) — 이어받기"
    [ "$tries" -ge 4 ] && return "$rc"
    sleep $((tries * 3))
  done
}

stage_once() {
  local src cur ver file sha size force rejected staged stg top curdir
  # tmp 는 local 이 아니다 — EXIT trap 이 함수가 끝난 뒤(서브셸 종료 때) 읽는다.
  src=$(head -n1 "$SOURCE_FILE" 2>/dev/null | tr -d ' \t\r\n')
  if [ -z "$src" ]; then
    log "받을 곳(ota-source) 없음 — 뷰어 알림 대기"
    set_state "state=idle" "source=null" "message=null"
    return 0
  fi
  case "$src" in http://*|https://*) ;; *) fail bad_source "ota-source 형식: $src" ;; esac
  case "$src" in */) ;; *) src="$src/" ;; esac
  force=$(python3 -I -c 'import json,sys
try: print("1" if json.load(open(sys.argv[1])).get("force") is True else "")
except Exception: print("")' "$NOTIFY_FILE" 2>/dev/null)
  cur=$(cur_version)
  set_state "source=$src" "version=${cur:-null}"

  tmp=$(mktemp -d "$ROOT/.ota-m.XXXXXX") || fail io "임시 디렉터리 실패"
  trap 'rm -rf "$tmp"' EXIT   # stage_once 는 서브셸에서 돈다(fail 의 exit 도 여기서 정리)

  # 1) manifest
  if ! curl -sf --connect-timeout 5 --max-time 20 -o "$tmp/manifest.json" "${src}manifest.json"; then
    # 이미 받아 둔 버전이 있으면 그대로 설치 대기(뷰어가 떠났을 뿐 — 설치에는 뷰어가 필요 없다)
    staged=$(get_state staged)
    if [ -n "$staged" ] && [ -f "$RELEASES/$staged/.ota-ready" ] && newer "$staged" "$cur"; then
      log "뷰어에 닿지 않음($src) — 받아 둔 $staged 설치 대기 유지"
      set_state "state=ready"; return 0
    fi
    fail unreachable "뷰어에 닿지 않거나 manifest 없음: $src"
  fi

  # 2) 필요한 값만
  read -r ver file sha size < <(python3 -I -c '
import json, sys
m = json.load(open(sys.argv[1]))
s = m.get("server") or {}
print(m.get("version", "") or "-", s.get("file", "") or "-", s.get("sha256", "") or "-", s.get("size", 0) or 0)' \
    "$tmp/manifest.json" 2>/dev/null)
  [[ "${ver:-}" =~ ^v?[0-9][0-9A-Za-z._-]{0,40}$ ]] || fail manifest "version 형식: ${ver:-}"
  [ "${file:--}" != "-" ] || { log "manifest 에 server 없음 ($ver) — 할 일 없음"; set_state "state=idle"; return 0; }
  [[ "$file" =~ ^[A-Za-z0-9._-]+$ ]] || fail manifest "server.file 형식: $file"
  [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || fail manifest "server.sha256 형식"
  [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -gt 0 ] || fail manifest "server.size 없음"

  # 3) 버전 — 엄격히 높을 때만
  if ! newer "$ver" "$cur"; then
    log "최신 (지금 ${cur:-없음}, 뷰어 $ver) — 할 일 없음"
    set_state "state=idle" "staged=null" "available=$ver" "message=null"
    return 0
  fi
  rejected=$(get_state rejected)
  if [ "$ver" = "$rejected" ] && [ -z "$force" ]; then
    log "$ver 는 설치 후 헬스체크에 실패해 롤백한 버전 — 건너뜀(force 알림이면 다시 받는다)"
    set_state "state=failed:rolled_back" "available=$ver"
    return 0
  fi
  staged=$(get_state staged)
  if [ "$staged" = "$ver" ] && [ -f "$RELEASES/$ver/.ota-ready" ]; then
    log "$ver 이미 받아 둠 — 설치 대기"
    set_state "state=ready" "staged=$ver" "available=$ver" "message=null"
    return 0
  fi
  log "새 버전 받기: ${cur:-없음} → $ver ($src)"
  set_state "available=$ver" "message=null"

  # 4) 받기(이어받기) → size·sha256(덜 받힘·깨짐 확인)
  mkdir -p "$DL"
  find "$DL" -mindepth 1 -maxdepth 1 ! -name "$file" -exec rm -rf {} + 2>/dev/null
  set_state "state=downloading:0"
  download "${src}files/$file" "$DL/$file" "$size" || fail download "server tar 받기 실패: $file"
  set_state "state=verifying"
  [ "$(stat -c %s "$DL/$file")" = "$size" ] || { rm -f "$DL/$file"; fail size "크기 불일치: $file"; }
  [ "$(sha256sum "$DL/$file" | cut -d' ' -f1)" = "$sha" ] || { rm -f "$DL/$file"; fail sha256 "해시 불일치: $file"; }

  # 5) 풀기 — releases/.staging-<ver> 에 풀고 끝까지 성공하면 releases/<ver> 로 옮긴다
  set_state "state=extracting"
  mkdir -p "$RELEASES"
  stg="$RELEASES/.staging-$ver"
  rm -rf "$stg"; mkdir -p "$stg"
  # 최상위가 디렉터리 하나(server-<ver>/)면 벗긴다. 맥 tar 의 ._* 부속 파일은 버린다.
  # (목록은 파일로 한 번만 — `tar -t | grep -q` 는 큰 tar 에서 SIGPIPE 로 pipefail 에 걸린다)
  tar -tzf "$DL/$file" 2>/dev/null | sed 's#^\./##' | grep -v '^$' | grep -v '\(^\|/\)\._' >"$tmp/list" || true
  top=$(cut -d/ -f1 "$tmp/list" | sort -u)
  [ -n "$top" ] || { rm -rf "$stg"; rm -f "$DL/$file"; fail extract "tar 가 비었거나 깨졌다"; }
  if [ "$(printf '%s\n' "$top" | wc -l)" -eq 1 ] && grep -q "^$top/." "$tmp/list"; then
    tar -xzf "$DL/$file" -C "$stg" --strip-components=1 --exclude='._*' --no-same-owner \
      || { rm -rf "$stg"; fail extract "압축 해제 실패"; }
  else
    tar -xzf "$DL/$file" -C "$stg" --exclude='._*' --no-same-owner \
      || { rm -rf "$stg"; fail extract "압축 해제 실패"; }
  fi

  # 6) 실행 의존성 — 현장은 인터넷이 없다. 가능한 것부터:
  #    a) tar 에 node_modules 가 들어 있다 → 그대로
  #    b) package-lock.json 이 지금 릴리스와 같다 → 지금 릴리스의 node_modules 복사
  #    c) npm ci --omit=dev (npm 캐시 우선 — 인터넷이 있거나 캐시에 다 있으면 된다)
  #    d) 예전 소스만 있는 릴리스(dist 없음) → 빌드(devDependencies 필요 = 인터넷 필요)
  set_state "state=installing"
  curdir=$(readlink -f "$CURRENT" 2>/dev/null || true)
  if [ -d "$stg/node_modules" ] && [ -f "$stg/dist/main.js" ]; then
    log "의존성: 릴리스에 포함"
  elif [ -f "$stg/dist/main.js" ] && [ -n "$curdir" ] && [ -d "$curdir/node_modules" ] \
       && cmp -s "$stg/package-lock.json" "$curdir/package-lock.json"; then
    log "의존성: lock 이 같아 지금 릴리스에서 복사"
    cp -a "$curdir/node_modules" "$stg/node_modules" || { rm -rf "$stg"; fail deps "node_modules 복사 실패"; }
  elif [ -f "$stg/dist/main.js" ]; then
    log "의존성: npm ci --omit=dev"
    ( cd "$stg" && timeout 900 npm ci --omit=dev --prefer-offline --no-audit --no-fund >/dev/null 2>&1 ) \
      || { rm -rf "$stg"; fail deps "npm ci 실패(인터넷·npm 캐시 없음?)"; }
  else
    log "빌드(소스만 있는 릴리스)"
    ( cd "$stg" && timeout 1500 npm ci --no-audit --no-fund >/dev/null 2>&1 && npm run build >/dev/null 2>&1 \
        && npm prune --omit=dev >/dev/null 2>&1 ) || { rm -rf "$stg"; fail build "빌드 실패"; }
  fi
  [ -f "$stg/dist/main.js" ] || { rm -rf "$stg"; fail build "dist/main.js 없음"; }
  ( cd "$stg" && timeout 30 node -e 'require("@nestjs/core"); require("@nestjs/common")' >/dev/null 2>&1 ) \
    || { rm -rf "$stg"; fail deps "의존성 로드 확인 실패"; }

  # 7) 준비 완료 표식 → releases/<ver>
  cp "$tmp/manifest.json" "$stg/.ota-manifest.json"
  printf '{"version":"%s","sha256":"%s","source":"%s","staged_at":"%s"}\n' \
    "$ver" "$sha" "$src" "$(date '+%FT%T%z')" >"$stg/.ota-ready"
  [ "$RELEASES/$ver" = "$curdir" ] && fail io "current 와 같은 디렉터리"   # newer() 로 불가능 — 방어
  rm -rf "${RELEASES:?}/$ver"
  mv -T "$stg" "$RELEASES/$ver" || fail io "releases/$ver 로 옮기기 실패"
  # 이전에 받아 두고 설치하지 않은 버전은 지운다(current 는 건드리지 않는다)
  if [ -n "$staged" ] && [ "$staged" != "$ver" ] && [ -f "$RELEASES/$staged/.ota-ready" ] \
     && [ "$(readlink -f "$RELEASES/$staged")" != "$curdir" ]; then
    rm -rf "${RELEASES:?}/$staged"
  fi
  rm -f "$DL/$file"
  set_state "state=ready" "staged=$ver" "message=null"
  log "받기 완료: $ver — 뷰어에서 [설치]를 누르면 교체한다"
}

cmd_stage() {
  lock_or 0
  mkdir -p "$RELEASES"
  # 받는 중에 새 알림이 오면(ota-source·ota-notify.json 이 바뀜) 한 번 더 — 최대 3회.
  # (서버가 systemctl start 를 다시 불러도 이미 도는 oneshot 에 합쳐질 뿐이라 여기서 챙긴다)
  local n=0 before after rc
  while :; do
    before=$(cat "$SOURCE_FILE" "$NOTIFY_FILE" 2>/dev/null)
    ( stage_once ); rc=$?
    after=$(cat "$SOURCE_FILE" "$NOTIFY_FILE" 2>/dev/null)
    n=$((n+1))
    if [ "$before" != "$after" ] && [ "$n" -lt 3 ]; then log "도중에 새 알림 — 다시"; continue; fi
    return $rc
  done
}

# ── apply ─────────────────────────────────────────────────────────
check_json() {  # stdin=/check 응답, $1=1 이면 streaming:true 까지 요구
  python3 -I -c '
import json, sys
d = json.load(sys.stdin)
sys.exit(0 if (sys.argv[1] != "1" or d.get("streaming") is True) else 1)' "$1" 2>/dev/null
}

# 교체 직전에 스트리밍 중이었나 — 카메라가 빠져 있던 장비에서 정상 빌드를 롤백하지 않게
was_streaming() { curl -sf --max-time 3 "$CHECK_URL" 2>/dev/null | check_json 1; }

healthy() {  # $1=기대 릴리스 디렉터리 $2=1 이면 streaming:true 요구 — 그 디렉터리에서 돌고 /check 200
  local want="$1" need="${2:-0}" i pid cwd
  for i in $(seq 1 "$HEALTH_SECS"); do
    sleep 1
    pid=$(pm2 pid "$PM2_APP" 2>/dev/null | tail -n1)
    cwd=""
    [ -n "$pid" ] && [ "$pid" != "0" ] && cwd=$(readlink -f "/proc/$pid/cwd" 2>/dev/null)
    [ "$cwd" = "$want" ] || continue
    curl -sf --max-time 3 "$CHECK_URL" 2>/dev/null | check_json "$need" && return 0
  done
  return 1
}

# 설치에 성공한 릴리스의 ota/ 로 업데이터 자신을 갱신한다. 헬스체크 성공 뒤에만 부른다.
#  - 유닛: User= 를 지금 사용자로 바꿔 /etc/systemd/system 과 다르면 설치 → daemon-reload
#  - update.sh: 맨 마지막에 임시 파일 → mv(원자적). 돌고 있는 bash 는 열어 둔 옛 파일을 계속 읽는다.
self_update() {  # $1=릴리스 디렉터리
  local src="$1/ota" u name tmpu changed=0
  [ -d "$src" ] || { log "릴리스에 ota/ 없음 — 업데이터 그대로"; return 0; }
  for u in "$src"/systemd/*.service "$src"/systemd/*.timer; do
    [ -f "$u" ] || continue
    name=$(basename "$u")
    tmpu=$(mktemp) || continue
    sed "s/^User=.*/User=$(id -un)/" "$u" >"$tmpu"
    if ! cmp -s "$tmpu" "/etc/systemd/system/$name"; then
      if sudo -n install -m 644 "$tmpu" "/etc/systemd/system/$name"; then
        changed=1; log "유닛 갱신: $name"
      else
        log "유닛 갱신 실패(sudo): $name"
      fi
    fi
    rm -f "$tmpu"
  done
  if [ "$changed" = 1 ]; then
    sudo -n systemctl daemon-reload || log "daemon-reload 실패"
    if systemctl is-enabled -q vertical-update.timer 2>/dev/null; then
      sudo -n systemctl restart vertical-update.timer || true
    fi
  fi
  if [ -f "$src/update.sh" ] && ! cmp -s "$src/update.sh" "$BIN"; then
    if ! bash -n "$src/update.sh"; then log "새 update.sh 문법 오류 — 그대로"; return 0; fi
    mkdir -p "$(dirname "$BIN")"
    [ -f "$BIN" ] && cp -p "$BIN" "$BIN.prev"
    cp "$src/update.sh" "$BIN.new.$$" && chmod 755 "$BIN.new.$$" && mv -f "$BIN.new.$$" "$BIN" \
      && log "업데이터 갱신: $BIN" || { rm -f "$BIN.new.$$"; log "업데이터 갱신 실패"; }
  fi
}

switch_to() {  # $1=릴리스 디렉터리 — 원자적 링크 교체
  ln -sfn "$1" "$CURRENT.new" && mv -Tf "$CURRENT.new" "$CURRENT"
}

cmd_apply() {
  lock_or 3
  local staged cur dest prev t0 d need
  staged=$(get_state staged); cur=$(cur_version)
  dest="$RELEASES/$staged"
  if [ -z "$staged" ] || [ ! -f "$dest/.ota-ready" ]; then
    log "설치할 버전 없음(staged=${staged:-없음})"; exit 2
  fi
  if ! newer "$staged" "$cur"; then
    log "$staged 는 지금($cur)보다 높지 않다 — 설치 안 함"; set_state "staged=null" "state=idle"; exit 2
  fi
  prev=$(readlink -f "$CURRENT" 2>/dev/null || true)
  need=0; was_streaming && need=1
  t0=$(date +%s)
  log "설치: ${cur:-없음} → $staged (헬스체크: /check 200$([ "$need" = 1 ] && echo ' + streaming'))"
  set_state "state=restarting" "message=null"
  switch_to "$dest" || fail switch "링크 교체 실패"
  pm2 restart "$PM2_APP" --update-env >/dev/null 2>&1 || log "pm2 restart 오류(헬스체크로 판단)"
  set_state "state=health"
  if healthy "$dest" "$need"; then
    pm2 save >/dev/null 2>&1 || true
    log "설치 완료: $staged ($(( $(date +%s) - t0 ))s)"
    set_state "state=idle" "version=$staged" "staged=null" "rejected=null" "message=null" \
      "last=json:{\"result\":\"ok\",\"from\":\"${cur}\",\"to\":\"${staged}\",\"at\":\"$(date '+%FT%T%z')\"}"
    # 최근 $KEEP 개만 — 지금·직전 릴리스는 항상 남긴다
    ls -1dt "$RELEASES"/*/ 2>/dev/null | sed 's#/$##' | tail -n +$((KEEP+1)) | while read -r d; do
      if [ "$(readlink -f "$d")" = "$dest" ] || [ "$(readlink -f "$d")" = "$prev" ]; then continue; fi
      log "오래된 릴리스 정리: $(basename "$d")"; rm -rf "$d"
    done
    self_update "$dest"   # 맨 마지막(update.sh 교체가 이 실행의 마지막 동작)
    exit 0
  fi
  log "헬스체크 실패(${HEALTH_SECS}s) — 롤백"
  if [ -n "$prev" ] && [ -d "$prev" ]; then
    switch_to "$prev"
    pm2 restart "$PM2_APP" --update-env >/dev/null 2>&1
    if healthy "$prev" "$need"; then log "롤백 완료: $(basename "$prev")"; else log "롤백 후에도 헬스체크 실패 — 확인 필요"; fi
  else
    log "롤백 대상 없음"
  fi
  rm -rf "${RELEASES:?}/$staged"
  set_state "state=failed:rolled_back" "version=$(cur_version)" "staged=null" "rejected=$staged" \
    "message=$staged 헬스체크 실패 — $(basename "${prev:-?}") 로 되돌림" \
    "last=json:{\"result\":\"rolled_back\",\"from\":\"${cur}\",\"to\":\"${staged}\",\"at\":\"$(date '+%FT%T%z')\"}"
  exit 1
}

MODE="${1:-stage}"
case "$MODE" in
  stage) cmd_stage ;;
  apply) cmd_apply ;;
  status) cat "$STATE" 2>/dev/null || echo '{}' ;;
  *) echo "사용법: update.sh stage|apply|status" >&2; exit 64 ;;
esac
