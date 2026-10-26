#!/usr/bin/env bash
#
# 1회: pm2 의 rtsp-api-server 를 OTA 릴리스(/opt/vertical/current)로 돌게 바꾼다. Pi 에서 실행.
#
# OTA 는 릴리스를 /opt/vertical/releases/<tag> 에 풀고 current 링크를 바꾼 뒤 pm2 를 재시작한다.
# 그런데 예전 설치는 pm2 가 ~/rtsp-api-server/dist/main.js 를 직접 돌려 OTA 가 실행 코드를 못 바꿨다.
# 이 스크립트가 pm2 앱을 current 로 옮기고, 예전 설치 디렉터리는 데이터 디렉터리(VERTICAL_DATA —
# config.json·log.txt·media/·youtube/)로 그대로 쓴다. 헬스체크 실패 시 예전 정의로 되돌린다.
#
set -euo pipefail

ROOT="${VERTICAL_ROOT:-/opt/vertical}"
APP="${VERTICAL_PM2_APP:-rtsp-api-server}"
HEALTH="${VERTICAL_HEALTH:-http://127.0.0.1:3000/youtube/status}"
CUR="$ROOT/current"

[ -f "$CUR/dist/main.js" ] || { echo "릴리스 없음: $CUR/dist/main.js — 먼저 update.sh 로 릴리스를 받는다"; exit 1; }

read -r old_exec old_cwd < <(pm2 jlist 2>/dev/null | python3 -c '
import sys, json
app = sys.argv[1]
for p in json.load(sys.stdin):
    if p["name"] == app:
        e = p["pm2_env"]; print(e.get("pm_exec_path", ""), e.get("pm_cwd", "")); break
' "$APP")
[ -n "${old_exec:-}" ] || { echo "pm2 앱 없음: $APP"; exit 1; }

case "$old_exec" in
  "$ROOT"/*) echo "이미 OTA 릴리스로 돌고 있다: $old_exec"; exit 0 ;;
esac

DATA="${VERTICAL_DATA:-$old_cwd}"
[ -f "$DATA/config.json" ] || echo "주의: $DATA/config.json 없음 — 기본 설정으로 뜬다"
echo "pm2 $APP: $old_exec → $CUR/dist/main.js (데이터 $DATA)"

healthy() {
  for _ in $(seq 1 20); do
    sleep 2
    curl -sf --max-time 3 -o /dev/null "$HEALTH" 2>/dev/null && return 0
  done
  return 1
}

pm2 delete "$APP" >/dev/null
VERTICAL_DATA="$DATA" pm2 start "$CUR/dist/main.js" --name "$APP" --cwd "$CUR" >/dev/null

if healthy; then
  pm2 save >/dev/null
  echo "전환 완료 — 이후 OTA 릴리스가 실행 코드를 바꾼다"
else
  echo "헬스체크 실패 — 예전 정의로 되돌림"
  pm2 delete "$APP" >/dev/null 2>&1 || true
  pm2 start "$old_exec" --name "$APP" --cwd "$old_cwd" >/dev/null
  pm2 save >/dev/null
  exit 1
fi
