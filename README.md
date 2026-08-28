# vertical-dist

**Vertical 현장 장비 OTA 배포 저장소.**

라즈베리파이 카메라 서버(`rtsp-api-server`)와 안드로이드 뷰어 앱(**Vertical**)을
GitHub Releases 로 배포하고, 현장 장비가 인터넷이 될 때만 안전하게 갱신한다.

## 운용 전제

| 장소 | 네트워크 | 동작 |
|---|---|---|
| **현장** | 공유기만 (인터넷 없음) | 영상 전송만. **업데이트 시도 없음** |
| **집** | 같은 SSID, 인터넷 있음 | 이때만 갱신 |

SSID 가 같아 이름으로는 구분할 수 없다. **GitHub 도달 여부 자체가 판별 기준**이다.

## 갱신 시점 (이 3가지뿐)

1. **부팅 후 2분**
2. **1시간마다**
3. **앱 설정의 "업데이트 확인" 버튼** → Pi 의 `POST /update/check`

## 배포 경로

```
GitHub Releases ──(집: 인터넷)──> 라즈베리파이 ──(현장: 사설망)──> 안드로이드 앱
```

**Pi 가 APK 재배포자다.** 집에서 받아둔 APK 를 Pi 가 서빙하므로
**폰은 현장에서도 인터넷 없이 업데이트**할 수 있다.

## 설치 (Pi, 1회)

```bash
curl -fsSL https://raw.githubusercontent.com/bdhwan/vertical-dist/main/scripts/install.sh | bash
```

## 릴리스 구성

각 릴리스(`v1.2.0`)에 다음 자산이 올라간다.

| 자산 | 내용 |
|---|---|
| `manifest.json` | 버전 · versionCode · SHA-256 |
| `server-<ver>.tar.gz` | Pi 서버 소스 |
| `vertical-<ver>.apk` | 안드로이드 앱 |

APK 는 git 에 커밋하지 않는다 — 바이너리가 버전마다 영구 누적되면 저장소가 부푼다.

## 안전 원칙

- **인터넷 없으면 아무것도 하지 않는다** (조회 실패 = 현장으로 판단, 즉시 종료)
- **촬영 중이면 건너뛴다** (`GET /youtube/status` 의 `recording`)
- **완전히 받고 검증한 뒤에만 교체한다** (SHA-256 → 빌드 → 헬스체크 → 원자적 심볼릭링크 교체)
- **실패하면 자동 롤백** (직전 릴리스로 링크 복구)
