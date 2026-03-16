# OCP4 Air-Gap Easy Install — 스크립트 명세서

> **목적**: `ocp4-ez-install` 프로젝트의 모든 스크립트에 대한 구현 명세입니다.
> 이 문서만으로 스크립트의 동작을 이해하고 재현하거나 수정할 수 있도록 작성되었습니다.

---

## 1. 프로젝트 개요

Air-gap(인터넷 차단) 환경에서 OpenShift Container Platform 4(OCP4)를 설치하기 위한 쉘 스크립트 모음.
인터넷이 연결된 서버에서 필요한 도구와 이미지를 다운로드/미러링한 뒤, 그 결과물을 air-gap 환경으로 옮겨 설치하는 2단계 구조.

### 환경 정보

| 항목 | 값 |
|------|-----|
| 설치 OCP 버전 | 4.20.14 |
| 서버 OS | RHEL 9 |
| 아키텍처 | x86_64 |
| 설치 방식 | Agent-Based Install |

---

## 2. 디렉토리 구조

```
ocp4-ez-install/                        ← 프로젝트 루트 (BASE_DIR)
├── config.env                          ← 공통 환경설정 파일
├── connected/                          ← 인터넷 연결 환경 스크립트
│   ├── 01_download_ocp_tools.sh        ← OCP CLI 도구 다운로드 및 설치
│   ├── 02_create_isc.sh                ← ISC YAML 파일 생성 (인터랙티브)
│   └── 03_mirror_images.sh             ← oc-mirror 로 이미지 미러링
├── air-gapped/                         ← 인터넷 차단 환경 스크립트
│   ├── 01_install_tools.sh             ← CLI 도구 설치 (downloads/ 사용)
│   ├── 02_create_certs.sh              ← CA/서버 인증서 생성
│   ├── 03_create_registry.sh           ← Mirror Registry 구성 (Podman)
│   ├── 04_upload_mirror.sh             ← 미러링 이미지 → Registry 업로드
│   ├── 05_create_install_config.sh     ← install-config.yaml 생성
│   ├── 06_create_agent_config.sh       ← agent-config.yaml 생성
│   ├── 07_create_config_yaml.sh        ← 클러스터 매니페스트 생성
│   ├── 08_create_cluster_manifests.sh  ← cluster-manifests 생성
│   ├── 09_create_agent_iso.sh          ← Agent ISO 생성
│   └── 10_monitor_install.sh           ← 설치 진행 모니터링
├── add-nodes/                          ← 워커 노드 추가 스크립트
│   ├── 01_create_nodes_config.sh       ← nodes-config.yaml 생성
│   └── 02_create_nodes_iso.sh          ← 노드 추가용 ISO 생성
├── add-operators/                      ← 운영 중 Operator 추가 스크립트
│   ├── 01_create_add_operators_isc.sh  ← 추가 Operator ISC 파일 생성
│   └── 02_mirror_add_operators.sh      ← 추가 Operator 이미지 미러링
└── {CLUSTER_NAME}/                     ← 05~09 스크립트가 사용하는 클러스터 디렉토리
    ├── orig/                           ← 원본 설치 파일 보관
    │   ├── install-config.yaml
    │   ├── agent-config.yaml
    │   └── openshift/                  ← 클러스터 매니페스트 원본
    └── cluster-manifests/              ← 08_create_cluster_manifests.sh 가 생성
```

### 런타임 데이터 경로 (BASE_DIR 기준)

```
{BASE_DIR}/
├── downloads/       ← 다운로드된 tar.gz 원본 파일
├── mirror/          ← oc-mirror 결과물 (ISC 파일 + 미러링 데이터, air-gap 환경으로 전송)
│   ├── ocp/
│   │   └── ocp-isc.yaml
│   ├── olm-redhat/
│   │   └── olm-redhat-isc.yaml
│   ├── olm-certified/
│   │   └── olm-certified-isc.yaml
│   ├── olm-community/
│   │   └── olm-community-isc.yaml
│   └── add-images/
│       └── add-images-isc.yaml
├── cache/           ← oc-mirror 캐시 (업로드 시 사용)
│   └── {target}/
├── mirror-added/    ← add-operators 미러링 결과물
│   └── {YYYYMMDD-HHMMSS}/
│       ├── olm-redhat/
│       ├── olm-certified/
│       └── olm-community/
├── cache-added/     ← add-operators oc-mirror 캐시
│   └── {YYYYMMDD-HHMMSS}/{target}/
├── certs/           ← 생성된 인증서
│   └── {domain}/
│       ├── root_ca/         (ca.key, ca.crt)
│       └── domain_certs/    ({name}.key, {name}.crt)
└── logs/            ← 스크립트 실행 로그
```

---

## 3. 공통 규칙

### 3-1. Bash 스크립트 공통 헤더

모든 `.sh` 파일:
```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.env"   # air-gapped/, connected/ 스크립트 기준
source "${CONFIG_FILE}"
```

- config.env 파일이 없으면 즉시 `exit 1`
- air-gapped/와 connected/ 스크립트 모두 `../config.env` 경로 사용

### 3-2. 헬퍼 함수 패턴

스크립트별로 필요에 따라 아래 두 패턴 중 하나 사용:

**색상 출력 패턴** (02_create_certs.sh 등):
```bash
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
```

**단순 출력 패턴** (01_install_tools.sh, 03_create_registry.sh 등):
```bash
info()  { echo "[INFO] $*"; }
warn()  { echo "[WARN] $*"; }
error() { echo "[ERROR] $*" >&2; }
```

**명령어 추적 헬퍼** (설치/설정 스크립트):
```bash
run() { echo "[CMD] $*"; "$@"; }
```

---

## 4. `config.env` 명세

**위치**: 프로젝트 루트
**용도**: 모든 스크립트가 `source` 하는 공통 설정 파일
**셔뱅**: `#!/usr/bin/env bash`

### 4-1. 변수 목록

#### OpenShift 버전

| 변수 | 예시값 | 설명 |
|------|----|------|
| `OCP_VERSION` | `4.20.14` | 전체 버전 문자열 |
| `OCP_MAJOR_VERSION` | `4.20` | Catalog 태그에 사용 |
| `OCP_CHANNEL` | `stable-4.20` | ISC platform channel 이름 |

#### 클러스터 기본 설정

| 변수 | 예시값 | 설명 |
|------|--------|------|
| `CLUSTER_NAME` | `kscada` | ISC/클러스터 디렉토리 이름 |
| `BASE_DOMAIN` | `kdneri.com` | 클러스터 베이스 도메인 |

#### 디렉토리 설정

