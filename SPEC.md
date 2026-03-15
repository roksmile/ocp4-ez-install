# OCP4 Air-Gap Easy Install — 스크립트 명세서

> **목적**: 이 문서는 `ocp4-ez-install` 프로젝트의 모든 스크립트에 대한 완전한 구현 명세입니다.
> 다른 AI 또는 개발자가 이 문서만으로 동일한 스크립트를 재현하거나 수정할 수 있도록 작성되었습니다.

---

## 1. 프로젝트 개요

Air-gap(인터넷 차단) 환경에서 OpenShift Container Platform 4(OCP4)를 설치하기 위한 쉘 스크립트 모음.
인터넷이 연결된 서버에서 필요한 도구와 이미지를 다운로드한 뒤, 그 결과물을 air-gap 환경으로 옮겨 설치하는 2단계 구조.

### 환경 정보

| 항목 | 값 |
|------|-----|
| 설치 OCP 버전 | 4.20.14 |
| 서버 OS | RHEL 9 |
| 서버 HW | KVM 기반 VM |
| 스토리지 | `/data` 1000GB |
| 아키텍처 | x86_64 |

---

## 2. 디렉토리 구조

```
ocp4-ez-install/                        ← 프로젝트 루트 (BASE_DIR)
├── config.env                          ← 공통 환경설정 파일
├── connected/                          ← 인터넷 연결 환경 스크립트
│   ├── 01_download_ocp_tools.sh
│   ├── 02_create_isc.sh
│   └── 03_mirror_images.sh
├── air-gapped/                         ← 인터넷 차단 환경 스크립트 (현재 placeholder)
│   └── .gitkeep
└── {CLUSTER_NAME}/                     ← 02_create_isc.sh 가 자동 생성
    ├── ocp/
    │   └── ocp-isc.yaml
    ├── olm-redhat/
    │   └── olm-redhat-isc.yaml
    ├── olm-certified/
    │   └── olm-certified-isc.yaml
    └── olm-community/
        └── olm-community-isc.yaml
```

### 런타임 데이터 경로 (`/data` 기준)

```
/data/
├── downloads/       ← 다운로드된 tar.gz 원본 파일
├── mirror/          ← oc-mirror 결과물 (air-gap 환경으로 전송)
│   ├── ocp/
│   ├── olm-redhat/
│   ├── olm-certified/
│   └── olm-community/
└── logs/            ← 스크립트 실행 로그
```

---

## 3. 공통 규칙

### 3-1. Bash 스크립트 공통 헤더

모든 `.sh` 파일 첫 줄: `#!/usr/bin/env bash`
두 번째 줄: `set -euo pipefail`
세 번째: `config.env` 소스 로드

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"   # connected/ 스크립트 기준
```

### 3-2. 색상 코드 (모든 스크립트 공통 선언)

```bash
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'   # 02, 03 스크립트만 추가
readonly BOLD='\033[1m'
readonly NC='\033[0m'
```

### 3-3. 로깅 함수 (모든 스크립트 공통)

모든 출력은 `tee -a "${LOG_FILE}"` 로 화면과 파일 동시 기록.

```bash
log_info()    { echo -e "${GREEN}[INFO]${NC}  $(date '+%H:%M:%S') $*" | tee -a "${LOG_FILE}"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $(date '+%H:%M:%S') $*" | tee -a "${LOG_FILE}"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $*" | tee -a "${LOG_FILE}"; }
log_section() { echo -e "\n${BLUE}${BOLD}========== $* ==========${NC}" | tee -a "${LOG_FILE}"; }
log_success() { echo -e "${CYAN}[OK]${NC}    $(date '+%H:%M:%S') $*" | tee -a "${LOG_FILE}"; }
```

`init_logging()`: `mkdir -p "${LOG_DIR}"` 후 로그 파일 경로 출력.

---

## 4. `config.env` 명세

**위치**: 프로젝트 루트
**용도**: connected/와 air-gapped/ 양쪽 스크립트가 `source` 하는 공통 설정 파일
**셔뱅**: `#!/usr/bin/env bash` (직접 실행하지 않고 source 전용)

### 4-1. 변수 목록

#### OpenShift 버전

