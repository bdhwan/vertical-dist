# vertical-dist

**Vertical 현장 장비 OTA 배포 저장소.**

라즈베리파이 카메라 서버(`rtsp-api-server`)와 안드로이드 뷰어 앱(**Vertical**)을
GitHub Releases 로 배포한다. 인터넷에서 받는 것은 뷰어뿐이고, 현장의 카메라(Pi·송출 폰)는 같은 LAN 의 뷰어에서 받는다.

## Pi 업데이트 (통합 OTA v2)

설계: `local-rtsp-player/docs/ops/ota-unified-design.md`(개정 2). **Pi 는 현장 LAN 의 뷰어에서만 받는다 — GitHub 에 직접 가지 않는다.**
인터넷(GitHub Release)에서 받아 오는 것은 뷰어(`http://<뷰어>:3100/ota/`)의 일이다.

```
뷰어 ──POST /update/notify {"source":"http://<뷰어>:3100/ota/","version":"v1.4.0"}──▶ Pi 서버(:3000)
                                  │  /opt/vertical/ota-source 에 적고 vertical-update.service 기동
                                  ▼
          update.sh stage   manifest.json → 버전 비교(sort -V, 엄격히 높을 때만) → server tar 이어받기
                            → size·sha256 → releases/<ver> 에 풀기 → 의존성 → 상태 ready   (서버 무영향)
뷰어 [설치] ──POST /update/install──▶ vertical-apply.service
          update.sh apply   current 링크 원자 교체 → pm2 restart → 30초 안에 새 릴리스에서 돌고 /check 200
                            (+ 교체 직전에 스트리밍 중이었으면 streaming:true)
                            → 실패면 직전 릴리스로 롤백(failed:rolled_back)
                            → 성공이면 최근 3개만 보관 + 릴리스의 ota/ 로 업데이터 자신 갱신
```

| 언제 | 무엇 |
|---|---|
| 뷰어 알림(`/update/notify`) | stage — **받기만**, 설치 안 함 |
| `vertical-update.timer` 부팅 2분 뒤 + 1시간마다 | 저장된 뷰어 주소로 stage 다시(새 것 없으면 바로 끝, 받을 곳이 없으면 아무것도 안 함) |
| 뷰어 [설치](`/update/install`) | apply — 사람이 누를 때만 |

- 진행 상태: `/opt/vertical/ota-state.json` → 서버 `GET /check` 의 `ota`
  `{"version":"v1.3.3","state":"idle|downloading:42|verifying|extracting|installing|ready|restarting|health|failed:<사유>","staged":"v1.4.0"|null,"source":"…"|null}`
  실패 사유: `unreachable`·`manifest`·`download`·`size`·`sha256`·`extract`·`deps`·`build`·`rolled_back`·`interrupted`(서버가 판단: 진행 중인데 프로세스 없음).
- 롤백된 버전은 기억해 두고(`rejected`) 타이머가 다시 받지 않는다. 뷰어가 `"force":true` 로 알리면 다시 받는다.
- 서명 검증은 없다(사용자 결정). sha256·size 는 덜 받힘·깨짐 확인용이다.
- 의존성(현장은 인터넷 없음): `make-release.sh` 가 운영 `node_modules` 를 tar 에 넣는다(순수 JS 만 — 네이티브 바이너리가 있으면 릴리스가 멈춘다).
  Pi 는 그대로 쓴다. 예전 tar(node_modules 없음)는 lock 이 같으면 지금 릴리스에서 복사, 아니면 `npm ci --omit=dev --prefer-offline`.
- 업데이터 위치: 유닛은 `/opt/vertical/bin/update.sh` 를 실행한다(git clone 이 아님). 서버 tar 의 `ota/`(update.sh·systemd 유닛)를
  apply 가 헬스체크 성공 뒤 설치한다 — 유닛이 바뀌었으면 `/etc/systemd/system` + daemon-reload, update.sh 는 맨 마지막에 임시 파일 → mv.
  직전 것은 `update.sh.prev`. **stage 자체가 깨진 update.sh 는 릴리스로 고칠 수 없다**(받기가 안 되므로) — 손으로 넣는다.