| 변수 | 값 | 설명 |
|------|----|------|
| `BASE_DIR` | `$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)` | config.env 위치 기준 자동 설정 |
| `DOWNLOAD_DIR` | `${BASE_DIR}/downloads` | 다운로드 원본 저장 |
| `MIRROR_DIR` | `${BASE_DIR}/mirror` | oc-mirror 결과물 저장 |
| `CACHE_DIR` | `${BASE_DIR}/cache` | oc-mirror 캐시 디렉토리 |
| `LOG_DIR` | `${BASE_DIR}/logs` | 로그 디렉토리 |
| `CERTS_DIR` | `${BASE_DIR}/certs` | 인증서 저장 디렉토리 |
| `CLUSTER_DIR` | `${BASE_DIR}/${CLUSTER_NAME}` | ISC 파일 저장 위치 |

#### Mirror Registry 설정

| 변수 | 예시값 | 설명 |
|------|--------|------|
| `MIRROR_REGISTRY_HOST` | `ocp-registry.kscada.kdneri.com` | 레지스트리 호스트명 |
| `MIRROR_REGISTRY_PORT` | `5000` | 레지스트리 포트 |
| `MIRROR_REGISTRY` | `${MIRROR_REGISTRY_HOST}:${MIRROR_REGISTRY_PORT}` | 조합 주소 |
| `MIRROR_REGISTRY_USER` | `admin` | 레지스트리 사용자 |
| `MIRROR_REGISTRY_PASS` | `redhat` | 레지스트리 패스워드 |

#### 인증서 Subject DN 기본값

| 변수 | 예시값 |
|------|--------|
| `CERT_C` | `KR` |
| `CERT_ST` | `Seoul` |
| `CERT_L` | `Gangnam` |
| `CERT_O` | `Red Hat` |
| `CERT_OU` | `GPS` |

#### 인증 설정

| 변수 | 설명 |
|------|------|
| `PULL_SECRET_FILE` | `${BASE_DIR}/pull-secret.txt` — Red Hat Pull Secret 파일 경로 |
| `REDHAT_REGISTRY_USER` | registry.redhat.io 인증 (pull-secret 있으면 불필요, 기본 빈값) |
| `REDHAT_REGISTRY_PASS` | 동일 |

#### 다운로드 URL

| 변수 | 값 |
|------|----|
| `OCP_MIRROR_BASE` | `https://mirror.openshift.com/pub/openshift-v4/x86_64/clients` |
| `OCP_CLIENT_URL` | `${OCP_MIRROR_BASE}/ocp/${OCP_VERSION}` |
| `BUTANE_URL` | `${OCP_MIRROR_BASE}/butane/latest/butane-amd64` |
| `HELM_VERSION` | `3.17.1` |
| `HELM_URL` | `https://developers.redhat.com/content-gateway/file/pub/openshift-v4/clients/helm/${HELM_VERSION}/helm-linux-amd64.tar.gz` |

#### Operator Catalog 주소

| 변수 | 값 |
|------|----|
| `REDHAT_OPERATOR_INDEX` | `registry.redhat.io/redhat/redhat-operator-index:v${OCP_MAJOR_VERSION}` |
| `CERTIFIED_OPERATOR_INDEX` | `registry.redhat.io/redhat/certified-operator-index:v${OCP_MAJOR_VERSION}` |
| `COMMUNITY_OPERATOR_INDEX` | `registry.redhat.io/redhat/community-operator-index:v${OCP_MAJOR_VERSION}` |

#### Operator 그룹 배열

형식: `"operator-name:catalog"` (catalog: `redhat` | `certified` | `community`)

```bash
OPERATOR_GROUPS=(
    "base:기본 Operator"
    "gpu:GPU Operator (NFD, NVIDIA GPU/Network)"
    "virt:가상화 Operator (KubeVirt, LSO, MTV 등)"
    "cicd:CI/CD Operator (GitOps, Pipelines, RHBK 등)"
)

BASE_OPERATORS=(
    "elasticsearch-eck-operator-certified:certified"
    "web-terminal:redhat"
    "kubernetes-nmstate-operator:redhat"
    "node-healthcheck-operator:redhat"
    "self-node-remediation:redhat"
    "cincinnati-operator:redhat"
    "cluster-logging:redhat"
    "devworkspace-operator:redhat"
    "loki-operator:redhat"
    "netobserv-operator:redhat"
    "metallb-operator:redhat"
)

GPU_OPERATORS=(
    "nfd:redhat"
    "gpu-operator-certified:certified"
    "nvidia-network-operator:certified"
)

VIRT_OPERATORS=(
    "kubevirt-hyperconverged:redhat"
    "local-storage-operator:redhat"
    "mtc-operator:redhat"
    "mtv-operator:redhat"
    "redhat-oadp-operator:redhat"
    "fence-agents-remediation:redhat"
)

CICD_OPERATORS=(
    "openshift-gitops-operator:redhat"
    "rhbk-operator:redhat"
    "openshift-pipelines-operator-rh:redhat"
)
```

#### Add Operators

운영 중인 클러스터에 추가할 Operator 목록과 결과물 저장 디렉토리.

```bash
ADD_OPERATORS=(
    "elasticsearch-operator:redhat"
    "amq-streams:redhat"
)

ADD_OPERATORS_MIRROR_DIR="${BASE_DIR}/mirror-added"
ADD_OPERATORS_CACHE_DIR="${BASE_DIR}/cache-added"
```

- 형식: `"operator-name:catalog"` (기존 OPERATORS 배열과 동일)
- `ADD_OPERATORS_MIRROR_DIR`: 실행마다 타임스탬프 하위 디렉토리 자동 생성 (`YYYYMMDD-HHMMSS/`)
- `ADD_OPERATORS_CACHE_DIR`: 캐시도 타임스탬프별로 분리

#### 노드 정의

형식: `"role|hostname|ip|nic|mac"`

```bash
NODES=(
    "master|master0|192.168.100.10|ens3|52:54:00:aa:bb:01"
    "master|master1|192.168.100.11|ens3|52:54:00:aa:bb:02"
    "master|master2|192.168.100.12|ens3|52:54:00:aa:bb:03"
    "worker|worker0|192.168.100.20|ens3|52:54:00:aa:bb:04"
    "worker|worker1|192.168.100.21|ens3|52:54:00:aa:bb:05"
)

ADD_NODES=(    # add-nodes/ 스크립트에서 사용
    "worker|worker2|192.168.100.22|ens3|52:54:00:aa:bb:06"
    "worker|worker3|192.168.100.23|ens3|52:54:00:aa:bb:07"
)
```

#### 네트워크 설정

| 변수 | 예시값 | 설명 |
|------|--------|------|
| `MACHINE_NETWORK` | `192.168.100.0/24` | 노드 IP 네트워크 |
| `GATEWAY` | `192.168.100.1` | 기본 게이트웨이 |
| `DNS_SERVERS` | `("192.168.100.1")` | DNS 서버 목록 (배열) |
| `CLUSTER_NETWORK_CIDR` | `10.128.0.0/14` | OCP Pod 네트워크 |
| `CLUSTER_NETWORK_HOST_PREFIX` | `23` | Pod 네트워크 호스트 prefix |
| `SERVICE_NETWORK` | `172.30.0.0/16` | OCP Service 네트워크 |

