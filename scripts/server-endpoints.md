# Pi 서버에 추가할 OTA 엔드포인트

`rtsp-api-server` 에 3개를 추가한다. APK 를 폰에 나눠주는 역할이다.

| 엔드포인트 | 용도 |
|---|---|
| `GET /update/manifest` | `/opt/vertical/apk/manifest.json` 반환 — 앱이 versionCode 비교 |
| `GET /update/apk` | `/opt/vertical/apk/vertical.apk` 파일 전송 |
| `POST /update/check` | 앱 "업데이트 확인" 버튼 → `systemctl start vertical-update.service` |

## 주의 — 기존 `@Get("update")` 와 충돌

`app.controller.ts:514` 에 이미 `@Get("update")` 가 있고 로컬 `update.sh`+`restart.sh` 를
실행하는 **구식 경로**다. OTA 도입 시 이 라우트는 제거하거나 `/update/legacy` 로 옮긴다.
그대로 두면 `/update/...` 경로와 헷갈린다.

## 앱 쪽 동작

```
설정 "업데이트 확인" 버튼
  → POST /update/check      (Pi 가 인터넷 확인·다운로드 — 없으면 즉시 종료)
  → GET  /update/manifest   (versionCode 비교)
  → 새 버전이면 사용자 확인 → GET /update/apk → SHA-256 검증 → 설치
```

폰은 **인터넷이 필요 없다.** Pi 와 같은 AP 에만 있으면 된다.
