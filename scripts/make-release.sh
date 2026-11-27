#!/usr/bin/env bash
#
# 개발 저장소(local-rtsp-player)에서 릴리스(manifest v2)를 만들어 vertical-dist 에 발행한다.
#
#   scripts/make-release.sh v1.4.0                       # 빌드 → 검사 → manifest → (확인 후) gh release create
#   scripts/make-release.sh v1.4.0-dryrun --dry-run       # 발행만 빼고 전부. 결과는 남겨 둔 임시 폴더에
#   scripts/make-release.sh v1.4.0-dryrun --dry-run --allow-dirty   # 커밋 안 된 변경이 있어도(시험용)
#
# 릴리스 내용(설계: local-rtsp-player/docs/ops/ota-unified-design.md 4절)
#   manifest.json                         schema 2 — server + apps[] + ios, 파일마다 sha256·size
#   server-<ver>.tar.gz                   rtsp-api-server(커밋된 파일 + 맥에서 빌드한 dist + 운영 node_modules)
#                                         + ota/(update.sh·systemd 유닛 — Pi 가 설치 성공 뒤 업데이터 자신을 갱신)
#   vertical-pad-<versionName>.apk        안드로이드 뷰어 com.sec.vertical_pad (arm64-v8a — apps[], 옛 뷰어가 고르는 기본 APK)
#   vertical-pad-<versionName>-armeabi-v7a.apk  같은 뷰어의 32비트 빌드(-PabiV7, 갤럭시 탭 SM-T583 등) — appVariants[]
#                                         apps[] 에 같은 package 를 두 번 넣으면 옛 뷰어(Manifest.allFiles)가 v7 까지 받고, 옛
#                                         ota_verify.py 가 "package 중복"으로 거부하므로 새 키 appVariants 에 둔다
#                                         (옛 뷰어·송출 앱·Pi update.sh 는 모르고 지나감 — Pi 는 server 만 읽는다).
#                                         APK 마다 "abis"(aapt native-code) — 새 뷰어가 Build.SUPPORTED_ABIS 로 고른다.
#   vertical-publisher-<versionName>.apk  송출 앱 com.vertical.publisher
#   (versionName = 릴리스 번호에서 v 를 뺀 것 — 세 APK 모두 같다. 예 v1.3.6 → 1.3.6. versionCode = git 커밋 수)
# manifest 서명은 없다(사용자 결정). sha256·size 는 깨짐·덜 받음 검사용. APK 는 안드로이드 서명 검사(debug 키)로 보호.
#
# APK 는 assembleDebug 로 만든다 — 현장 기기에 깔린 것과 같은 변형·같은 키(~/.android/debug.keystore).
#   release 변형은 현장에서 한 번도 안 돌려 봤고(GStreamer JNI), debuggable 이 꺼지면 run-as 로 설정 넣는 개발 경로가 막힌다.
#
# 환경변수: SRC_REPO(기본 ~/git/local-rtsp-player) VERTICAL_REPO(기본 bdhwan/vertical-dist)
#           IOS_BUILD(TestFlight 빌드 번호, 모르면 비움 → ios.build=null) CHANNEL(기본 stable)
#           ANDROID_HOME / ANDROID_SDK_ROOT(기본 ~/Library/Android/sdk)
#           OTA_VERSION_CODE=N 또는 --ota-version-code N (dry-run 전용) — 두 APK 를 -PotaVersionCode=N 으로 빌드(업그레이드 시험용).
#           없으면 두 APK 의 versionCode 는 반드시 local-rtsp-player 의 `git rev-list --count HEAD` 여야 한다(다르면 멈춤).
set -euo pipefail

VER=""; DRY=0; ALLOW_DIRTY=0; OTA_VC="${OTA_VERSION_CODE:-}"; WANT_VC_ARG=0
for a in "$@"; do
  if [ "$WANT_VC_ARG" = 1 ]; then OTA_VC="$a"; WANT_VC_ARG=0; continue; fi
  case "$a" in
    --ota-version-code) WANT_VC_ARG=1 ;;
    --ota-version-code=*) OTA_VC="${a#*=}" ;;
    --dry-run) DRY=1 ;;
    --allow-dirty) ALLOW_DIRTY=1 ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    -*) echo "모르는 옵션: $a"; exit 1 ;;
    *) [ -z "$VER" ] && VER="$a" || { echo "버전은 하나만"; exit 1; } ;;
  esac