#### SSH 키 설정

```bash
SSH_PUB_KEY=(
    "ssh-ed25519 AAAA... root@bastion01..."
    "ssh-ed25519 AAAA... cloud@bastion01..."
)
```

#### 추가 이미지 (ADDITIONAL_IMAGES)

```bash
ADDITIONAL_IMAGES=(
    "registry.redhat.io/rhaiis/vllm-cuda-rhel9:latest"
    "registry.redhat.io/rhelai1/granite-3-1-8b-instruct-quantized-w8a8:1.5"
    "registry.redhat.io/ubi8/ubi:latest"
    "registry.redhat.io/ubi9/ubi:latest"
)
```

#### 내부 변수 (수정 불필요)

```bash
LOG_FILE="${LOG_DIR}/ocp4-ez-install-$(date +%Y%m%d-%H%M%S).log"

OCP_TOOL_FILES=(
    "openshift-client-linux-amd64-rhel9.tar.gz"
    "oc-mirror.rhel9.tar.gz"
    "openshift-install-linux.tar.gz"
    "opm-linux-rhel9.tar.gz"
)
```

---

## 5. Connected 환경 스크립트

### 5-1. `connected/01_download_ocp_tools.sh`

**목적**: OCP 설치에 필요한 CLI 바이너리를 다운로드하고 `/usr/local/bin/` 에 설치
**실행 권한**: root 필수

#### 사전 검사

| 함수 | 내용 |
|------|------|
| `check_root()` | `$EUID -ne 0` 이면 `exit 1` |
| `check_os_version()` | `/etc/os-release` source 후 `ID != "rhel"` 또는 major버전 `!= "9"` 이면 `exit 1` |
| `check_disk_space()` | `DATA_DIR` 기준 가용 공간 < 10GB 이면 `exit 1` |
| `check_internet()` | `curl -fsS --connect-timeout 10 https://mirror.openshift.com` 실패 시 `exit 1` |

#### 디렉토리 생성

`create_directories()`: `DOWNLOAD_DIR`, `MIRROR_DIR`, `LOG_DIR`, `CLUSTER_DIR` 를 `mkdir -p` 로 생성

#### 다운로드

| 함수 | 내용 |
|------|------|
| `download_file(url, output, desc)` | `curl -fL --retry 3 --retry-delay 5 --connect-timeout 30 --progress-bar` 실패 시 파일 삭제 후 `return 1` |
| `download_ocp_tools()` | `OCP_TOOL_FILES` 배열 순회, 파일 존재 시 건너뜀 |
| `download_butane()` | `BUTANE_URL` 에서 단일 바이너리 다운로드 |
| `download_helm()` | `HELM_URL` 에서 tar.gz 다운로드 |

#### 압축 해제 및 설치

`extract_and_install_tools()`:
- `mktemp -d` 로 임시 디렉토리 생성, `trap` 으로 RETURN 시 자동 삭제
- `tar -xzf` 로 OCP 도구 4종 + Helm 압축 해제
- `find -maxdepth 3 -type f -executable` 로 바이너리 탐색
- `known_binaries=("oc" "kubectl" "oc-mirror" "openshift-install" "opm" "helm")` 에 있으면 `install -m 755` 로 `/usr/local/bin/` 에 설치
- Butane: tar.gz 아닌 단일 바이너리이므로 별도 처리 (`butane-amd64` → `butane`)

#### 설치 검증

`verify_installations()`: `printf "%-20s %-15s %s\n"` 형식 표, 미설치 시 `exit 1`

#### main() 실행 순서

```
print_banner → init_logging
→ check_root → check_os_version → check_disk_space → check_internet
→ create_directories
→ download_ocp_tools → download_butane → download_helm
→ extract_and_install_tools → verify_installations
```

---

### 5-2. `connected/02_create_isc.sh`

**목적**: oc-mirror v2 용 ImageSetConfiguration(ISC) YAML 파일 생성
**실행 권한**: 일반 사용자 (dnf install 시 root 필요)

#### 전역 변수

```bash
declare -a SELECTED_REDHAT_OPERATORS=()
declare -a SELECTED_CERTIFIED_OPERATORS=()
declare -a SELECTED_COMMUNITY_OPERATORS=()
```

#### 사전 검사

| 함수 | 내용 |
|------|------|
| `check_prerequisites()` | `oc`, `oc-mirror`, `skopeo`, `jq`, `podman`, `curl` 확인, 누락 시 `install_prerequisites()` 호출 |
| `install_prerequisites()` | `skopeo`, `jq`, `podman` 을 `dnf`(없으면 `yum`)로 설치 |
| `check_pull_secret()` | 파일 존재 → `jq -e '.'` JSON 검증 → `jq -e '.auths["registry.redhat.io"]'` 인증 확인 → `~/.docker/config.json` 없으면 복사 |

#### ISC 디렉토리

`create_isc_directories()`: `${CLUSTER_DIR}/{ocp,olm-redhat,olm-certified,olm-community}` 를 `mkdir -p`

#### Default Channel 조회

`get_default_channel(catalog, package)`:
- `oc-mirror list operators --catalog="${catalog}"` 출력에서 `awk -v pkg="${package}" '$1 == pkg { print $2; exit }'`
- 실패 시 빈 문자열 반환 → ISC에 channel 블록 없이 생성

`generate_package_yaml(name, channel)`:
```yaml
# channel 있을 때
    - name: {name}
      channels:
      - name: {channel}

# channel 없을 때
    - name: {name}
```

#### ISC YAML 생성

`create_ocp_isc()` → `${CLUSTER_DIR}/ocp/ocp-isc.yaml`:
```yaml
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  platform:
    channels:
    - name: {OCP_CHANNEL}
      minVersion: {OCP_VERSION}
      maxVersion: {OCP_VERSION}
      shortestPath: true
    graph: true
```

`create_redhat_olm_isc()` / `create_certified_olm_isc()` / `create_community_olm_isc()`:
- `SELECTED_*_OPERATORS` 배열이 비면 warn + `return 0`
- 각 operator에 대해 `get_default_channel` + `generate_package_yaml` 호출 후 append
- `additionalImages` 섹션에 `ADDITIONAL_IMAGES` 배열 포함 (olm-redhat ISC에만)

#### 메뉴 인터페이스

`show_main_menu()`: 번호 입력 방식, `^[1-5](,[1-5])*$` 검증
```
[1] OCP Platform
[2] RedHat OLM
[3] Certified OLM
[4] Community OLM
[5] ALL (1+2+3+4)
```

`select_operator_groups()`:
1. `BASE_OPERATORS` 자동 로드
2. GPU / Virt / CI/CD 그룹별 `ask_yn()` 질문 (y/N)
3. 중복 제거: `mapfile -t ... < <(printf '%s\n' ... | sort -u)`

`ask_yn(prompt)`: `read -rp "  ${prompt} (y/N): "` → `[[ "${answer}" =~ ^[Yy]$ ]]`