| 변수 | 값 | 설명 |
|------|----|------|
| `OCP_VERSION` | `4.20.14` | 전체 버전 문자열 |
| `OCP_MAJOR_VERSION` | `4.20` | Catalog 태그에 사용 |
| `OCP_CHANNEL` | `stable-4.20` | ISC platform channel 이름 |

#### 클러스터 기본 설정

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `CLUSTER_NAME` | `ocp-cluster` | ISC 하위 디렉토리 이름으로 사용됨 |
| `BASE_DOMAIN` | `example.com` | 클러스터 베이스 도메인 |

#### 디렉토리 설정

| 변수 | 값 | 설명 |
|------|----|------|
| `BASE_DIR` | `$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)` | config.env 위치 기준 자동 설정 |
| `DATA_DIR` | `/data` | 데이터 루트 |
| `DOWNLOAD_DIR` | `${DATA_DIR}/downloads` | 다운로드 원본 저장 |
| `MIRROR_DIR` | `${DATA_DIR}/mirror` | oc-mirror 결과물 저장 |
| `LOG_DIR` | `${DATA_DIR}/logs` | 로그 디렉토리 |
| `CLUSTER_DIR` | `${BASE_DIR}/${CLUSTER_NAME}` | ISC 파일 저장 위치 |

#### Mirror Registry (air-gap용, 기본값 비어있음)

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `MIRROR_REGISTRY_HOST` | `""` | 예: registry.example.com |
| `MIRROR_REGISTRY_PORT` | `8443` | |
| `MIRROR_REGISTRY` | `${MIRROR_REGISTRY_HOST}:${MIRROR_REGISTRY_PORT}` | |
| `MIRROR_REGISTRY_USER` | `init` | |
| `MIRROR_REGISTRY_PASS` | `""` | |

#### 인증

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `PULL_SECRET_FILE` | `${HOME}/.config/ocp-pull-secret.json` | Red Hat Pull Secret 파일 경로 |
| `REDHAT_REGISTRY_USER` | `""` | 선택사항, pull-secret 있으면 불필요 |
| `REDHAT_REGISTRY_PASS` | `""` | |

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

**Base Operators** (OLM ISC 생성 시 항상 포함, 기본값 빈 배열)

```bash
REDHAT_BASE_OPERATORS=()
CERTIFIED_BASE_OPERATORS=()
```

**GPU Operators**

```bash
REDHAT_GPU_OPERATORS=("nfd")
CERTIFIED_GPU_OPERATORS=("nvidia-gpu-operator" "nvidia-network-operator")
```

**Virtualization Operators**

```bash
REDHAT_VIRT_OPERATORS=(
    "kubevirt-hyperconverged" "local-storage-operator"
    "mtc-operator" "mtv-operator"
    "redhat-oadp-operator" "fence-agents-remediation"
)
CERTIFIED_VIRT_OPERATORS=()
```

**CI/CD Operators**

