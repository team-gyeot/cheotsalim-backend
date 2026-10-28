# cheotsalim-backend

첫살림 백엔드. Java 21 / Spring Boot 4.1.2 / PostgreSQL.

현재 배포 목표는 `인터넷 → Nginx:80 → 127.0.0.1:8080 → Cloud DB:5432`의 연결 확인이다.
DB는 기존 Cloud DB를 사용하며 Compose로 별도 DB를 만들지 않는다.

## 1. 서버에서 DB 환경 변수 준비

저장소 루트에서 실행한다. Docker와 Compose, 호스트 Nginx가 설치된 Ubuntu 기준이다.

```bash
cp .env.example .env
chmod 600 .env
nano .env
```

| 변수 | 값 |
| --- | --- |
| `DB_HOST` | Cloud DB 콘솔에서 확인한 **Private Domain**, 프로토콜·포트 제외 |
| `DB_PORT` | `5432` |
| `DB_NAME` | `cheotsalim` |
| `DB_USERNAME` | 현재 접속 확인 계정 `cheotsalim_admin` |
| `DB_PASSWORD` | 콘솔에서 확인한 실제 비밀번호 |

Compose는 `.env`를 읽어 컨테이너에 전달한다. 비밀번호는 예제처럼 작은따옴표로 감싸 `$`, `#` 등이 해석되지 않게 한다.
비밀번호에 작은따옴표가 있으면 Compose 규칙에 따라 `\'`로 이스케이프한다.
`.env`, `.env.*`, `*.pem`, `*.key`는 Git과 Docker 빌드 컨텍스트에서 제외된다. `.env.example`만 Git에 포함한다.
이미 Git에 올린 비밀값은 ignore로 제거되지 않으므로 해당 값은 교체해야 한다.
`docker compose config`, `docker inspect` 출력에는 비밀번호가 포함될 수 있으므로 공유하지 않는다.

Spring 설정은 DB 필수값에 기본 비밀번호를 제공하지 않는다. Hikari 풀은 최대 5개 연결을 사용한다.
`ddl-auto: validate`이므로 테이블을 자동 생성·수정하지 않는다. 엔티티가 추가되면 먼저 별도 스키마 변경이 필요하다.

## 2. Docker 빌드 및 실행

```bash
sudo docker compose up -d --build --wait --wait-timeout 180
sudo docker compose ps
curl -i http://127.0.0.1:8080/api/health
```

이미지 빌드에서 Gradle 테스트와 `bootJar`를 실행한다. 빌드에는 Gradle·Maven 저장소와 Docker 이미지 다운로드를 위한 외부 통신이 필요하다.
최종 컨테이너는 Java 21 JRE와 일반 사용자로 실행된다. 백엔드 포트는 서버의 `127.0.0.1`에만 게시한다.

성공 응답:

```http
HTTP/1.1 200
Content-Type: application/json

{"status":"UP"}
```

이 API는 요청마다 `SELECT 1`을 실행한다. DB 쿼리 실패 시 `503 {"status":"DOWN"}`만 반환하며 DB 주소·비밀번호·예외 내용을 노출하지 않는다.
기동 단계부터 DB 연결에 실패하면 API가 열리지 않을 수도 있다. 컨테이너 healthcheck도 같은 API를 사용한다.
Docker의 `unhealthy` 상태만으로 자동 재시작되지는 않는다. `restart: unless-stopped`는 프로세스 종료 등에 대한 재시작 정책이다.

문제 확인:

```bash
sudo docker compose logs --tail=100 backend
```

- 환경 변수 오류: `.env`의 필수값을 입력한다.
- DB 연결 오류: Private Domain, 계정·비밀번호, DB 사용자 접속 범위 `10.20.1.6/32`, DB ACG의 앱 서버 접근 허용을 확인한다.
- 서버의 psql은 성공하지만 컨테이너는 실패: 컨테이너의 DNS·라우팅과 DB ACG를 확인한다.
- `Schema-validation` 오류: 엔티티에 필요한 스키마를 먼저 반영한다. `ddl-auto: update`로 우회하지 않는다.