`input_community_operators()`: 쉼표 구분 자유 입력, `IFS=','` 로 파싱

#### main() 실행 순서

```
print_banner → init_logging
→ check_prerequisites → check_pull_secret
→ show_main_menu (→ select_operator_groups / input_community_operators / create_*)
→ print_summary
```

---

### 5-3. `connected/03_mirror_images.sh`

**목적**: ISC 파일을 사용해 `oc-mirror --v2` 로 이미지를 로컬 디스크에 미러링

#### 전역 변수

```bash
declare -gA ISC_MAP=(
    ["ocp"]="${CLUSTER_DIR}/ocp/ocp-isc.yaml"
    ["olm-redhat"]="${CLUSTER_DIR}/olm-redhat/olm-redhat-isc.yaml"
    ["olm-certified"]="${CLUSTER_DIR}/olm-certified/olm-certified-isc.yaml"
    ["olm-community"]="${CLUSTER_DIR}/olm-community/olm-community-isc.yaml"
)
declare -ga MIRROR_TARGETS=()
```

#### 사전 검사

| 함수 | 내용 |
|------|------|
| `check_prerequisites()` | `oc-mirror` 미설치 시 `exit 1`, `PULL_SECRET_FILE` 없으면 `exit 1`, `~/.docker/config.json` 없으면 pull-secret에서 복사 |
| `check_isc_files()` | ISC_MAP 4개 파일 존재 여부를 표로 출력, 4개 모두 없으면 `exit 1` |
| `check_disk_space()` | 가용 공간 < 50GB 이면 `log_warn` + (y/N) 확인 |

#### 미러링 실행

`run_mirror(isc_name, isc_file)`:
```bash
oc-mirror --v2 --config "${isc_file}" --log-level info "file://${mirror_dest}" 2>&1 | tee -a "${LOG_FILE}"
```
- 성공: 소요 시간, `du -sh` 크기 출력
- 실패: `return 1`

#### 메뉴

`show_mirror_menu()`: ISC_MAP 4개 항목 + `[5] ALL`, `^[1-5](,[1-5])*$` 검증
ISC 파일 없는 항목은 `(ISC 파일 없음 - 건너뜀)` 황색 표시

#### main() 실행 순서

```
print_banner → init_logging
→ check_prerequisites → check_isc_files → check_disk_space
→ show_mirror_menu → confirm_mirror
→ for target in MIRROR_TARGETS: run_mirror(target, ISC_MAP[target])
→ print_mirror_summary
```

---

## 6. Air-Gapped 환경 스크립트

### 6-1. `air-gapped/01_install_tools.sh`

**목적**: connected 환경에서 다운로드한 파일로 CLI 도구를 `/usr/local/bin/` 에 설치
**실행 권한**: root 필수

#### 함수 목록

| 함수 | 내용 |
|------|------|
| `check_rhel9()` | `/etc/redhat-release` 존재 및 버전 9 확인 |
| `check_root()` | `$EUID -ne 0` 이면 `exit 1` |
| `check_download_dir()` | `DOWNLOAD_DIR` 미존재 시 `exit 1` |
| `install_ocp_tools()` | `OCP_TOOL_FILES` 압축 해제 → `find -maxdepth 1 -type f -executable` → `install -m 755` |
| `install_butane()` | `downloads/butane-amd64` → `install -m 755 /usr/local/bin/butane` |
| `install_helm()` | `helm-linux-amd64.tar.gz` 압축 해제 → `install -m 755 helm-linux-amd64 /usr/local/bin/helm` (tar 내 `helm-linux-amd64` 경로) |
| `verify_installation()` | `tools=("oc" "kubectl" "oc-mirror" "openshift-install" "opm" "butane" "helm")` 확인, `printf "[OK] %-20s %s\n"` 형식 출력 |

#### main() 실행 순서

```
배너 출력 → check_rhel9 → check_root → check_download_dir
→ install_ocp_tools → install_butane → install_helm
→ verify_installation
```

---

### 6-2. `air-gapped/02_create_certs.sh`

**목적**: CA 인증서 및 서버 인증서 생성 (대화형)
**사전 조건**: `openssl` 설치

#### 인증서 디렉토리 구조

```
{CERTS_DIR}/{domain}/
├── root_ca/
│   ├── ca.key    (4096 bit RSA, chmod 600)
│   └── ca.crt    (유효기간 10년 / 3650일, CA:TRUE)
└── domain_certs/
    ├── {name}.key  (2048 bit RSA, chmod 600)
    └── {name}.crt  (유효기간 10년 / 3650일, CA:FALSE)
```

#### 메인 메뉴

```
1) CA 인증서 생성
2) 서버 인증서 생성
3) 생성된 인증서 목록 보기
q) 종료
```

#### `create_ca()` 흐름

1. `prompt_domain()`: 도메인 입력 (기본값: `BASE_DOMAIN`) → `CERT_DIR`, `ROOT_CA_DIR`, `DOMAIN_CERTS_DIR` 설정
2. CA 기존 존재 시 덮어쓰기 확인
3. `prompt_subject_dn()`: C/ST/L/O/OU 입력 (config.env 기본값 사용)
4. CN 입력 (기본값: `{domain} Root CA`)
5. OpenSSL 설정 파일(tmpfile) 생성 (`[v3_ca]` 포함)
6. `openssl genrsa 4096` → `openssl req -new -x509 -days 3650`

#### `create_server_cert()` 흐름

1. `CERTS_DIR` 하위 CA 목록 자동 탐색 (`find -mindepth 1 -maxdepth 1 -type d`)
2. CA 도메인 선택 (번호 또는 직접 입력)
3. 서버 CN 입력 (와일드카드 허용, `*.domain` → 파일명 `wildcard.domain`)
4. `prompt_subject_dn()`: Subject DN 입력
5. SAN DNS 항목 입력 (CN 자동으로 DNS.1 추가, 추가 DNS.2, DNS.3...)
6. SAN IP 항목 입력 (옵션)
7. CSR용 `req.cnf` + 서명용 `ext.cnf` 두 개 tmpfile 생성
8. `openssl genrsa 2048` → `openssl req -new` (CSR) → `openssl x509 -req -days 3650 -sha256` (CA 서명)
9. CSR + tmpfile 삭제, `openssl verify -CAfile` 로 체인 검증

#### `list_certs()` 흐름

`find CERTS_DIR -mindepth 1 -maxdepth 1 -type d` 순회, CA + 서버 인증서의 만료일 출력

---

### 6-3. `air-gapped/03_create_registry.sh`

**목적**: Podman 기반 Mirror Registry 구성, systemd 서비스 등록
**실행 권한**: root 필수
**사전 조건**: `02_create_certs.sh` 로 서버 인증서 생성 완료

#### 설정 변수

```bash
REGISTRY_BASE_HOME="/opt/registry"
REGISTRY_CONTAINER_NAME="mirror-registry"
REGISTRY_IMAGE="docker.io/library/registry:2"
```