```bash
REDHAT_CICD_OPERATORS=(
    "openshift-gitops-operator" "rhbk-operator"
    "openshift-pipelines-operator-rh" "web-terminal"
)
CERTIFIED_CICD_OPERATORS=()
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

> `OCP_TOOL_FILES`에 Helm은 포함하지 않음. Helm은 별도 URL(`HELM_URL`)에서 다운로드.

---

## 5. `connected/01_download_ocp_tools.sh` 명세

**목적**: OCP 설치에 필요한 CLI 바이너리를 다운로드하고 `/usr/local/bin/` 에 설치
**실행 권한**: root 필수 (`sudo bash`)
**실행 순서**: Step 1

### 5-1. 사전 검사 함수

#### `check_root()`
- `$EUID -ne 0` 이면 에러 메시지 출력 후 `exit 1`

#### `check_os_version()`
- `/etc/os-release` 없으면 `exit 1`
- `/etc/os-release` source 후 `$ID != "rhel"` 이면 `exit 1`
- `VERSION_ID` 에서 major 버전 추출(`cut -d. -f1`), `!= "9"` 이면 `exit 1`
- 통과 시 `log_success "OS 검사 통과: ${PRETTY_NAME}"`

#### `check_disk_space()`
- `mkdir -p "${DATA_DIR}"`
- `df -BG "${DATA_DIR}" | tail -1 | awk '{gsub("G",""); print $4}'` 로 가용 공간(GB) 확인
- `< 10` GB 이면 `exit 1`

#### `check_internet()`
- `curl -fsS --connect-timeout 10 --max-time 15 -o /dev/null "https://mirror.openshift.com"` 실패 시 `exit 1`

### 5-2. 디렉토리 생성

#### `create_directories()`
- `"${DOWNLOAD_DIR}" "${MIRROR_DIR}" "${LOG_DIR}" "${CLUSTER_DIR}"` 를 `mkdir -p` 로 생성

### 5-3. 다운로드 함수

#### `download_file(url, output, description)`
- `curl -fL --retry 3 --retry-delay 5 --connect-timeout 30 --progress-bar -o "${output}" "${url}"`
- 성공 시 `du -sh` 로 파일 크기 출력
- 실패 시 `rm -f "${output}"` 후 `return 1`

#### `download_ocp_tools()`
- `OCP_TOOL_FILES` 배열을 순회
- 각 파일: `url = ${OCP_CLIENT_URL}/${filename}`, `output = ${DOWNLOAD_DIR}/${filename}`
- 파일이 이미 존재하면 `log_warn` 출력 후 건너뜀
- `tool_descriptions` associative array 로 사람이 읽기 쉬운 이름 매핑:
  ```
  openshift-client-linux-amd64-rhel9.tar.gz → "OpenShift Client (oc, kubectl)"
  oc-mirror.rhel9.tar.gz                    → "OC Mirror"
  openshift-install-linux.tar.gz            → "OpenShift Installer"
  opm-linux-rhel9.tar.gz                    → "OPM (Operator Package Manager)"
  ```

#### `download_butane()`
- `output = ${DOWNLOAD_DIR}/butane-amd64`
- URL: `${BUTANE_URL}`
- 이미 존재하면 건너뜀

#### `download_helm()`
- `filename = "helm-linux-amd64.tar.gz"`
- `output = ${DOWNLOAD_DIR}/${filename}`
- URL: `${HELM_URL}`
- 이미 존재하면 `log_warn` (강제 재다운로드 방법 안내 포함) 후 건너뜀

### 5-4. 압축 해제 및 설치

#### `extract_and_install_tools()`
- `tmp_dir=$(mktemp -d /tmp/ocp-install-XXXXXX)`, `trap "rm -rf '${tmp_dir}'" RETURN` 로 정리 보장
- `archives` 배열:
  ```
  openshift-client-linux-amd64-rhel9.tar.gz
  oc-mirror.rhel9.tar.gz
  openshift-install-linux.tar.gz
  opm-linux-rhel9.tar.gz
  helm-linux-amd64.tar.gz
  ```
- 각 archive: 파일 없으면 `log_warn` 후 `continue`, `tar -xzf ... -C "${tmp_dir}"` 실패 시 `continue`
- `known_binaries=("oc" "kubectl" "oc-mirror" "openshift-install" "opm" "helm")`
- `find "${tmp_dir}" -maxdepth 3 -type f -executable -print0` 로 추출된 실행파일 탐색
- known_binaries 에 이름이 일치하면 `install -m 755 "${bin_path}" "${install_dir}/${bin_name}"`
- **Butane 별도 처리**: tar.gz가 아닌 단일 바이너리이므로 `${DOWNLOAD_DIR}/butane-amd64` → `install -m 755 ... "${install_dir}/butane"`

### 5-5. 설치 검증

#### `verify_installations()`
- 검증 대상: `("oc" "oc-mirror" "openshift-install" "opm" "helm" "butane")`
- `printf "%-20s %-15s %s\n"` 형식으로 표 출력
- 도구별 버전 확인 명령:

| 도구 | 버전 확인 명령 |
|------|---------------|
| `oc` | `oc version --client \| grep "Client Version" \| awk '{print $NF}'` |
| `oc-mirror` | `oc-mirror version \| grep -i version \| head -1 \| awk '{print $NF}'` |
| `openshift-install` | `openshift-install version \| head -1 \| awk '{print $2}'` |
| `opm` | `opm version \| head -1 \| awk '{print $2}'` |
| `helm` | `helm version --short \| head -1` |
| `butane` | `butane --version \| head -1` |

- 하나라도 미설치이면 `exit 1`

### 5-6. `main()` 실행 순서

```
print_banner → init_logging
→ check_root → check_os_version → check_disk_space → check_internet
→ create_directories
→ download_ocp_tools → download_butane → download_helm
→ extract_and_install_tools
→ verify_installations
```

---

## 6. `connected/02_create_isc.sh` 명세

**목적**: oc-mirror v2 용 ImageSetConfiguration YAML 파일 생성
**실행 권한**: 일반 사용자 가능 (dnf install 시 root 필요)
**실행 순서**: Step 2

### 6-1. 전역 변수

```bash
declare -a SELECTED_REDHAT_OPERATORS=()
declare -a SELECTED_CERTIFIED_OPERATORS=()
declare -a SELECTED_COMMUNITY_OPERATORS=()
```

### 6-2. 사전 검사 함수

#### `check_prerequisites()`
- `required_tools=("oc" "oc-mirror" "skopeo" "jq" "podman" "curl")`
- 누락 도구 있으면 `install_prerequisites()` 호출

#### `install_prerequisites()`
- `packages=("skopeo" "jq" "podman")`
- `dnf` 우선, 없으면 `yum`, 둘 다 없으면 `exit 1`
- 실패 시 수동 설치 명령 안내 후 `exit 1`

#### `check_pull_secret()`
- `${PULL_SECRET_FILE}` 없으면 다운로드 방법 안내 후 `exit 1`
- `jq -e '.'` 로 JSON 형식 검증, 실패 시 `exit 1`
- `jq -e '.auths["registry.redhat.io"]'` 로 인증 정보 존재 확인, 실패 시 `exit 1`
- `~/.docker/config.json` 없으면 pull-secret 파일 복사 (oc-mirror 가 이 경로를 사용)

### 6-3. ISC 디렉토리 생성

#### `create_isc_directories()`
- 다음 4개 디렉토리를 `mkdir -p` 로 생성:
  ```
  ${CLUSTER_DIR}/ocp
  ${CLUSTER_DIR}/olm-redhat
  ${CLUSTER_DIR}/olm-certified
  ${CLUSTER_DIR}/olm-community
  ```

### 6-4. Default Channel 조회

#### `get_default_channel(catalog, package)` → 문자열 반환
- `oc-mirror list operators --catalog="${catalog}" 2>/dev/null` 의 출력에서
  `awk -v pkg="${package}" '$1 == pkg { print $2; exit }'` 로 DEFAULT CHANNEL 컬럼 파싱
- 조회 실패(빈 문자열) 시: `log_warn` 후 빈 문자열 반환 → ISC에 channel 블록 없이 생성
- 조회 성공 시: `log_info "  ${package} -> default channel: ${channel}"`

#### `generate_package_yaml(name, channel)` → stdout
- `channel` 이 있으면:
  ```yaml
      - name: {name}
        channels:
        - name: {channel}
  ```
- `channel` 이 없으면:
  ```yaml
      - name: {name}
  ```

### 6-5. ISC YAML 생성 함수

#### `create_ocp_isc()`
- 출력 파일: `${CLUSTER_DIR}/ocp/ocp-isc.yaml`
- 내용 (heredoc):
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

#### `create_redhat_olm_isc()`
- `SELECTED_REDHAT_OPERATORS` 배열이 비어있으면 `log_warn` 후 `return 0`
- 출력 파일: `${CLUSTER_DIR}/olm-redhat/olm-redhat-isc.yaml`
- 헤더 작성 후, 각 operator에 대해 `get_default_channel` + `generate_package_yaml` 로 패키지 블록 append
- Catalog: `${REDHAT_OPERATOR_INDEX}`

#### `create_certified_olm_isc()`
- `SELECTED_CERTIFIED_OPERATORS` 배열이 비어있으면 `log_warn` 후 `return 0`
- 출력 파일: `${CLUSTER_DIR}/olm-certified/olm-certified-isc.yaml`
- Catalog: `${CERTIFIED_OPERATOR_INDEX}`
- 나머지 로직 동일

#### `create_community_olm_isc()`
- `SELECTED_COMMUNITY_OPERATORS` 배열이 비어있으면 `log_warn` 후 `return 0`
- 출력 파일: `${CLUSTER_DIR}/olm-community/olm-community-isc.yaml`
- Catalog: `${COMMUNITY_OPERATOR_INDEX}`
- 나머지 로직 동일

### 6-6. 메뉴 인터페이스

#### `print_divider()` / `print_header(title)`
- `print_divider`: `${BLUE}----...----${NC}` 줄 출력
- `print_header`: 빈 줄 + `${MAGENTA}${BOLD}${title}${NC}` + `print_divider`

#### `ask_yn(prompt)` → return 0(yes) or 1(no)
- `read -rp "  ${prompt} (y/N): " answer`
- `[[ "${answer}" =~ ^[Yy]$ ]]` — y 또는 Y 만 true(0)

#### `select_operator_groups()` — **y/n 방식**
실행 순서:
1. **Base Operators 초기 로드**: `REDHAT_BASE_OPERATORS`, `CERTIFIED_BASE_OPERATORS` 가 비어있지 않으면 `SELECTED_*` 에 추가
2. **GPU Operators 표시 후 질문**:
   - `RedHat: ${REDHAT_GPU_OPERATORS[*]}`, `Certified: ${CERTIFIED_GPU_OPERATORS[*]}` 출력
   - `ask_yn "GPU Operators 를 추가하겠습니까?"` → y면 양쪽 배열에 추가
3. **Virtualization Operators 표시 후 질문**:
   - `CERTIFIED_VIRT_OPERATORS` 이 비어있지 않을 때만 Certified 줄 출력
   - `ask_yn "Virtualization Operators 를 추가하겠습니까?"` → y면 추가
4. **CI/CD Operators 표시 후 질문**:
   - `CERTIFIED_CICD_OPERATORS` 이 비어있지 않을 때만 Certified 줄 출력
   - `ask_yn "CI/CD Operators 를 추가하겠습니까?"` → y면 추가
5. **중복 제거**: `mapfile -t ... < <(printf '%s\n' ... | sort -u)`
6. 최종 선택 목록 `log_info` 출력

> **ALL 옵션 없음.** 각 그룹을 독립적으로 y/N 질문.

#### `input_community_operators()`
- 쉼표 구분으로 패키지 이름 자유 입력
- Enter 입력 시 건너뜀
- 입력값을 `IFS=','` 로 분리, 공백 제거 후 `SELECTED_COMMUNITY_OPERATORS` 에 추가

#### `show_main_menu()` — 최상위 ISC 선택 메뉴
- 번호 입력 방식 (복수 선택 가능, 쉼표 구분)
- 선택지:
  ```
  [1] OCP Platform
  [2] RedHat OLM
  [3] Certified OLM
  [4] Community OLM
  [5] ALL (1+2+3+4)
  ```
- 입력 유효성: `^[1-5](,[1-5])*$` 정규식 검사, 실패 시 재입력
- `5` 선택 시 `menu_input="1,2,3,4"` 로 확장
- `2` 또는 `3` 선택 시 `need_operator_groups=true` → `select_operator_groups()` 호출
- `4` 선택 시 `need_community=true` → `input_community_operators()` 호출
- `create_isc_directories()` 호출 후 선택 번호에 따라 생성 함수 실행

#### `print_summary()`
- ISC 파일 4개의 존재 여부와 크기를 체크마크/대시로 출력
- 다음 단계(`03_mirror_images.sh`) 안내

### 6-7. `main()` 실행 순서

```
print_banner → init_logging
→ check_prerequisites → check_pull_secret
→ show_main_menu (내부에서 select_operator_groups, create_* 호출)
→ print_summary
```

---

## 7. `connected/03_mirror_images.sh` 명세

**목적**: ISC 파일을 사용해 `oc-mirror --v2` 로 이미지를 로컬 디스크에 미러링
**실행 권한**: 일반 사용자 가능
**실행 순서**: Step 3

### 7-1. 전역 변수

```bash
declare -gA ISC_MAP=(
    ["ocp"]="${CLUSTER_DIR}/ocp/ocp-isc.yaml"
    ["olm-redhat"]="${CLUSTER_DIR}/olm-redhat/olm-redhat-isc.yaml"
    ["olm-certified"]="${CLUSTER_DIR}/olm-certified/olm-certified-isc.yaml"
    ["olm-community"]="${CLUSTER_DIR}/olm-community/olm-community-isc.yaml"
)
declare -ga MIRROR_TARGETS=()
```

> `ISC_MAP`은 `check_isc_files()` 안에서 `declare -gA` 로 전역 선언

### 7-2. 사전 검사

#### `check_prerequisites()`
- `oc-mirror` 미설치 시 `exit 1`
- `${PULL_SECRET_FILE}` 없으면 `exit 1`
- `~/.docker/config.json` 없으면 pull-secret에서 복사

#### `check_isc_files()`
- ISC_MAP 의 4개 파일 존재 여부를 표로 출력 (`printf "%-20s %-10s %s\n"`)
- 4개 모두 없으면 `exit 1`

#### `check_disk_space()`
- `mkdir -p "${MIRROR_DIR}"`
- 가용 공간 `< 50` GB 이면 `log_warn` + 계속 진행 여부 `(y/N)` 질문
- N 이면 `exit 0`

### 7-3. 미러링 실행

#### `run_mirror(isc_name, isc_file)`
- `mirror_dest="${MIRROR_DIR}/${isc_name}"`
- ISC 파일 없으면 `return 1`
- `mkdir -p "${mirror_dest}"`
- `start_time=$(date +%s)` 기록
- 실행 명령:
  ```bash
  oc-mirror --v2 --config "${isc_file}" --log-level info "file://${mirror_dest}" 2>&1 | tee -a "${LOG_FILE}"
  ```
- 성공 시: 소요 시간(분/초), 저장 크기(`du -sh`), 저장 경로 출력
- 실패 시: `return 1`

### 7-4. 메뉴 인터페이스

#### `show_mirror_menu()`
- ISC_MAP 순서대로 4개 항목을 번호 메뉴로 출력
- 파일이 존재하면 ISC 파일 경로와 크기 표시, 없으면 `(ISC 파일 없음 - 건너뜀)` 황색 표시
- `[5] ALL (존재하는 ISC 전체 미러링)`
- 입력 유효성: `^[1-5](,[1-5])*$`
- `5` 선택 시 → `"1,2,3,4"` 확장
- 선택된 번호 → keys 배열 (`"ocp" "olm-redhat" "olm-certified" "olm-community"`) 인덱스 매핑
- ISC 파일 없는 항목은 `log_warn` 후 `MIRROR_TARGETS` 에서 제외
- 유효 대상 0개이면 `exit 1`

#### `confirm_mirror()`
- 미러링 대상, 저장 경로, 주의사항 출력
- `(y/N)` 확인, N 이면 `exit 0`

### 7-5. `main()` 실행 순서

```
print_banner → init_logging
→ check_prerequisites → check_isc_files → check_disk_space
→ show_mirror_menu → confirm_mirror
→ for target in MIRROR_TARGETS: run_mirror(target, ISC_MAP[target])
→ 성공/실패 집계 후 print_mirror_summary
```

#### `print_mirror_summary()`
- 미러 디렉토리 아래 각 서브 디렉토리 크기 출력
- 총 미러 크기(`du -sh "${MIRROR_DIR}"`) 출력
- 다음 단계 안내:
  1. `rsync -avzP ${MIRROR_DIR} user@air-gap-server:/data/` 또는 외장 드라이브 복사
  2. `air-gapped/` 스크립트로 Mirror Registry 구성 및 OCP 설치

---

## 8. ISC YAML 포맷 명세

**API 버전**: `mirror.openshift.io/v2alpha1` (oc-mirror v2, OCP 4.14+ 권장)

### OCP Platform ISC (`ocp-isc.yaml`)

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

### OLM ISC 공통 구조 (redhat / certified / community)

channel 조회 성공 시:
```yaml
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  operators:
  - catalog: registry.redhat.io/redhat/redhat-operator-index:v4.20
    packages:
    - name: nfd
      channels:
      - name: stable
    - name: kubevirt-hyperconverged
      channels:
      - name: stable
