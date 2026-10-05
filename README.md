# Home Dashboard 배포

소스 저장소는 비공개로 유지한다. 공개 설치 저장소 `rnpeh84/home-dashboard-install`에는
install.sh, VERSION, 설치 안내와 Apache-2.0 고지만 게시한다.

fork 버전의 기준은 저장소 루트 `VERSION`이다. Homarr 원본 package 버전은 유지한다.
`x.x.x` 이미지 태그는 재사용하지 않으며 새 코드 배포는 VERSION을 올리고 새 태그를 만든다.
이미지는 `hub.v.cller.com/home_dashboard/home-dashboard:<VERSION>`에 게시한다.
`latest`는 최신 검증된 버전과 같은 이미지를 가리키며, x.x.x 태그는 고정한다.
설치 스크립트는 공개 VERSION의 고정 버전을 기본으로 사용한다.
첫 릴리스는 `0.1.1`, Linux amd64이다.

Linux 서버에 Docker Engine, Docker Compose v2, curl, openssl이 필요하다.
Harbor 프로젝트가 private이면 서버에서 **pull 권한 전용 계정**으로 먼저 로그인한다.
배포용 push robot 계정을 설치 스크립트나 Git에 넣지 않는다.

```bash
docker login hub.v.cller.com
curl -fsSL https://raw.githubusercontent.com/rnpeh84/home-dashboard-install/v0.1.3/install.sh -o /tmp/home-dashboard-install.sh && sudo bash /tmp/home-dashboard-install.sh --version 0.1.3
```

Docker 로그인을 일반 사용자로 했다면 sudo Docker와 인증 저장소가 다르다. 같은 사용자로
로그인/설치를 실행한다. 예를 들어 `sudo docker login hub.v.cller.com` 후 sudo 설치한다.
기본 설치 경로는 명령을 실행한 현재 폴더, 포트는 `7575`, bind는 `0.0.0.0`이다.
실행하면 현재 폴더를 기본값으로 설치 경로를 묻는다. Enter는 현재 폴더, 다른 절대 경로를 입력하면
그 경로에 compose.yaml/.env/appdata를 만든다. `--dir` 또는 HOME_DASHBOARD_DIR을 지정하면
질문을 생략한다. 터미널 없는 자동 실행은 --dir이 필요하다. curl 파이프 실행도 경로 질문을
stdin 대신 /dev/tty에서 읽어 스크립트 내용과 사용자 입력이 섞이지 않는다.
설치 스크립트 버전은 `scripts/home-dashboard/INSTALLER_VERSION`(0.1.2), 앱 버전은
루트 VERSION(0.1.3)로 구분한다. 앱 변경은 새 버전 이미지로 빌드해 게시한다.
기존 reverse proxy 뒤에서만 노출하려면 `--bind 127.0.0.1`과 `--url https://실제주소`를 지정한다.
스크립트는 방화벽, DNS, TLS, reverse proxy를 변경하지 않는다.

`appdata/`에 DB·Redis 데이터가 보존되고 `.env`의 SECRET_ENCRYPTION_KEY는 한 번만 생성된다.
기존 키가 없거나 잘못되면 설치를 중단한다. 키를 바꾸면 기존 연동 비밀을 복호화할 수 없다.
초기 설치 후 웹에서 관리자 온보딩을 완료한다. 샘플 계정/로컬 검증 DB는 이미지에 포함되지 않는다.

같은 경로로 스크립트를 다시 실행하고 `--version x.x.x`를 지정하면 업데이트한다.
기존 port/bind/URL 설정은 `.env`에 기록되어 옵션을 생략해도 유지된다.
이미지를 먼저 pull하고, 기존 컨테이너를 정지한 뒤 `backups/<UTC시간-PID>/`에
appdata 전체와 기존 compose/.env/VERSION을 백업한다. 실패한 백업은 기존 구성을 다시 시작한다.
마이그레이션 후 이전 이미지로 태그만 바꾸는 rollback은 지원하지 않는다.
복구 시 컨테이너를 정지하고 백업 데이터·키·compose를 함께 복원한 뒤 이전 버전을 시작한다.
백업에는 비밀 값이 있으므로 외부 공개하거나 Git에 추가하지 않는다.

빌드는 기존 Dockerfile을 사용한다:

```powershell
$releaseVersion = (Get-Content VERSION -Raw).Trim()
$releaseRevision = git rev-parse HEAD
docker buildx build --platform linux/amd64 --build-arg "HOME_DASHBOARD_VERSION=$releaseVersion" --build-arg "SOURCE_REVISION=$releaseRevision" --tag "hub.v.cller.com/home_dashboard/home-dashboard:$releaseVersion" --load .
```

OCI version/revision/source 라벨을 확인하고 격리 볼륨에서 실행·마이그레이션·재시작을 검증한
뒤 push한다. VERSION, 소스 커밋, 이미지 digest와 검증 결과는 구현 계획에 기록한다.