#### 인증서 경로 (prompt_registry_info() 에서 설정)

```bash
DOMAIN_CRT="${CERTS_DIR}/${BASE_DOMAIN}/domain_certs/${MIRROR_REGISTRY_HOST}.crt"
DOMAIN_KEY="${CERTS_DIR}/${BASE_DOMAIN}/domain_certs/${MIRROR_REGISTRY_HOST}.key"
CA_CRT="${CERTS_DIR}/${BASE_DOMAIN}/root_ca/ca.crt"
```

#### 함수 목록

| 함수 | 내용 |
|------|------|
| `prompt_registry_info()` | Host/Port/User/Pass 입력 (Enter=기본값), 설정 확인 후 Y/n |
| `check_rhel9()` | RHEL9 확인 |
| `check_root()` | root 확인 |
| `check_htpasswd()` | `htpasswd` 없으면 `dnf install -y httpd-tools` |
| `check_certs()` | `DOMAIN_CRT`, `DOMAIN_KEY`, `CA_CRT` 존재 확인 |
| `create_dirs()` | `/opt/registry/{auth,data,certs}` 생성 |
| `copy_certs()` | 인증서 → `/opt/registry/certs/{registry.crt, registry.key, ca.crt}` |
| `create_htpasswd()` | `htpasswd -bBc /opt/registry/auth/htpasswd {user} {pass}` |
| `configure_docker_auth()` | `~/.docker/config.json` 에 base64 인증 정보 저장 |
| `trust_ca()` | CA 인증서 → `/etc/pki/ca-trust/source/anchors/` + `update-ca-trust extract` |
| `run_registry()` | `podman run -d` 로 registry:2 컨테이너 실행 (TLS, htpasswd 인증, `openssl rand -hex 16` HTTP_SECRET) |
| `create_systemd_service()` | `podman generate systemd --new --name` → `/etc/systemd/system/{name}.service` → `systemctl enable --now` |
| `configure_firewall()` | firewalld 활성 시 `firewall-cmd --add-port={port}/tcp --permanent` |
| `verify_registry()` | `curl -s ... https://{registry}/v2/` → HTTP 200 확인 |

#### main() 실행 순서

```
배너 출력 → prompt_registry_info
→ check_rhel9 → check_root → check_htpasswd → check_certs
→ create_dirs → copy_certs → create_htpasswd → configure_docker_auth
→ trust_ca → run_registry → create_systemd_service → configure_firewall
→ verify_registry
```

---

### 6-4. `air-gapped/04_upload_mirror.sh`

**목적**: `MIRROR_DIR` 의 미러링 파일을 내부 Registry 로 업로드 (`file://` → `docker://`)

#### ISC 매핑

```bash
declare -A ISC_FILES=(
    ["ocp"]="ocp-isc.yaml"
    ["olm-redhat"]="olm-redhat-isc.yaml"
    ["olm-certified"]="olm-certified-isc.yaml"
    ["olm-community"]="olm-community-isc.yaml"
    ["add-images"]="add-images-isc.yaml"
)
ISC_ORDER=("ocp" "olm-redhat" "olm-certified" "olm-community" "add-images")
```

#### 업로드 선택 메뉴

```
1) ocp           - OpenShift Platform 이미지
2) olm-redhat    - Red Hat Operator 이미지
3) olm-certified - Certified Operator 이미지
4) olm-community - Community Operator 이미지
5) add-images    - 추가 이미지 (ADDITIONAL_IMAGES)
6) all           - 전체 업로드
```

#### `configure_registry()`

- Registry 주소, 사용자, 패스워드 입력 (기본값: config.env)
- `podman login` 으로 사전 인증

#### `run_upload(target)`

```bash
oc-mirror \
    --v2 \
    --config "${isc_file}" \
    --from "file://${isc_dir}" \
    --cache-dir "${CACHE_DIR}/${target}" \
    --dest-tls-verify=false \
    "docker://${MIRROR_REGISTRY}/${target}"
```

#### main() 실행 순서

```
배너 출력 → configure_registry → check_prerequisites → select_target
→ run_upload() (단일 or 전체 순서대로)
→ 성공/실패 집계 출력
```

---

### 6-5. `air-gapped/05_create_install_config.sh`

**목적**: Agent-Based Install용 `install-config.yaml` 생성
**출력**: `${CLUSTER_DIR}/orig/install-config.yaml`

#### 노드 파싱

`parse_nodes()`: `NODES` 배열을 `IFS='|'` 로 파싱 → `MASTER_COUNT`, `WORKER_COUNT`, `MASTER_NODES[]`, `WORKER_NODES[]`

#### SSH 키 처리

`check_ssh_pub_key()`:
- `SSH_PUB_KEY` 배열 원소 1개: `sshKey: {key}` (단일행)
- 2개 이상: `sshKey: |` 후 각 키를 `  {key}` 로 indent

#### CA 인증서 선택

`load_ca_cert()`:
- `find ${CERTS_DIR} -mindepth 3 -maxdepth 3 -path "*/root_ca/ca.crt"` 로 목록 스캔
- 번호 선택 또는 `s` 로 건너뜀 (`additionalTrustBundle` 생략)

#### `generate_install_config()` 생성 내용

```yaml
apiVersion: v1
baseDomain: {BASE_DOMAIN}
metadata:
  name: {CLUSTER_NAME}
compute:
- architecture: amd64
  hyperthreading: Enabled
  name: worker
  replicas: {WORKER_COUNT}
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  replicas: {MASTER_COUNT}
networking:
  clusterNetwork:
  - cidr: {CLUSTER_NETWORK_CIDR}
    hostPrefix: {CLUSTER_NETWORK_HOST_PREFIX}
  machineNetwork:
  - cidr: {MACHINE_NETWORK}
  networkType: OVNKubernetes
  serviceNetwork:
  - {SERVICE_NETWORK}
platform:
  none: {}
fips: false
pullSecret: '{PULL_SECRET}'
sshKey: {SSH_KEY}
additionalTrustBundle: |   ← CA 인증서 선택 시만 포함
  {CA_CERT}
imageDigestSources:
- mirrors:
  - {MIRROR_REGISTRY}/ocp/openshift/release
  source: quay.io/openshift-release-dev/ocp-release
- mirrors:
  - {MIRROR_REGISTRY}/ocp/openshift/release
  source: quay.io/openshift-release-dev/ocp-v4.0-art-dev
```

#### main() 실행 순서

```
배너 출력 → parse_nodes (master 0개 시 exit 1, 1/3 이외 경고)
→ print_node_summary → check_ssh_pub_key → load_pull_secret
→ load_ca_cert → prepare_output_dir → generate_install_config
```

---

### 6-6. `air-gapped/06_create_agent_config.sh`

**목적**: Agent-Based Install용 `agent-config.yaml` 생성
**출력**: `${CLUSTER_DIR}/orig/agent-config.yaml`

#### 생성 내용