```

channel 조회 실패 시 (channel 블록 없음):
```yaml
    packages:
    - name: nfd
    - name: kubevirt-hyperconverged
```

---

## 9. Operator 카탈로그 매핑

| Operator | Catalog | 그룹 |
|----------|---------|------|
| `nfd` | redhat-operator-index | GPU |
| `nvidia-gpu-operator` | certified-operator-index | GPU |
| `nvidia-network-operator` | certified-operator-index | GPU |
| `kubevirt-hyperconverged` | redhat-operator-index | Virtualization |
| `local-storage-operator` | redhat-operator-index | Virtualization |
| `mtc-operator` | redhat-operator-index | Virtualization |
| `mtv-operator` | redhat-operator-index | Virtualization |
| `redhat-oadp-operator` | redhat-operator-index | Virtualization |
| `fence-agents-remediation` | redhat-operator-index | Virtualization |
| `openshift-gitops-operator` | redhat-operator-index | CI/CD |
| `rhbk-operator` | redhat-operator-index | CI/CD |
| `openshift-pipelines-operator-rh` | redhat-operator-index | CI/CD |
| `web-terminal` | redhat-operator-index | CI/CD |

---

## 10. 다운로드 파일 목록

| 파일 | URL 기반 경로 | 설치 위치 |
|------|--------------|-----------|
| `openshift-client-linux-amd64-rhel9.tar.gz` | `${OCP_CLIENT_URL}/` | `oc`, `kubectl` → `/usr/local/bin/` |
| `oc-mirror.rhel9.tar.gz` | `${OCP_CLIENT_URL}/` | `oc-mirror` → `/usr/local/bin/` |
| `openshift-install-linux.tar.gz` | `${OCP_CLIENT_URL}/` | `openshift-install` → `/usr/local/bin/` |
| `opm-linux-rhel9.tar.gz` | `${OCP_CLIENT_URL}/` | `opm` → `/usr/local/bin/` |
| `butane-amd64` | `${BUTANE_URL}` (단일 바이너리) | `butane` → `/usr/local/bin/` |
| `helm-linux-amd64.tar.gz` | `${HELM_URL}` | `helm` → `/usr/local/bin/` |

---

## 11. 실행 흐름 요약

```
[사전 준비]
  1. config.env 에서 CLUSTER_NAME, PULL_SECRET_FILE 등 설정
  2. Pull Secret 파일을 ${PULL_SECRET_FILE} 경로에 저장

