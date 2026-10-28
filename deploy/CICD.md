# develop 즉시 배포 연결

GitHub 기본 러너가 테스트·빌드에 성공하면 기존 앱 서버에 WireGuard로 연결하고 SSH로 배포한다.
별도 러너 서버·고정 IP 러너·서버 조회 타이머는 사용하지 않는다.
즉시 배포는 주기적 확인 대기가 없다는 뜻이며, CI·VPN 연결·Docker 빌드 시간은 필요하다.

## 실행 조건

| 이벤트 | 실행 |
| --- | --- |
| develop/main 대상 PR | CI만 실행 |
| main push | CI만 실행 |
| develop push | CI 성공 후 배포 |
| Run workflow에서 develop 선택 | CI 성공 후 배포 |

배포는 Repository variable `DEPLOY_ENABLED=true`일 때만 실행한다.
서버 저장소는 develop을 사용하고 최신 origin/develop과 일치하는 커밋만 반영한다.
동시 배포는 직렬화하며 오래된 실행은 skip한다. 결과와 실패 로그는 GitHub Actions의 deploy 작업에서 확인한다.
DB 비밀번호는 기존 서버 `.env`에만 둔다. Nginx는 자동으로 수정하지 않는다.

## 연결 경로

`GitHub 기본 러너 → 앱 서버 공인 IP의 UDP 51820 → WireGuard 터널 → 10.203.0.1:22 SSH → Docker`

- 앱 서버의 터널 IP: `10.203.0.1`
- GitHub 러너의 터널 IP: `10.203.0.2`
- WireGuard 인터페이스: 양쪽 모두 `wg-ci`
- 기존 TCP 22의 관리자 IP 제한은 유지한다.
- 터널에는 서버 한 대로 가는 경로만 추가한다. 기본 인터넷 경로·DB/VPC 경로는 변경하지 않는다.
- 서버 템플릿은 터널에서 오는 트래픽 중 SSH만 허용하고 다른 호스트로의 전달을 차단한다. IP forwarding/NAT를 새로 켤 필요가 없다.