```yaml
apiVersion: v1alpha1
kind: AgentConfig
metadata:
  name: {CLUSTER_NAME}
rendezvousIP: {첫 번째 master IP}
hosts:
- hostname: {hostname}
  role: {master|worker}
  interfaces:
  - name: {nic}
    macAddress: {mac}
  networkConfig:
    interfaces:
    - name: {nic}
      type: ethernet
      state: up
      mac-address: {mac}
      ipv4:
        enabled: true
        address:
        - ip: {ip}
          prefix-length: {MACHINE_NETWORK의 prefix}
        dhcp: false
    dns-resolver:
      config:
        server:
        - {DNS_SERVERS[0]}
        - {DNS_SERVERS[1]}   ← DNS_SERVERS 배열 순서대로
    routes:
      config:
      - destination: 0.0.0.0/0
        next-hop-address: {GATEWAY}
        next-hop-interface: {nic}
        table-id: 254
```

`write_host_entry(role, hostname, ip, nic, mac, prefix_length)`: 단일 노드 엔트리를 `OUTPUT_FILE` 에 append

#### main() 실행 순서

```
배너 출력 → parse_nodes → print_summary → prepare_output_dir → generate_agent_config
```

---

### 6-7. `air-gapped/07_create_config_yaml.sh`

**목적**: 클러스터 설치 후 적용할 매니페스트 파일 생성
**출력**: `${CLUSTER_DIR}/orig/openshift/` 하위 6개 파일

#### 생성 파일 목록

| 파일 | 종류 | 내용 |
|------|------|------|
| `operatorhub-disabled.yaml` | `OperatorHub` | `disableAllDefaultSources: true` |
| `sample-operator.yaml` | `samples.operator.openshift.io/v1 Config` | `managementState: Removed` (air-gap 불필요) |
| `cs-redhat-operator-index.yaml` | `CatalogSource` | `image: {MIRROR_REGISTRY}/olm-redhat/redhat/redhat-operator-index:v{OCP_MAJOR_VERSION}` |
| `idms-olm-redhat.yaml` | `ImageDigestMirrorSet` | `source: registry.redhat.io` → `mirrors: {MIRROR_REGISTRY}/olm-redhat` |
| `master-kubeletconfig.yaml` | `KubeletConfig` | `autoSizingReserved: true`, `logLevel: 3` (master pool) |
| `worker-kubeletconfig.yaml` | `KubeletConfig` | `autoSizingReserved: true`, `logLevel: 3` (worker pool) |

`write_manifest(filename, content)`: `cat > "${MANIFEST_DIR}/${filename}"` 로 파일 생성

---

### 6-8. `air-gapped/08_create_cluster_manifests.sh`

**목적**: `orig/` 파일을 클러스터 디렉토리로 복사 후 `openshift-install agent create cluster-manifests` 실행

#### 함수 목록

| 함수 | 내용 |
|------|------|
| `check_prerequisites()` | `ORIG_DIR` 존재, `install-config.yaml`, `agent-config.yaml` 존재, `openshift-install` PATH 확인 |
| `copy_orig_files()` | `install-config.yaml`, `agent-config.yaml` 복사, `openshift/` 디렉토리 복사 (기존 삭제 후) |
| `create_cluster_manifests()` | `openshift-install agent create cluster-manifests --dir "${CLUSTER_DIR}"` |

#### main() 실행 순서

```
배너 출력 → check_prerequisites → copy_orig_files → create_cluster_manifests
```

---

### 6-9. `air-gapped/09_create_agent_iso.sh`

**목적**: Agent ISO 생성 및 이름 변경

#### 함수 목록

| 함수 | 내용 |
|------|------|
| `check_prerequisites()` | `cluster-manifests/` 디렉토리 존재, `openshift-install` PATH 확인 |
| `create_agent_iso()` | `openshift-install agent create image --dir "${CLUSTER_DIR}"` |
| `rename_iso()` | `agent.x86_64.iso` → `ocp-v{OCP_VERSION}-agent.x86_64.iso` |

#### main() 실행 순서

```
배너 출력 → check_prerequisites → create_agent_iso → rename_iso
```

---

### 6-10. `air-gapped/10_monitor_install.sh`

**목적**: Agent ISO 부팅 후 설치 진행 모니터링

#### 함수 목록

| 함수 | 내용 |
|------|------|
| `check_prerequisites()` | `CLUSTER_DIR` 존재, `openshift-install` PATH 확인 |
| `get_rendezvous_ip()` | `orig/agent-config.yaml` 에서 `grep -m1 'address:'` 로 첫 번째 IP 추출 |
| `wait_bootstrap_complete()` | `openshift-install agent wait-for bootstrap-complete --dir "${CLUSTER_DIR}" --log-level info` |
| `wait_install_complete()` | `openshift-install agent wait-for install-complete --dir "${CLUSTER_DIR}" --log-level info` → kubeadmin password 출력 |

#### main() 실행 순서

```
배너 출력 → check_prerequisites → wait_bootstrap_complete → wait_install_complete
```

---

## 7. Add-Nodes 스크립트

### 7-1. `add-nodes/01_create_nodes_config.sh`

**목적**: 기존 클러스터에 워커 노드 추가용 `nodes-config.yaml` 생성
**출력**: `${CLUSTER_DIR}/orig/nodes-config.yaml`

- `ADD_NODES` 배열 파싱 (NODES와 동일 형식)
- agent-config.yaml과 동일한 NMState 네트워크 구조
- `apiVersion: v1alpha1`, `kind: NodeConfig`

```yaml
apiVersion: v1alpha1
kind: NodeConfig
metadata:
  name: {CLUSTER_NAME}
hosts:
- hostname: {hostname}
  role: {role}
  interfaces: ...
  networkConfig: ...
```

#### main() 실행 순서

```
배너 출력 → parse_nodes (ADD_NODES 파싱, 0개 시 exit 1)
→ print_summary → prepare_output_dir → generate_nodes_config
```

---

### 7-2. `add-nodes/02_create_nodes_iso.sh`

**목적**: 운영 중인 클러스터에서 pull-secret 추출 후 `oc adm node-image create` 로 ISO 생성
**사전 조건**: `oc login` 완료

#### 변수

```bash
ORIG_NODES_CONFIG="${CLUSTER_DIR}/orig/nodes-config.yaml"
DEST_NODES_CONFIG="${CLUSTER_DIR}/nodes-config.yaml"
PULL_SECRET_FILE="${CLUSTER_DIR}/cluster-pull-secret.txt"
ISO_SRC="${CLUSTER_DIR}/node.x86_64.iso"
ISO_DEST="${CLUSTER_DIR}/ocp-v${OCP_VERSION}-add-nodes.x86_64.iso"
```

#### 함수 목록

