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
# 유닛이 실행하는 업데이터는 고정 위치에 둔다 — 이후로는 설치에 성공한 릴리스의 ota/ 가 갱신한다(GitHub 안 감).
mkdir -p "$ROOT/bin"
install -m 755 "$ROOT/repo/scripts/update.sh" "$ROOT/bin/update.sh"

# systemd 등록 (사용자명 치환)
#  vertical-update.service = update.sh stage (뷰어 알림·타이머 — 받기만)
#  vertical-apply.service  = update.sh apply (뷰어 [설치] 버튼 → 서버 /update/install 이 띄운다)
for u in vertical-update.service vertical-apply.service; do
  sudo sed "s/^User=.*/User=$USER_NAME/" "$ROOT/repo/systemd/$u" | sudo tee "/etc/systemd/system/$u" >/dev/null
done
sudo cp "$ROOT/repo/systemd/vertical-update.timer" /etc/systemd/system/
# 예전 GitHub PAT 방식 APK 스테이징(local-rtsp-player tools/)이 같은 이름으로 깔려 있었다면 위에서 덮어썼다.
# 그 방식은 이제 vertical-apk-legacy.* 이름을 쓴다.
sudo systemctl daemon-reload
sudo systemctl enable --now vertical-update.timer

echo
echo "설치 완료."
echo "  다음 실행: $(systemctl show vertical-update.timer -p NextElapseUSecRealtime --value 2>/dev/null)"
echo "  받기:      systemctl start vertical-update.service   (받을 곳: $ROOT/ota-source — 뷰어 알림이 적는다)"
echo "  상태:      $ROOT/bin/update.sh status"
echo "  로그:      tail -f $ROOT/update.log"