공개 저장소에 self-hosted runner를 등록하지 않는다. PR에서는 배포 Secrets와 VPN을 사용하지 않는다.
공식 참고: [GitHub WireGuard 연결](https://docs.github.com/en/actions/how-tos/manage-runners/github-hosted-runners/connect-to-a-private-network/connect-with-wireguard),
[WireGuard 키 생성](https://www.wireguard.com/quickstart/).

## 1. GitHub와 내 PC: 코드 반영

설정 중에는 Repository variable `DEPLOY_ENABLED`를 `false`로 두거나 등록하지 않는다.
develop에서 변경 파일을 커밋·푸시하고 CI가 성공하는지 확인한다. main으로 병합할 필요는 없다.

GitHub **Settings → Environments**에서 `development` 환경을 만들고 배포 허용 브랜치를 **develop만**으로 지정한다.
push만으로 배포하려면 이 환경에 수동 승인자를 필수로 지정하지 않는다.

## 2. 서버 SSH 터미널: 타이머 중지와 브랜치 전환

이전 방식의 타이머를 실제로 설치했다면 다음을 실행한다. 설치하지 않았다면 생략한다.

```bash
sudo systemctl disable --now cheotsalim-deploy.timer
systemctl is-active cheotsalim-deploy.service
```

서비스가 active라면 기존 배포가 끝날 때까지 기다린다. 타이머만 중지해도 현재 실행 중인 배포는 계속된다.
현재 앱을 내리거나 배포 서비스를 강제로 중지할 필요는 없다.

```bash
cd ~/cheotsalim-backend
git status --short
git fetch origin
git switch develop
git pull --ff-only origin develop
```

미커밋 변경이 있으면 보존·정리한 뒤 진행한다. 강제 reset하지 않는다.
`git switch develop`은 로컬 develop이 없으면 origin/develop을 추적하는 브랜치를 만든다.
새로 clone하는 경우 `git clone --branch develop https://github.com/team-gyeot/cheotsalim-backend.git`으로 지정한다.

## 3. NCP 콘솔: ACG

앱 서버 ACG에 다음 인바운드 규칙을 추가한다.

| 프로토콜 | 포트 | 출발지 | 용도 |
| --- | --- | --- | --- |
| UDP | 51820 | 0.0.0.0/0 | 동적 IP인 GitHub 기본 러너의 키 인증 VPN 접속 |
| TCP | 22 | 기존 관리자 IP 범위 유지 | 관리자가 직접 접속 |

TCP 22를 전체 공개하지 않는다. UDP 포트를 공개하는 대신 WireGuard의 키 인증으로 접속을 제한한다.
별도 NACL을 제한해 두었다면 UDP 왕복 통신도 허용해야 한다.
서버에서 `sudo ufw status`를 확인하고, 이미 UFW가 활성화되어 있다면 `sudo ufw allow 51820/udp`도 실행한다.
UFW를 새로 활성화하거나 기존 방화벽 규칙을 초기화하지 않는다.

## 4. 서버 SSH 터미널: WireGuard 설치와 키 생성

```bash
sudo apt-get update
sudo apt-get install -y wireguard-tools iptables
sudo modprobe wireguard
ip route show
sudo install -d -m 700 /etc/wireguard
```

기존 네트워크에 `10.203.0.1/32`, `10.203.0.2/32`와 겹치는 경로가 없는지 확인한다.
겹친다면 워크플로·템플릿·SSH 키 제한·호스트 키 레코드의 터널 주소를 함께 변경해야 한다.
`modprobe`가 실패하면 커널의 WireGuard 지원을 먼저 확인한다.

아래 키 생성은 최초 한 번만 실행한다. 기존 키가 있으면 덮어쓰지 않고 중단한다.

```bash
sudo bash -c '
set -euo pipefail
umask 077
test ! -e /etc/wireguard/ci-server.key
test ! -e /etc/wireguard/ci-client.key
wg genkey > /etc/wireguard/ci-server.key
wg pubkey < /etc/wireguard/ci-server.key > /etc/wireguard/ci-server.pub
wg genkey > /etc/wireguard/ci-client.key
wg pubkey < /etc/wireguard/ci-client.key > /etc/wireguard/ci-client.pub
'
```

서버 비밀키는 서버에만 두고, 클라이언트 비밀키는 이후 GitHub Secret으로 등록한다.
키·설정 내용은 채팅이나 로그에 공유하지 않는다.

## 5. 서버 SSH 터미널: WireGuard 설정

기존 `/etc/wireguard/wg-ci.conf`가 있다면 덮어쓰지 말고 먼저 내용을 확인한다.
최초 설정 시 다음을 실행한다.

```bash
cd ~/cheotsalim-backend
sudo install -m 600 deploy/wireguard/wg-ci.conf.example /etc/wireguard/wg-ci.conf
sudo nano /etc/wireguard/wg-ci.conf
```

템플릿의 두 항목만 실제 값으로 바꾼다. 키 파일은 관리자 터미널에서 `sudo cat`으로 확인할 수 있다.

| 자리 표시자 | 사용할 파일의 내용 |
| --- | --- |
| REPLACE_WITH_SERVER_PRIVATE_KEY | /etc/wireguard/ci-server.key |
| REPLACE_WITH_CLIENT_PUBLIC_KEY | /etc/wireguard/ci-client.pub |

```bash
sudo systemctl enable --now wg-quick@wg-ci
sudo wg show wg-ci
sudo ss -lntp 'sport = :22'
```

SSH가 `0.0.0.0:22` 또는 터널 주소에서 수신하는지 확인한다. 특정 기존 사설 IP만 수신한다면 SSH ListenAddress 설정을 추가 검토한다.
WireGuard peer handshake는 첫 GitHub 접속 때 발생하므로 이 단계에서 없을 수 있다.
템플릿은 터널의 ICMP 등을 차단하므로 ping 성공을 연결 확인 기준으로 사용하지 않는다.

## 6. 내 PC: 배포용 SSH 키 생성

PowerShell에서 실행한다. 기존 배포 전용 키가 있으면 재사용할 수 있으며 덮어쓰지 않는다.

```powershell
ssh-keygen -t ed25519 -C "github-actions-cheotsalim" -f "$env:USERPROFILE\.ssh\cheotsalim-actions"
```

무인 접속용이므로 passphrase 입력은 빈 값으로 Enter 두 번을 누른다.
`.pub`는 공개키이며 확장자 없는 파일은 비밀키다.

서버에서 기존 관리용 키를 유지한 채 `~/.ssh/authorized_keys`에 새 공개키 한 줄을 추가한다.
공개키 앞에 아래 제한을 붙인다.

```text
from="10.203.0.2",restrict ssh-ed25519 AAAA... github-actions-cheotsalim
```

```bash
mkdir -p ~/.ssh
chmod 700 ~/.ssh
nano ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

이 전용 키는 터널의 러너 주소에서만 인증되며 PTY와 포트 포워딩을 허용하지 않는다.

## 7. 서버 SSH 터미널: 비대화형 Docker 권한

```bash
command -v docker
sudo visudo -f /etc/sudoers.d/cheotsalim-deploy
```

Docker 경로가 `/usr/bin/docker`인지 확인하고 아래 내용을 한 줄로 저장한다. 이미 같은 규칙이 있으면 중복 추가하지 않는다.

```sudoers
deploy ALL=(root) NOPASSWD: /usr/bin/docker compose -f /home/deploy/cheotsalim-backend/compose.yaml --project-directory /home/deploy/cheotsalim-backend up -d --build --wait --wait-timeout 180
```

```bash
sudo chmod 440 /etc/sudoers.d/cheotsalim-deploy
sudo visudo -c
```

Docker 경로가 다르면 deploy.sh와 sudoers를 함께 맞춘다. `NOPASSWD: ALL`은 추가하지 않는다.
Dockerfile·Compose 수정 권한과 이 명령을 실행할 권한을 가진 주체는 사실상 root 수준 작업이 가능하다.
develop 쓰기 권한과 GitHub Secrets를 관리자 자격증명으로 취급한다. develop의 PR 리뷰·CI 보호 규칙을 함께 권장한다.

## 8. GitHub: Secrets 등록 및 활성화

Settings → Environments → development에 Environment secrets를 등록한다.

| Secret | 값 |
| --- | --- |
| DEPLOY_HOST | 앱 서버의 공인 IPv4 또는 공인 호스트명. 포트·프로토콜 제외 |
| WG_CLIENT_PRIVATE_KEY | /etc/wireguard/ci-client.key 내용 |
| WG_SERVER_PUBLIC_KEY | /etc/wireguard/ci-server.pub 내용 |
| DEPLOY_SSH_KEY | 로컬에서 생성한 배포용 SSH 비밀키 전체, BEGIN/END 줄 포함 |
| DEPLOY_KNOWN_HOSTS | 아래에서 확인한 터널 주소의 SSH 호스트 키 레코드 |

호스트 키는 이미 신뢰하고 접속한 서버 SSH 터미널에서 확인한다.

```bash
printf '%s ' '10.203.0.1'
cat /etc/ssh/ssh_host_ed25519_key.pub
```

출력된 `10.203.0.1 ssh-ed25519 AAAA...` 한 줄을 DEPLOY_KNOWN_HOSTS에 넣는다.
공인 IP가 아닌 SSH 접속 대상인 터널 주소를 사용한다. 호스트 키 검증은 끄지 않는다.

Settings → Secrets and variables → Actions → Variables에 Repository variable `DEPLOY_ENABLED=true`를 등록한다.
이전 DEPLOY_RUNNER와 production 환경 설정은 사용하지 않는다. 배포 Secrets는 development 환경에 있어야 한다.

## 9. 첫 실행과 이후 배포

Actions → CI/CD → Run workflow에서 develop을 선택한다.
build와 deploy가 성공하고 외부에서도 `/api/health`가 200인지 확인한다.
이후에는 develop push마다 CI 성공 후 자동으로 배포한다. main PR 병합이나 별도 push는 필요 없다.

배포 일시 중지는 DEPLOY_ENABLED를 false로 바꾼다. 이미 실행 중인 배포는 취소하지 않으며 현재 앱도 중지하지 않는다.
자동 배포와 수동 배포를 동시에 실행하지 않는다.

문제 확인:

- VPN/SSH timeout: ACG·NACL·UFW의 UDP 통신, 공인 IP, 양쪽 WireGuard 키와 `sudo wg show wg-ci` 확인.
- SSH Permission denied: 전용 공개키와 from 주소, deploy 사용자 확인.
- Host key verification failed: 신뢰할 서버에서 호스트 키 확인. 검증 비활성화로 우회하지 않는다.
- sudo password required: sudoers와 스크립트 명령이 정확히 일치하는지 확인.
- 잘못된 브랜치/로컬 변경/fast-forward 실패: 서버 상태를 보존·정리한 뒤 다시 실행. 강제 reset하지 않는다.
- 오래된 실행 skip: 최신 develop 실행 결과를 확인한다.
- 컨테이너/health 실패: 서버에서 `sudo docker compose logs --tail=100 backend` 확인.

서버가 CI에서 검증한 SHA를 다시 빌드한다. 사용 중인 Docker 태그와 외부 의존성까지 고정하는 이미지 릴리스 방식은 포함하지 않는다.
재배포 중 짧은 중단이 있으며 자동 rollback은 없다. 코드 문제라면 develop에 revert를 반영해 재배포한다.
DB 스키마 변경은 별도 복구 계획이 필요하다. HTTPS·DB 암호화 확인 전에는 가상 데이터만 사용한다.
