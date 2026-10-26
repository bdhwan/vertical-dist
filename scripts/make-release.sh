#!/usr/bin/env bash
#
# 개발 저장소(local-rtsp-player)에서 릴리스를 만들어 vertical-dist 에 발행한다.
# 개발 저장소에서 실행:  scripts/make-release.sh v1.2.0 [경로/vertical.apk]
#
set -euo pipefail

VER="${1:-}"; APK_SRC="${2:-}"
[ -n "$VER" ] || { echo "사용법: make-release.sh v1.2.0 [app.apk]"; exit 1; }

SRC="${SRC_REPO:-$HOME/git/local-rtsp-player}"
DIST_REPO="${VERTICAL_REPO:-bdhwan/vertical-dist}"
OUT=$(mktemp -d); trap 'rm -rf "$OUT"' EXIT
STAGE="$OUT/server-$VER"

echo "== 릴리스 $VER 준비 =="

# 1) 서버: git 에 커밋된 파일만 + 맥에서 빌드한 dist
#    작업 폴더의 실행 중 상태(config.json·log.txt·media/·youtube/)는 들어가지 않는다.
#    Pi 는 devDependencies(nest CLI·typescript) 없이 npm ci --omit=dev 만 하므로 빌드는 여기서 한다.
SERVER="$SRC/rtsp-api-server"
if [ -n "$(git -C "$SRC" status --porcelain -- rtsp-api-server)" ]; then
  echo "rtsp-api-server 에 커밋 안 된 변경이 있다 — 커밋한 뒤 릴리스한다(릴리스 = 커밋 하나)"; exit 1
fi
COMMIT=$(git -C "$SRC" rev-parse --short HEAD)
echo "-- 빌드 (커밋 $COMMIT)"
( cd "$SERVER" && npm run build >/dev/null ) || { echo "빌드 실패"; exit 1; }
mkdir -p "$STAGE"
# (맥 openrsync 는 --files-from 이 없어 tar 로 옮긴다)
( cd "$SERVER" && git ls-files -z . | grep -zv '^test/' | tar --null -T - -cf - ) | tar -xf - -C "$STAGE"
rsync -a --exclude '*.tsbuildinfo' "$SERVER/dist/" "$STAGE/dist/"

# 2) ── 비밀정보 검사 (사람 주의력에 의존하지 않는다) ──────────────
echo "-- 비밀정보 검사"
FAIL=0
scan() {  # $1=정규식 $2=설명
  local hit
  hit=$(grep -rniE "$1" "$STAGE" 2>/dev/null | head -5) || true
  [ -n "$hit" ] && { echo "  ✗ $2"; printf '    %s\n' "$hit" | cut -c1-120; FAIL=1; }
}
scan '(WIFI_PASS|wifi[_-]?password|psk)\s*[=:]\s*["'"'"'][^"'"'"']{4,}' "WiFi 자격증명"
scan '[a-z0-9-]+\.ts\.net'                                              "tailnet MagicDNS 주소"
scan '\b100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\.[0-9]+\.[0-9]+'   "tailscale IP"
scan '(api[_-]?key|secret|token)\s*[=:]\s*["'"'"'][A-Za-z0-9_-]{16,}'   "API 키/토큰"
[ "$FAIL" = "1" ] && { echo; echo "릴리스 중단 — 위 항목을 제거하거나 환경변수로 옮기세요."; exit 1; }
echo "  ✓ 통과"

# 3) 서버 tar
tar -czf "$OUT/server-$VER.tar.gz" -C "$OUT" "server-$VER"

# 4) manifest 생성
sha() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
APK_JSON='null'
if [ -n "$APK_SRC" ] && [ -f "$APK_SRC" ]; then
  cp "$APK_SRC" "$OUT/vertical-$VER.apk"
  VC=$(aapt dump badging "$OUT/vertical-$VER.apk" 2>/dev/null \
        | grep -oE "versionCode='[0-9]+'" | grep -oE '[0-9]+' | head -1)
  [ -n "$VC" ] || { echo "  ! versionCode 추출 실패(aapt 없음) — 수동 입력 필요"; VC=0; }
  APK_JSON=$(printf '{"file":"vertical-%s.apk","versionCode":%s,"sha256":"%s"}' \
             "$VER" "$VC" "$(sha "$OUT/vertical-$VER.apk")")
fi

cat > "$OUT/manifest.json" <<JSON
{
  "version": "$VER",
  "commit": "$COMMIT",
  "server": { "file": "server-$VER.tar.gz", "sha256": "$(sha "$OUT/server-$VER.tar.gz")" },
  "app": $APK_JSON
}
JSON

# 5) 발행
echo "-- GitHub Release 발행"
gh release create "$VER" --repo "$DIST_REPO" \
   --title "$VER" --notes "Vertical $VER" \
   "$OUT/manifest.json" "$OUT/server-$VER.tar.gz" \
   $([ -f "$OUT/vertical-$VER.apk" ] && echo "$OUT/vertical-$VER.apk")

echo "완료: $VER"