done
[ -n "$VER" ] || { echo "사용법: make-release.sh v1.4.0 [--dry-run [--allow-dirty] [--ota-version-code N]]"; exit 1; }
[ "$WANT_VC_ARG" = 0 ] || { echo "--ota-version-code 뒤에 숫자"; exit 1; }
if [ -n "$OTA_VC" ]; then
  [[ "$OTA_VC" =~ ^[1-9][0-9]{0,8}$ ]] || { echo "OTA_VERSION_CODE 는 양의 정수"; exit 1; }
  [ "$DRY" = 1 ] || { echo "--ota-version-code(OTA_VERSION_CODE) 는 --dry-run 에서만 쓴다 — 실제 릴리스는 git 커밋 수"; exit 1; }
fi
if [ "$DRY" = 1 ]; then
  # 넷째 숫자(vX.Y.Z.N)는 시험용 — 현장 Pi(sort -V)에서 vX.Y.Z 와 vX.Y.(Z+1) 사이에 놓인다
  [[ "$VER" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+|-[A-Za-z0-9.]+)?$ ]] || { echo "버전 형식: vX.Y.Z[.N|-꼬리표]"; exit 1; }
else
  # 실제 릴리스는 꼬리표 없이 — 뷰어(Versions)와 Pi(sort -V)의 꼬리표 순서가 다를 수 있다
  [[ "$VER" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "실제 릴리스 버전 형식: vX.Y.Z"; exit 1; }
  [ "$ALLOW_DIRTY" = 0 ] || { echo "--allow-dirty 는 --dry-run 에서만 쓴다"; exit 1; }
fi

SRC="${SRC_REPO:-$HOME/git/local-rtsp-player}"
DIST_REPO="${VERTICAL_REPO:-bdhwan/vertical-dist}"
CHANNEL="${CHANNEL:-stable}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
# 현장 기기에 깔린 APK 의 서명 인증서(~/.android/debug.keystore, CN=Android Debug).
# 다른 키로 서명된 APK 는 현장에서 업데이트가 거부되므로 발행 전에 막는다.
APK_CERT_SHA256="7623a8459165d59e8c2686a2cdf0245271a08b9f0b2c6c85b2d251302877ac6b"

echo "== 릴리스 $VER 준비 $([ "$DRY" = 1 ] && echo '(dry-run)') =="

# 0) 작업 트리 — 릴리스 = 커밋 하나. 산출물에 들어가는 경로만 본다.
PATHS=(rtsp-api-server rtsp-android-pad-viewer rtsp-android-publisher android-ota rtsp-ios-viewer/GstCore)
DIRTY=$(git -C "$SRC" status --porcelain -- "${PATHS[@]}")
if [ -n "$DIRTY" ]; then
  if [ "$ALLOW_DIRTY" = 1 ]; then
    echo "  ! 커밋 안 된 변경 $(printf '%s\n' "$DIRTY" | wc -l | tr -d ' ')개 — --allow-dirty 로 계속(dry-run 전용)"
  else
    echo "커밋 안 된 변경이 있다 — 커밋한 뒤 릴리스한다(릴리스 = 커밋 하나):"
    printf '%s\n' "$DIRTY" | head -20
    exit 1
  fi
fi
COMMIT=$(git -C "$SRC" rev-parse --short HEAD)
# 두 APK 의 versionCode 가 돼야 할 값 — build.gradle 의 gitCommitCount() 와 같은 git 커밋 수(시험 덮어쓰기면 그 값)
GIT_COUNT=$(git -C "$SRC" rev-list --count HEAD)
EXPECT_VC="${OTA_VC:-$GIT_COUNT}"
# 커밋 수는 여기서 직접 넘긴다 — build.gradle 의 git 호출은 오래 떠 있는 Gradle 데몬이 다른 환경(샌드박스 등)에서
# 시작됐으면 저장소를 못 보고 1 을 낸다(실제로 dry-run 에서 versionCode 1 이 나왔다).
GRADLE_VC_ARGS=("-PgitCommitCount=$GIT_COUNT")
# versionName = 릴리스 번호(v 를 뺀 것) — 뷰어(64·32비트)·송출 앱이 같은 이름(사용자 결정 11-27). 개발 빌드는 "dev-<versionCode>"
RELEASE_NAME="${VER#v}"
GRADLE_VC_ARGS+=("-PreleaseVersion=$RELEASE_NAME")
[ -n "$OTA_VC" ] && GRADLE_VC_ARGS+=("-PotaVersionCode=$OTA_VC")

if [ "$DRY" = 1 ]; then
  OUT=$(mktemp -d "${TMPDIR:-/tmp}/vertical-release-$VER.XXXXXX")
else
  OUT=$(mktemp -d); trap 'rm -rf "$OUT"' EXIT
fi
STAGE="$OUT/server-$VER"

# 1) 서버: git 에 커밋된 파일만 + 맥에서 빌드한 dist (운영 node_modules 는 비밀정보 검사 뒤 4) 에서)
#    작업 폴더의 실행 중 상태(config.json·log.txt·media/·youtube/)는 들어가지 않는다.
#    현장 Pi 는 인터넷이 없어 npm 을 못 쓴다 — 빌드도 의존성도 여기서 끝낸다.
SERVER="$SRC/rtsp-api-server"
echo "-- 서버 빌드 (커밋 $COMMIT)"
( cd "$SERVER" && npm run build >/dev/null ) || { echo "서버 빌드 실패"; exit 1; }
mkdir -p "$STAGE"
# (맥 openrsync 는 --files-from 이 없어 tar 로 옮긴다)
( cd "$SERVER" && git ls-files -z . | grep -zv '^test/' | tar --null -T - -cf - ) | tar -xf - -C "$STAGE"
rsync -a --exclude '*.tsbuildinfo' "$SERVER/dist/" "$STAGE/dist/"

# 2) 안드로이드 두 앱 (assembleDebug — 머리말 참고)
echo "-- 안드로이드 빌드"
echo "   versionCode 기대값 $EXPECT_VC $([ -n "$OTA_VC" ] && echo "(시험 덮어쓰기 -PotaVersionCode, git 커밋 수 $GIT_COUNT)" || echo "(git 커밋 수)")"
( cd "$SRC/rtsp-android-pad-viewer" && ./gradlew -q "${GRADLE_VC_ARGS[@]}" :app:assembleDebug ) >"$OUT/gradle-pad.log" 2>&1 \
  || { tail -30 "$OUT/gradle-pad.log"; echo "뷰어 APK 빌드 실패"; exit 1; }
# 32비트(armeabi-v7a) 뷰어 — 같은 소스·같은 키, 출력은 app/build-v7/ (app/build.gradle 의 -PabiV7)
( cd "$SRC/rtsp-android-pad-viewer" && ./gradlew -q "${GRADLE_VC_ARGS[@]}" -PabiV7 :app:assembleDebug ) >"$OUT/gradle-pad-v7.log" 2>&1 \
  || { tail -30 "$OUT/gradle-pad-v7.log"; echo "32비트 뷰어 APK 빌드 실패"; exit 1; }
( cd "$SRC/rtsp-android-publisher" && ./gradlew -q "${GRADLE_VC_ARGS[@]}" :vertical:assembleDebug ) >"$OUT/gradle-publisher.log" 2>&1 \
  || { tail -30 "$OUT/gradle-publisher.log"; echo "송출 APK 빌드 실패"; exit 1; }
rm -f "$OUT"/gradle-*.log
PAD_APK="$SRC/rtsp-android-pad-viewer/app/build/outputs/apk/debug/app-debug.apk"
PAD_V7_APK="$SRC/rtsp-android-pad-viewer/app/build-v7/outputs/apk/debug/app-debug.apk"
PUB_APK="$SRC/rtsp-android-publisher/vertical/build/outputs/apk/debug/vertical-debug.apk"

BT=$(ls -d "$SDK"/build-tools/*/ 2>/dev/null | sed 's#/$##' | sort -V \
     | while read -r d; do [ -x "$d/aapt" ] && [ -x "$d/apksigner" ] && echo "$d"; done | tail -1)
[ -n "$BT" ] || { echo "Android SDK build-tools 의 aapt·apksigner 를 못 찾음 ($SDK)"; exit 1; }
AAPT="$BT/aapt"; APKSIGNER="$BT/apksigner"

# $1=apk $2=기대 package $3=파일 이름 접두사 [$4=app|variant(기본 app) $5=기대 ABI(그 ABI 하나만 들어 있어야 함)]
# → $OUT 에 복사하고 apps.tsv 에 한 줄(package file versionCode versionName minSdk kind abis)
APPS_TSV="$OUT/apps.tsv"; : >"$APPS_TSV"
add_apk() {
  local apk="$1" want="$2" prefix="$3" kind="${4:-app}" want_abi="${5:-}" badging pkg vc vn minsdk cert dest abis
  badging=$("$AAPT" dump badging "$apk")
  pkg=$(printf '%s\n' "$badging" | sed -nE "s/^package: name='([^']+)'.*/\1/p")
  vc=$(printf '%s\n' "$badging" | sed -nE "s/^package: .*versionCode='([0-9]+)'.*/\1/p")
  vn=$(printf '%s\n' "$badging" | sed -nE "s/^package: .*versionName='([^']+)'.*/\1/p")
  minsdk=$(printf '%s\n' "$badging" | sed -nE "s/^sdkVersion:'([0-9]+)'.*/\1/p")
  [ "$pkg" = "$want" ] || { echo "  ✗ $apk: package '$pkg' (기대 $want)"; exit 1; }
  [ -n "$vc" ] && [ -n "$vn" ] && [ -n "$minsdk" ] || { echo "  ✗ $apk: aapt 값 추출 실패"; exit 1; }
  # 같은 커밋이면 같은 번호여야 한다 — 1 같은 값이 나오면 build.gradle 의 git 호출이 실패한 것(현장 기기가 업데이트를 거부한다)
  [ "$vc" = "$EXPECT_VC" ] || { echo "  ✗ $pkg: versionCode $vc ≠ 기대값 $EXPECT_VC (git rev-list --count HEAD = $GIT_COUNT)"; exit 1; }
  [ "$vn" = "$RELEASE_NAME" ] || { echo "  ✗ $pkg: versionName $vn ≠ 릴리스 번호 $RELEASE_NAME (build.gradle 의 -PreleaseVersion)"; exit 1; }
  cert=$("$APKSIGNER" verify --print-certs "$apk" 2>/dev/null \
         | sed -nE 's/.*certificate SHA-256 digest: ([0-9a-f]+).*/\1/p' | sort -u)
  [ "$cert" = "$APK_CERT_SHA256" ] || { echo "  ✗ $pkg: 서명 인증서가 현장 debug 키와 다르다 ($cert)"; exit 1; }
  # 네이티브 코드 ABI(없으면 빈 값 = ABI 상관없음)
  abis=$(printf '%s\n' "$badging" | sed -nE "s/^native-code: (.*)/\1/p" | tr -d "'" | tr ' ' ',' | sed 's/,*$//')
  if [ -n "$want_abi" ] && [ "$abis" != "$want_abi" ]; then
    echo "  ✗ $pkg: ABI '$abis' (기대 $want_abi 하나)"; exit 1
  fi
  dest="$prefix-$vn${want_abi:+-$want_abi}.apk"
  [ "$kind" = app ] && [ "$want_abi" = arm64-v8a ] && dest="$prefix-$vn.apk"   # 기본 APK 이름은 그대로(옛 릴리스와 같은 꼴)
  cp "$apk" "$OUT/$dest"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$pkg" "$dest" "$vc" "$vn" "$minsdk" "$kind" "$abis" >>"$APPS_TSV"
  echo "  $pkg  versionCode=$vc versionName=$vn minSdk=$minsdk abis=${abis:-any} ($kind) → $dest"
}
add_apk "$PAD_APK" com.sec.vertical_pad vertical-pad app arm64-v8a
add_apk "$PUB_APK" com.vertical.publisher vertical-publisher
add_apk "$PAD_V7_APK" com.sec.vertical_pad vertical-pad variant armeabi-v7a

# 3) ── 비밀정보 검사 (사람 주의력에 의존하지 않는다) ──────────────
#    서버 파일 + APK 안의 문자열(dex·resources·manifest·assets·네이티브 라이브러리)
echo "-- 비밀정보 검사"
SCAN="$OUT/apk-strings"; mkdir -p "$SCAN"
while IFS=$'\t' read -r pkg file _; do
  x="$OUT/apk-unzip/$file"; mkdir -p "$x"   # 같은 package 의 ABI 별 APK 가 있어 파일 이름으로 나눈다
  unzip -q -o "$OUT/$file" -d "$x"
  # 8비트 + UTF-16LE(바이너리 XML·arsc) 문자열
  find "$x" -type f \( -name '*.dex' -o -name '*.arsc' -o -name 'AndroidManifest.xml' -o -name '*.so' \
       -o -path '*/assets/*' -o -name '*.properties' -o -name '*.json' \) -print0 \
    | while IFS= read -r -d '' f; do
        { strings -a "$f"; strings -a -e l "$f" 2>/dev/null || true; } \
          >"$SCAN/$file.$(printf '%s' "${f#"$x"/}" | tr '/' '_').txt"
      done
  rm -rf "$x"
done <"$APPS_TSV"
rm -rf "$OUT/apk-unzip"
FAIL=0
scan() {  # $1=정규식 $2=설명 [$3=grep --exclude 패턴]
  local hit
  hit=$(grep -rniE ${3:+--exclude="$3"} -e "$1" "$STAGE" "$SCAN" 2>/dev/null | head -5) || true
  if [ -n "$hit" ]; then echo "  ✗ $2"; printf '    %s\n' "$hit" | cut -c1-160; FAIL=1; fi
  return 0   # set -e: 아무것도 안 걸렸을 때 마지막 [ ] 의 1 로 스크립트가 끝나지 않게
}
scan '(WIFI_PASS|wifi[_-]?password|psk)\s*[=:]\s*["'"'"'][^"'"'"']{4,}' "WiFi 자격증명"
scan '[a-z0-9-]+\.ts\.net'                                              "tailnet MagicDNS 주소"
scan '\b100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\.[0-9]+\.[0-9]+'   "tailscale IP"
scan '(api[_-]?key|secret|token)\s*[=:]\s*["'"'"'][A-Za-z0-9_-]{16,}'   "API 키/토큰"
# 개인키: 네이티브 라이브러리(GStreamer 의 OpenSSL/GnuTLS)는 PEM 머리말 상수를 그냥 담고 있어 뺀다
scan '-----BEGIN ([A-Z]+ )?PRIVATE KEY-----'                            "개인키" '*.so.txt'
if [ "$FAIL" = "1" ]; then echo; echo "릴리스 중단 — 위 항목을 제거하거나 환경변수로 옮기세요."; exit 1; fi
echo "  ✓ 통과"
rm -rf "$SCAN"

# 4) 서버 tar
#  a) 운영 node_modules — 깨끗한 복사본(STAGE)에서 npm ci --omit=dev. 현장 Pi(arm64 linux)에서 그대로 돌아야 하므로
#     네이티브 바이너리(.node·.so·.dylib·Mach-O/ELF 실행 파일)가 하나라도 있으면 멈춘다.
echo "-- 운영 의존성 (npm ci --omit=dev)"
( cd "$STAGE" && npm ci --omit=dev --no-audit --no-fund >"$OUT/npm.log" 2>&1 ) \
  || { tail -30 "$OUT/npm.log"; echo "npm ci 실패"; exit 1; }
rm -f "$OUT/npm.log"
NATIVE=$(cd "$STAGE" && {
  find node_modules -type f \( -name '*.node' -o -name '*.so' -o -name '*.so.*' -o -name '*.dylib' \) -print
  find node_modules -type f -perm -u+x -print0 | xargs -0 file 2>/dev/null | grep -E 'Mach-O|ELF' | cut -d: -f1 || true
} | sort -u) || true   # 아무것도 없을 때 grep 의 1 로 set -e 가 끝내지 않게
if [ -n "$NATIVE" ]; then
  echo "  ✗ 네이티브 바이너리가 있다 — 맥에서 만든 node_modules 는 Pi 에서 못 쓴다:"
  printf '    %s\n' $NATIVE | head -30
  exit 1
fi
echo "  ✓ 순수 JS — $(du -sh "$STAGE/node_modules" | cut -f1)"
#  b) 업데이터 자신 — Pi 의 update.sh apply 가 헬스체크 성공 뒤 /opt/vertical/bin·/etc/systemd/system 에 설치한다
mkdir -p "$STAGE/ota/systemd"
install -m 755 "$HERE/update.sh" "$STAGE/ota/update.sh"
install -m 644 "$HERE"/../systemd/*.service "$HERE"/../systemd/*.timer "$STAGE/ota/systemd/"
bash -n "$STAGE/ota/update.sh" || { echo "update.sh 문법 오류"; exit 1; }
#  c) 묶기 — 맥 tar 의 ._* 부속 파일(AppleDouble)·확장 속성은 넣지 않는다
COPYFILE_DISABLE=1 tar --no-xattrs -czf "$OUT/server-$VER.tar.gz" -C "$OUT" "server-$VER" 2>/dev/null \
  || COPYFILE_DISABLE=1 tar -czf "$OUT/server-$VER.tar.gz" -C "$OUT" "server-$VER"
echo "  server-$VER.tar.gz $(du -h "$OUT/server-$VER.tar.gz" | cut -f1)"
rm -rf "$STAGE"

# 5) manifest v2 — 한 번 쓰고 다시 쓰지 않는다(뷰어가 받은 바이트 그대로 카메라에 중계)
echo "-- manifest v2"
DIRTY_FLAG=$([ -n "$DIRTY" ] && echo 1 || echo 0)
python3 - "$OUT" "$VER" "$COMMIT" "$CHANNEL" "${IOS_BUILD:-}" "$DIRTY_FLAG" <<'PY'
import hashlib, json, os, sys, datetime
out, ver, commit, channel, ios_build, dirty = sys.argv[1:7]
def ent(name):
    p = os.path.join(out, name); h = hashlib.sha256()
    with open(p, 'rb') as f:
        for b in iter(lambda: f.read(1 << 20), b''): h.update(b)
    return {"file": name, "sha256": h.hexdigest(), "size": os.path.getsize(p)}
apps, variants = [], []
for line in open(os.path.join(out, "apps.tsv")):
    pkg, file, vc, vn, minsdk, kind, abis = line.rstrip("\n").split("\t")
    e = ent(file)
    a = {"package": pkg, "file": file, "versionCode": int(vc), "versionName": vn,
         "sha256": e["sha256"], "size": e["size"], "minSdk": int(minsdk),
         # 옛 클라이언트는 모르는 필드 — 없으면 arm64-v8a 로 본다, [] = ABI 상관없음
         "abis": [x for x in abis.split(",") if x]}
    (variants if kind == "variant" else apps).append(a)
m = {
    "schema": 2,
    "version": ver,
    "commit": commit,
    "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "channel": channel,
    "server": ent("server-%s.tar.gz" % ver),
    "apps": apps,
    # 같은 앱의 다른 ABI APK(32비트 탭 뷰어 등) — 새 뷰어만 본다. 옛 뷰어·송출 앱·Pi 는 모르고 지나간다
    "appVariants": variants,
    "ios": {"bundle": "com.sec.vertical-pad", "build": ios_build or None},
    # 구형 감시자(com.vertical.watchdog)용 단수 필드 — 그 대상(com.sec.rtsp_payler)은 이 릴리스에 없다
    "app": None,
}
if dirty == "1":
    m["dirty"] = True   # --allow-dirty dry-run: 커밋되지 않은 변경으로 만든 것
with open(os.path.join(out, "manifest.json"), "w", encoding="utf-8") as f:
    json.dump(m, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
rm -f "$APPS_TSV"

# 6) 만든 것 확인(형식 + 파일 크기·sha256)
python3 "$HERE/ota_verify.py" "$OUT/manifest.json" --dir "$OUT" || { echo "manifest 확인 실패"; exit 1; }

echo
cat "$OUT/manifest.json"
echo
if [ "$DRY" = 1 ]; then
  echo "dry-run 완료 — 발행하지 않음. 결과: $OUT"
  ls -la "$OUT"
  exit 0
fi

# 7) 발행 — 매번 사람이 확인
read -r -p "GitHub Release $VER 를 $DIST_REPO 에 발행할까요? [y/N] " yn
[ "$yn" = "y" ] || [ "$yn" = "Y" ] || { echo "발행 안 함"; exit 1; }
echo "-- GitHub Release 발행"
ASSETS=("$OUT/manifest.json" "$OUT/server-$VER.tar.gz")
for f in "$OUT"/*.apk; do ASSETS+=("$f"); done
gh release create "$VER" --repo "$DIST_REPO" --title "$VER" --notes "Vertical $VER (commit $COMMIT)" "${ASSETS[@]}"
echo "완료: $VER"
