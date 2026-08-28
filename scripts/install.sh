#!/usr/bin/env bash
#
# Vertical OTA 1회 설치 — 라즈베리파이에서 실행.
# 기존 pm2 앱을 건드리지 않고, 다음 업데이트부터 OTA 구조로 넘어간다.
#
set -euo pipefail

REPO="${VERTICAL_REPO:-bdhwan/vertical-dist}"
ROOT="${VERTICAL_ROOT:-/opt/vertical}"
USER_NAME="${SUDO_USER:-$(id -un)}"

echo "== Vertical OTA 설치 =="
echo "   저장소: $REPO"
echo "   경로:   $ROOT"

sudo mkdir -p "$ROOT"
sudo chown "$USER_NAME:$USER_NAME" "$ROOT"
mkdir -p "$ROOT"/{releases,apk}

# 업데이터 자체를 clone — 이후 update.sh 가 여기서 실행된다.
if [ -d "$ROOT/repo/.git" ]; then
  git -C "$ROOT/repo" pull --ff-only
else
  git clone --depth 1 "https://github.com/$REPO.git" "$ROOT/repo"
fi
chmod +x "$ROOT/repo/scripts/"*.sh

# systemd 등록 (사용자명 치환)
sudo sed "s/^User=.*/User=$USER_NAME/" "$ROOT/repo/systemd/vertical-update.service" \
  | sudo tee /etc/systemd/system/vertical-update.service >/dev/null
sudo cp "$ROOT/repo/systemd/vertical-update.timer" /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now vertical-update.timer

echo
echo "설치 완료."
echo "  다음 실행: $(systemctl show vertical-update.timer -p NextElapseUSecRealtime --value 2>/dev/null)"
echo "  지금 확인: systemctl start vertical-update.service"
echo "  로그:      tail -f $ROOT/update.log"