| 함수 | 내용 |
|------|------|
| `preflight_check()` | `nodes-config.yaml` 존재, `oc` PATH 확인, `oc whoami` 로그인 확인 |
| `copy_nodes_config()` | `orig/nodes-config.yaml` → `cluster_dir/nodes-config.yaml` |
| `fetch_pull_secret()` | `oc -n openshift-config get secret pull-secret -o jsonpath=... | base64 -d` → `cluster-pull-secret.txt` |
| `create_iso()` | `oc adm node-image create --dir="${CLUSTER_DIR}" -a "${PULL_SECRET_FILE}"` → `node.x86_64.iso` → rename |

#### main() 실행 순서

```
배너 출력 → preflight_check → copy_nodes_config → fetch_pull_secret → create_iso
```

---

## 8. Add-Operators 스크립트

### 8-1. `add-operators/01_create_add_operators_isc.sh`

**목적**: 운영 중인 OCP4 클러스터에 Operator를 추가 설치할 때 사용할 ISC 파일 생성
**특징**: 실행마다 타임스탬프(`YYYYMMDD-HHMMSS`) 디렉토리를 새로 생성하므로 기존 결과물을 덮어쓰지 않음

#### 전역 변수

```bash
RUN_ID=""    # date +%Y%m%d-%H%M%S 로 초기화
RUN_DIR=""   # ADD_OPERATORS_MIRROR_DIR/RUN_ID
RENDER_CACHE_DIR=""  # mktemp -d, EXIT 시 자동 삭제
```

#### 함수 목록

| 함수 | 내용 |
|------|------|
| `check_add_operators()` | `ADD_OPERATORS` 배열이 비어있으면 `exit 1`, 목록 출력 |
| `init_render_cache()` | `mktemp -d` 로 임시 디렉토리 생성, `trap EXIT` 으로 자동 삭제 |
| `_render_catalog(catalog_url)` | `opm render {catalog} -o json` 으로 카탈로그 렌더링 (캐시 있으면 스킵) |
| `get_default_channel(catalog_url, pkg)` | `jq` 로 `olm.package` 에서 `defaultChannel` 조회, 실패 시 `"stable"` 반환 |
| `_write_isc(dir, file, catalog_url, catalog_type)` | 카탈로그 타입 일치 패키지를 `ADD_OPERATORS` 에서 필터링 후 ISC YAML 생성 |
| `create_isc_files()` | redhat/certified/community 3개 카탈로그에 대해 `_write_isc` 호출 |

#### 생성되는 ISC 파일

```
{ADD_OPERATORS_MIRROR_DIR}/{YYYYMMDD-HHMMSS}/
├── olm-redhat/add-redhat-isc.yaml
├── olm-certified/add-certified-isc.yaml
└── olm-community/add-community-isc.yaml
```

해당 카탈로그에 포함할 패키지가 없으면 해당 디렉토리/파일은 생성하지 않음.

#### main() 실행 순서

```
RUN_ID/RUN_DIR 초기화
→ jq/opm 설치 확인 (미설치 시 warn, stable 로 대체)
→ check_add_operators
→ init_render_cache
→ create_isc_files
→ 완료 출력 (RUN_ID, 다음 단계 명령어 안내)
```

---

### 8-2. `add-operators/02_mirror_add_operators.sh`

**목적**: `01_create_add_operators_isc.sh` 로 생성한 ISC 파일을 사용하여 이미지 다운로드

**사용법**:
```bash
./02_mirror_add_operators.sh              # 기존 RUN_ID 목록에서 선택
./02_mirror_add_operators.sh YYYYMMDD-HHMMSS  # RUN_ID 직접 지정
```

#### ISC 매핑

```bash
declare -A ISC_FILES=(
    ["olm-redhat"]="add-redhat-isc.yaml"
    ["olm-certified"]="add-certified-isc.yaml"
    ["olm-community"]="add-community-isc.yaml"
)
ISC_ORDER=("olm-redhat" "olm-certified" "olm-community")
```

#### 함수 목록

| 함수 | 내용 |
|------|------|
| `check_prerequisites()` | `PULL_SECRET_FILE` 존재, `oc-mirror` PATH 확인 |
| `select_run(arg_run_id)` | CLI 인자 있으면 직접 사용, 없으면 `ADD_OPERATORS_MIRROR_DIR` 하위 타임스탬프 디렉토리 목록을 최신순으로 표시 후 선택 |
| `select_target()` | `RUN_DIR` 내 존재하는 ISC 파일 목록만 표시, 카탈로그 개별 또는 all 선택 |
| `run_mirror(target)` | `oc-mirror --v2 --config --cache-dir --authfile file://{isc_dir}` 실행 |

#### `run_mirror` 상세

```bash
oc-mirror \
    --v2 \
    --config "${RUN_DIR}/${target}/${ISC_FILES[target]}" \
    --cache-dir "${ADD_OPERATORS_CACHE_DIR}/${RUN_ID}/${target}" \
    --authfile "${PULL_SECRET_FILE}" \
    "file://${RUN_DIR}/${target}"
```

#### main() 실행 순서

```
check_prerequisites
→ select_run (CLI 인자 또는 목록 선택)
→ select_target (RUN_DIR 내 존재하는 카탈로그 선택)
→ run_mirror (단일 or 전체 순서대로)
→ 성공/실패 집계 출력 (RUN_ID 포함)
```

---

## 9. ISC YAML 포맷 명세

**API 버전**: `mirror.openshift.io/v2alpha1` (oc-mirror v2, OCP 4.14+ 권장)

### OCP Platform ISC

```yaml
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  platform:
    channels:
    - name: stable-4.20
      minVersion: 4.20.14
      maxVersion: 4.20.14
      shortestPath: true
    graph: true
```

### OLM ISC 공통 구조

```yaml
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  operators:
  - catalog: registry.redhat.io/redhat/redhat-operator-index:v4.20
    packages:
    - name: nfd
      channels:
      - name: stable          ← channel 조회 성공 시
    - name: kubevirt-hyperconverged
                              ← channel 조회 실패 시 channels 블록 없음
  additionalImages:           ← olm-redhat ISC에만 포함
  - name: registry.redhat.io/ubi9/ubi:latest
```

---

## 10. Operator 카탈로그 매핑

| Operator | Catalog | 그룹 |
|----------|---------|------|
| `nfd` | redhat | GPU |
| `gpu-operator-certified` | certified | GPU |
| `nvidia-network-operator` | certified | GPU |
| `kubevirt-hyperconverged` | redhat | Virt |
| `local-storage-operator` | redhat | Virt |
| `mtc-operator` | redhat | Virt |
| `mtv-operator` | redhat | Virt |
| `redhat-oadp-operator` | redhat | Virt |
| `fence-agents-remediation` | redhat | Virt |
| `openshift-gitops-operator` | redhat | CI/CD |
| `rhbk-operator` | redhat | CI/CD |
| `openshift-pipelines-operator-rh` | redhat | CI/CD |
| `elasticsearch-eck-operator-certified` | certified | Base |
| `web-terminal` | redhat | Base |
| `kubernetes-nmstate-operator` | redhat | Base |
| `node-healthcheck-operator` | redhat | Base |
| `self-node-remediation` | redhat | Base |
| `cincinnati-operator` | redhat | Base |
| `cluster-logging` | redhat | Base |
| `devworkspace-operator` | redhat | Base |
| `loki-operator` | redhat | Base |
| `netobserv-operator` | redhat | Base |
| `metallb-operator` | redhat | Base |