- apply 를 서버 자식 프로세스가 아니라 systemd 유닛으로 띄우는 이유: apply 가 pm2 로 그 서버를 재시작하는데 pm2 는 프로세스 트리째 죽인다.

```bash
/opt/vertical/bin/update.sh status                     # 상태
sudo systemctl start vertical-update.service           # 받기(ota-source 필요)
sudo systemctl start vertical-apply.service            # 받아 둔 것 설치(뷰어 [설치]와 같음)
tail -f /opt/vertical/update.log
```

### 뷰어(:3100) 계약

`GET /ota/manifest.json`, `GET /ota/files/<file>`(Range 지원). Pi 는 manifest 의 `version`, `server{file,sha256,size}` 만 본다.

## 설치 (Pi, 1회)

```bash
curl -fsSL https://raw.githubusercontent.com/bdhwan/vertical-dist/main/scripts/install.sh | bash
```

### 예전 설치에서 넘어올 때 (Pi, 1회)

예전 설치는 pm2 가 `~/rtsp-api-server/dist/main.js` 를 직접 돌려서 OTA 가 실행 코드를 바꾸지 못한다.
릴리스를 한 번 받은 뒤(`systemctl start vertical-update.service`) pm2 를 릴리스로 옮긴다.
예전 설치 디렉터리는 데이터 디렉터리(`VERTICAL_DATA` — config.json·log.txt·media/·youtube/)로 그대로 쓴다.

```bash
/opt/vertical/repo/scripts/adopt-pm2.sh
```

## 릴리스 구성

각 릴리스(`v1.4.0`)에 다음 자산이 올라간다. 만들기: 개발 맥에서 `scripts/make-release.sh v1.4.0`
(먼저 `--dry-run` 으로 확인 — 발행만 빼고 전부 하고 결과 폴더를 남긴다).

| 자산 | 내용 |
|---|---|
| `manifest.json` | schema 2 — `version`·`commit`·`server`·`apps[]`(package·versionCode·versionName·minSdk)·`ios`, 파일마다 `sha256`·`size` |
| `server-<ver>.tar.gz` | Pi 서버 — git 에 커밋된 파일 + 맥에서 빌드한 `dist/` + 운영 `node_modules`(순수 JS) + `ota/`(update.sh·systemd 유닛). 약 3.4 MB |
| `vertical-pad-<versionName>.apk` | 안드로이드 뷰어 `com.sec.vertical_pad` (arm64-v8a, `apps[]`) |
| `vertical-pad-<versionName>-armeabi-v7a.apk` | 같은 뷰어의 32비트 빌드(갤럭시 탭 SM-T583 등, `-PabiV7`) — `appVariants[]`. 옛 뷰어·송출 앱·Pi 는 이 키를 모르고 지나가고, 새 뷰어가 `Build.SUPPORTED_ABIS` 로 고른다. 항목마다 `abis`(없으면 arm64-v8a) |
| `vertical-publisher-<versionName>.apk` | 송출 앱 `com.vertical.publisher` |

- manifest 서명은 없다. `sha256`·`size` 는 깨짐·덜 받음 검사용이다. APK 는 안드로이드 서명 검사(현장과 같은 debug 키)로 보호된다.
- 확인 도구: `scripts/ota_verify.py manifest.json --dir <폴더> [--only server|<package>]`, 값 꺼내기 `--get server.file`.
- APK 는 git 에 커밋하지 않는다 — 바이너리가 버전마다 영구 누적되면 저장소가 부푼다.

## 안전 원칙

- **설치는 사람만** — 받기·확인은 자동, 교체는 뷰어 [설치] 버튼일 때만
- **완전히 받고 확인한 뒤에만 교체** (size·SHA-256 → 풀기 → 의존성 → 원자적 심볼릭링크 교체 → 헬스체크)
- **실패하면 자동 롤백** (직전 릴리스로 링크 복구, 그 버전은 다시 받지 않음)
- **다운그레이드 없음** (sort -V 로 엄격히 높을 때만)