[Step 1 - Connected 환경]
  sudo bash connected/01_download_ocp_tools.sh
    → RHEL9 확인 → 디스크/네트워크 확인
    → OCP 도구 4종 + Butane + Helm 다운로드 → /usr/local/bin/ 설치
    → 설치 검증 테이블 출력

[Step 2 - Connected 환경]
  bash connected/02_create_isc.sh
    → skopeo/jq/podman 확인 및 자동 설치
    → Pull Secret 검증
    → ISC 유형 선택 메뉴 (1~5)
    → OLM 선택 시 Operator 그룹 y/N 질문 (GPU / Virtualization / CI/CD)
    → default channel 조회 후 ISC YAML 파일 생성
    → ${CLUSTER_NAME}/ 하위에 ocp, olm-redhat, olm-certified, olm-community ISC 파일 생성

[Step 3 - Connected 환경]
  bash connected/03_mirror_images.sh
    → ISC 파일 목록 확인 (존재하는 것만 표시)
    → 미러링 대상 선택 메뉴 (1~5)
    → 확인 후 oc-mirror --v2 실행
    → /data/mirror/ 하위에 결과물 저장

[Step 4 - 데이터 전송]
  rsync 또는 외장 드라이브로 /data/mirror/ 를 air-gap 환경으로 전송

[Step 5 - Air-gapped 환경]
  air-gapped/ 스크립트로 Mirror Registry 구성 및 OCP 설치 (향후 구현)
```

---

## 12. 에러 처리 공통 원칙

| 상황 | 처리 방식 |
|------|----------|
| 사전 검사 실패 (OS, 권한, 디스크, 네트워크) | `log_error` + `exit 1` |
| 파일 이미 존재 (다운로드 건너뜀) | `log_warn` + `continue` |
| tar 압축 해제 실패 | `log_error` + `continue` (다음 파일 계속) |
| channel 조회 실패 | `log_warn` + 빈 channel로 ISC 생성 계속 |
| 미러링 실패 (단일 대상) | `log_error` + 다음 대상 계속 진행 |
| 50GB 미만 디스크 경고 | `log_warn` + `(y/N)` 확인, N이면 `exit 0` |