---

## 11. 다운로드 파일 목록

| 파일 | URL | 설치 경로 |
|------|-----|-----------|
| `openshift-client-linux-amd64-rhel9.tar.gz` | `OCP_CLIENT_URL` | `oc`, `kubectl` → `/usr/local/bin/` |
| `oc-mirror.rhel9.tar.gz` | `OCP_CLIENT_URL` | `oc-mirror` → `/usr/local/bin/` |
| `openshift-install-linux.tar.gz` | `OCP_CLIENT_URL` | `openshift-install` → `/usr/local/bin/` |
| `opm-linux-rhel9.tar.gz` | `OCP_CLIENT_URL` | `opm` → `/usr/local/bin/` |
| `butane-amd64` | `BUTANE_URL` (단일 바이너리) | `butane` → `/usr/local/bin/` |
| `helm-linux-amd64.tar.gz` | `HELM_URL` | `helm` → `/usr/local/bin/` |

---

## 12. 전체 실행 흐름

```
[사전 준비]
  1. config.env 에서 CLUSTER_NAME, BASE_DOMAIN, NODES, 네트워크 등 설정
  2. pull-secret.txt 를 BASE_DIR 에 저장

[Connected 환경]
  Step 1. sudo bash connected/01_download_ocp_tools.sh
           → RHEL9/root/디스크/인터넷 확인
           → OCP 도구 4종 + Butane + Helm 다운로드
           → /usr/local/bin/ 설치 및 검증

  Step 2. bash connected/02_create_isc.sh
           → skopeo/jq/podman 확인 및 자동 설치
           → Pull Secret 검증
           → ISC 유형 선택 (1~5번 메뉴)
           → OLM 선택 시 Operator 그룹 y/N 질문 (Base 자동 포함)
           → default channel 조회 후 ISC YAML 생성
           → {CLUSTER_NAME}/ocp|olm-redhat|olm-certified|olm-community/ 에 저장

  Step 3. bash connected/03_mirror_images.sh
           → ISC 파일 목록 확인
           → 미러링 대상 선택 (1~5번 메뉴)
           → oc-mirror --v2 실행
           → {BASE_DIR}/mirror/{target}/ 에 저장

[데이터 전송]
  Step 4. rsync 또는 외장 드라이브로 아래 경로를 air-gap 환경으로 전송:
           - downloads/  (CLI 도구)
           - mirror/     (이미지 미러링 결과)
           - {CLUSTER_NAME}/  (ISC 파일)

[Air-Gapped 환경]
  Step 1. sudo bash air-gapped/01_install_tools.sh
           → downloads/ 에서 CLI 도구 설치

  Step 2. bash air-gapped/02_create_certs.sh
           → CA 인증서 생성 (메뉴 1)
           → Mirror Registry 서버 인증서 생성 (메뉴 2)

  Step 3. sudo bash air-gapped/03_create_registry.sh
           → Podman registry:2 컨테이너 + TLS + htpasswd
           → systemd 서비스 등록 + 방화벽 오픈

  Step 4. bash air-gapped/04_upload_mirror.sh
           → mirror/ 의 이미지를 내부 Registry 로 업로드
           → oc-mirror --v2 --from file:// --to docker://

  Step 5. bash air-gapped/05_create_install_config.sh
           → NODES 파싱 → install-config.yaml 생성

  Step 6. bash air-gapped/06_create_agent_config.sh
           → NODES + NMState → agent-config.yaml 생성

  Step 7. bash air-gapped/07_create_config_yaml.sh
           → OperatorHub 비활성화, CatalogSource, IDMS, KubeletConfig 매니페스트 생성

  Step 8. bash air-gapped/08_create_cluster_manifests.sh
           → orig/ → cluster_dir/ 복사
           → openshift-install agent create cluster-manifests

  Step 9. bash air-gapped/09_create_agent_iso.sh
           → openshift-install agent create image
           → ocp-v{OCP_VERSION}-agent.x86_64.iso 생성

  Step 10. bash air-gapped/10_monitor_install.sh
            → 모든 노드 ISO 부팅 후 실행
            → wait-for bootstrap-complete → wait-for install-complete
            → kubeadmin password 출력

[노드 추가 (선택)]
  bash add-nodes/01_create_nodes_config.sh
       → ADD_NODES → nodes-config.yaml

  bash add-nodes/02_create_nodes_iso.sh
       → oc login 후 pull-secret 추출
       → oc adm node-image create → ocp-v{OCP_VERSION}-add-nodes.x86_64.iso

[Operator 추가 (선택)]
  # config.env 의 ADD_OPERATORS 배열에 추가할 Operator 목록 설정 후 실행

  # [Connected 환경] ISC 파일 생성
  bash add-operators/01_create_add_operators_isc.sh
       → ADD_OPERATORS 카탈로그별 분류
       → mirror-added/{YYYYMMDD-HHMMSS}/olm-*/add-*-isc.yaml 생성
       → 완료 시 RUN_ID 출력

  # [Connected 환경] 이미지 미러링
  bash add-operators/02_mirror_add_operators.sh [RUN_ID]
       → RUN_ID 선택 또는 직접 지정
       → 카탈로그 선택 (개별 or all)
       → oc-mirror --v2 실행
       → mirror-added/{RUN_ID}/{target}/ 에 저장

  # [데이터 전송] air-gap 환경으로 전송
  rsync -avzP ./mirror-added/ user@air-gap-server:/path/to/mirror-added/

  # [Air-Gapped 환경] Registry 업로드
  # 04_upload_mirror.sh 방식으로 mirror-added/{RUN_ID}/ 의 이미지를 Registry 에 업로드
```

---

## 13. 에러 처리 공통 원칙

| 상황 | 처리 방식 |
|------|----------|
| 사전 검사 실패 (OS, 권한, 파일 미존재) | `echo "[ERROR] ..."` + `exit 1` |
| 파일 이미 존재 (다운로드 건너뜀) | `log_warn` / `echo "[WARN]"` + `continue` |
| tar 압축 해제 실패 | `continue` (다음 파일 계속) |
| channel 조회 실패 | warn 출력 + 빈 channel로 ISC 생성 계속 |
| 미러링/업로드 실패 (단일 대상) | `return 1` + 다음 대상 계속, 최종 실패 집계 |
| 디스크 공간 부족 (< 50GB) | warn + (y/N) 확인, N이면 `exit 0` |
| CA 인증서 덮어쓰기 | 기존 존재 시 (y/N) 확인 |
| `set -euo pipefail` | 예상치 못한 명령 실패 시 즉시 종료 (일부 스크립트는 `set -uo pipefail`) |