`.env` 변경 후에는 `sudo docker compose up -d --force-recreate --wait --wait-timeout 180`으로 다시 생성한다.
중지하려면 `sudo docker compose down`을 사용한다. 외부 Cloud DB 데이터에는 영향을 주지 않는다.

## 3. 호스트 Nginx 연결

백엔드의 로컬 health 응답을 확인한 다음 진행한다.
`deploy/nginx/cheotsalim.conf`는 IPv4 `listen 80`만 사용하므로 현재 서버의 IPv6 소켓 문제를 피한다.
`proxy_pass`에 URI를 붙이지 않아 `/api/health` 경로를 그대로 전달한다.

Ubuntu 기본 사이트가 `/etc/nginx/sites-enabled/default` 심볼릭 링크로 활성화된 상태를 기준으로 한다.
기존 default 원본은 수정하지 않는다. 다른 사이트가 있다면 `default_server` 중복 여부를 먼저 확인한다.

```bash
sudo install -m 644 deploy/nginx/cheotsalim.conf /etc/nginx/sites-available/cheotsalim
sudo ln -sfn /etc/nginx/sites-available/cheotsalim /etc/nginx/sites-enabled/cheotsalim
sudo unlink /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx
curl -i http://127.0.0.1/api/health
```

`default` 링크가 이미 없다면 `unlink`는 생략한다. `nginx -t`가 실패하면 reload하지 말고 충돌 설정을 수정한다.
기본 사이트로 되돌릴 때는 아래 명령을 사용한다.

```bash
sudo unlink /etc/nginx/sites-enabled/cheotsalim
sudo ln -sfn /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx
```

외부 PC에서도 다음 요청이 200인지 확인한다.

```bash
curl -i http://APP_PUBLIC_IP/api/health
```

서버 ACG는 HTTP 80을 허용하고, SSH 22는 관리자의 IP 범위로 제한한다. 외부에서 8080이나 DB 5432를 열 필요는 없다.
502는 백엔드의 기동·포트부터 확인한다. 503과 `DOWN` 응답은 DB 연결부터 확인한다.

## 4. 로컬 개발 및 테스트

```powershell
.\gradlew.bat test bootJar
```

Linux에서는 `sh ./gradlew test bootJar`를 사용한다.
테스트는 DB 성공·실패 응답과 경로/메서드 접근 제한을 MockMvc 및 모의 JDBC로 검증하며 실제 PostgreSQL 접속을 대신하지 않는다.
직접 `bootRun`할 때는 DB 변수를 셸/IDE 환경 변수로 설정해야 한다. Spring Boot는 `.env`를 자동으로 읽지 않는다.

## 5. 기능 개발 및 실제 데이터 사용 전

현재 공개 경로는 `GET /api/health`뿐이며 다른 경로는 인증 여부와 관계없이 차단한다. CSRF 보호는 유지한다.
기능 API와 프론트 도메인이 정해지면 인증·인가와 허용할 CORS origin을 함께 설계한다. Swagger UI/API 문서는 현재 비활성화했다.
CLOVA Studio/OCR 연결과 키 설정은 실제 API 범위·비용 확인 이후에 추가한다.

현재 HTTP이며 DB 저장소 암호화도 적용되지 않았으므로 **배포 검증에는 가상 데이터만 사용한다**.
도메인 발급 후 인증서·HTTPS 리다이렉트와 전달 헤더 설정을 검토하고, 개인정보 사용 전에 DB 저장소/백업 암호화 지원, 접근 통제 및 복구 방안을 확인한다.
현재 JDBC URL은 TLS 검증 모드를 강제하지 않는다. DB의 TLS·CA 지원을 확인한 뒤 `sslmode=verify-full`과 신뢰할 CA 구성을 적용해야 한다.
앱 전용 최소 권한 DB 계정, 현재 1일 백업 보관 정책과 고가용성 미사용의 복구 한계도 운영 전에 검토한다.

설정 참고: [Spring Boot MVC 테스트](https://docs.spring.io/spring-boot/reference/testing/spring-boot-applications.html),
[Compose 환경 변수](https://docs.docker.com/compose/how-tos/environment-variables/set-environment-variables/),
[Nginx 프록시](https://nginx.org/en/docs/http/ngx_http_proxy_module.html).
