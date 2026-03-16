# OCP4 Air-Gap Easy Install

Air-gap(인터넷 차단) 환경에서 OpenShift Container Platform 4를 쉽게 설치할 수 있는 쉘 스크립트 모음입니다.

인터넷이 연결된 서버에서 도구와 이미지를 다운로드/미러링한 뒤, 그 결과물을 air-gap 환경으로 옮겨 설치하는 2단계 구조입니다.

---

## 요구사항

| 항목 | 내용 |
|------|------|
| OS | RHEL 9 (x86_64) |
| OCP 버전 | 4.20.x |
| 설치 방식 | Agent-Based Install |
| 실행 권한 | root (도구 설치 시) |
| Pull Secret | Red Hat 계정 필요 |
| Connected 서버 디스크 | 500GB 이상 권장 |

---

## 디렉토리 구조

```
ocp4-ez-install/
├── config.env                          # 공통 환경설정 (모든 스크립트 공유)
├── connected/                          # 인터넷 연결 환경 스크립트
│   ├── 01_download_ocp_tools.sh        # OCP CLI 도구 다운로드 및 설치
│   ├── 02_create_isc.sh                # ImageSetConfiguration YAML 생성
│   └── 03_mirror_images.sh             # oc-mirror 로 이미지 미러링
├── air-gapped/                         # 인터넷 차단 환경 스크립트
│   ├── 01_install_tools.sh             # CLI 도구 설치 (downloads/ 사용)
│   ├── 02_create_certs.sh              # CA / 서버 인증서 생성
│   ├── 03_create_registry.sh           # Mirror Registry 구성 (Podman)
│   ├── 04_upload_mirror.sh             # 미러링 이미지 → Registry 업로드
│   ├── 05_create_install_config.sh     # install-config.yaml 생성
│   ├── 06_create_agent_config.sh       # agent-config.yaml 생성
│   ├── 07_create_config_yaml.sh        # 클러스터 매니페스트 생성
│   ├── 08_create_cluster_manifests.sh  # cluster-manifests 생성
│   ├── 09_create_agent_iso.sh          # Agent ISO 생성
│   └── 10_monitor_install.sh           # 설치 진행 모니터링
├── add-nodes/                          # 워커 노드 추가 스크립트
│   ├── 01_create_nodes_config.sh       # nodes-config.yaml 생성
│   └── 02_create_nodes_iso.sh          # 노드 추가용 ISO 생성
└── add-operators/                      # 운영 중 Operator 추가 스크립트
    ├── 01_create_add_operators_isc.sh  # 추가 Operator ISC 파일 생성
    └── 02_mirror_add_operators.sh      # 추가 Operator 이미지 미러링
```

---

## 시작하기 전에

### 1. config.env 설정

모든 스크립트가 공유하는 환경설정 파일입니다. 환경에 맞게 수정하세요.

```bash
vi config.env
```

주요 항목:

| 항목 | 설명 |
|------|------|
| `OCP_VERSION` | 설치할 OCP 버전 (예: `4.20.14`) |
| `CLUSTER_NAME` | 클러스터 이름 |
| `BASE_DOMAIN` | 클러스터 베이스 도메인 |
| `MIRROR_REGISTRY_HOST` | Air-gap 환경의 Mirror Registry 호스트명 |
| `PULL_SECRET_FILE` | Red Hat Pull Secret 파일 경로 |
| `NODES` | 노드 정의 배열 (`role\|hostname\|ip\|nic\|mac`) |
| `MACHINE_NETWORK` | 노드 IP 네트워크 대역 |
| `GATEWAY` | 기본 게이트웨이 |
| `DNS_SERVERS` | DNS 서버 목록 |
| `SSH_PUB_KEY` | 노드 접속용 SSH 공개 키 배열 |
| `ADD_OPERATORS` | 운영 중 클러스터에 추가할 Operator 목록 (`operator-name:catalog`) |

### 2. Pull Secret 저장

[Red Hat Console](https://console.redhat.com/openshift/install/pull-secret) 에서 Pull Secret을 다운로드하여 `config.env`의 `PULL_SECRET_FILE` 경로에 저장합니다.

```bash
cp ~/Downloads/pull-secret.txt ./pull-secret.txt
```

---

## 실행 순서

### [Connected 환경]

#### Step 1. OCP 도구 다운로드 및 설치

```bash
sudo bash connected/01_download_ocp_tools.sh
```

설치되는 도구: `oc`, `kubectl`, `oc-mirror`, `openshift-install`, `opm`, `butane`, `helm`

#### Step 2. ISC(ImageSetConfiguration) 파일 생성

```bash
bash connected/02_create_isc.sh
```

인터랙티브 메뉴에서 미러링할 대상을 선택합니다.

```
[1] OCP Platform
[2] RedHat OLM
[3] Certified OLM
[4] Community OLM
[5] ALL (1+2+3+4)
```

OLM 선택 시 Operator 그룹을 추가로 선택합니다 (y/N):

| 그룹 | 포함 Operator |
|------|-------------|
| Base (자동 포함) | cluster-logging, loki-operator, metallb-operator, nmstate 등 11종 |
| GPU | nfd, gpu-operator-certified, nvidia-network-operator |
| Virtualization | kubevirt-hyperconverged, local-storage-operator, mtc/mtv-operator, oadp, fence-agents |
| CI/CD | openshift-gitops, rhbk, openshift-pipelines |

생성되는 ISC 파일 위치:
```
{CLUSTER_NAME}/ocp/ocp-isc.yaml
{CLUSTER_NAME}/olm-redhat/olm-redhat-isc.yaml
{CLUSTER_NAME}/olm-certified/olm-certified-isc.yaml
{CLUSTER_NAME}/olm-community/olm-community-isc.yaml
```

#### Step 3. 이미지 미러링

```bash
bash connected/03_mirror_images.sh
```

인터랙티브 메뉴에서 미러링 대상을 선택합니다. 결과물은 `{BASE_DIR}/mirror/{target}/` 에 저장됩니다.

#### Step 4. Air-gap 환경으로 데이터 전송

```bash
# rsync 로 전송
rsync -avzP ./downloads/ user@air-gap-server:/path/to/downloads/
rsync -avzP ./mirror/ user@air-gap-server:/path/to/mirror/

# 또는 외장 드라이브에 복사
cp -r ./downloads ./mirror /mnt/external-drive/
```

---

### [Air-Gapped 환경]

#### Step 1. CLI 도구 설치

```bash
sudo bash air-gapped/01_install_tools.sh
```

`downloads/` 디렉토리의 파일을 사용하여 `/usr/local/bin/` 에 설치합니다.

#### Step 2. 인증서 생성

```bash
bash air-gapped/02_create_certs.sh
```

인터랙티브 메뉴:
1. CA 인증서 생성
2. Mirror Registry 서버 인증서 생성 (SAN 포함)
3. 생성된 인증서 목록 확인

인증서 저장 경로:
```
certs/{domain}/root_ca/ca.crt
certs/{domain}/domain_certs/{hostname}.crt
```

#### Step 3. Mirror Registry 구성

```bash
sudo bash air-gapped/03_create_registry.sh
```

- Podman 기반 `registry:2` 컨테이너 구성
- TLS + htpasswd 인증 적용
- systemd 서비스 등록 (`mirror-registry.service`)
- 방화벽 포트 오픈

#### Step 4. 이미지 업로드

```bash
bash air-gapped/04_upload_mirror.sh
```

`mirror/` 의 이미지를 내부 Mirror Registry 로 업로드합니다.

```
1) ocp           - OpenShift Platform 이미지
2) olm-redhat    - Red Hat Operator 이미지
3) olm-certified - Certified Operator 이미지
4) olm-community - Community Operator 이미지
5) add-images    - 추가 이미지
6) all           - 전체 업로드
```

#### Step 5. install-config.yaml 생성

```bash
bash air-gapped/05_create_install_config.sh
```

`config.env`의 `NODES`, 네트워크 설정, Pull Secret, CA 인증서를 사용하여 `{CLUSTER_NAME}/orig/install-config.yaml` 을 생성합니다.

#### Step 6. agent-config.yaml 생성

```bash
bash air-gapped/06_create_agent_config.sh
```

`config.env`의 `NODES` 배열을 파싱하여 각 노드의 NMState 네트워크 설정이 포함된 `{CLUSTER_NAME}/orig/agent-config.yaml` 을 생성합니다.

#### Step 7. 클러스터 매니페스트 생성

```bash
bash air-gapped/07_create_config_yaml.sh
```

`{CLUSTER_NAME}/orig/openshift/` 에 아래 매니페스트를 생성합니다:

| 파일 | 내용 |
|------|------|
| `operatorhub-disabled.yaml` | 기본 OperatorHub 소스 비활성화 |
| `sample-operator.yaml` | Sample Operator 제거 |
| `cs-redhat-operator-index.yaml` | Mirror Registry 기반 CatalogSource |
| `idms-olm-redhat.yaml` | ImageDigestMirrorSet |
| `master-kubeletconfig.yaml` | Master KubeletConfig |
| `worker-kubeletconfig.yaml` | Worker KubeletConfig |

#### Step 8. Cluster Manifests 생성

```bash
bash air-gapped/08_create_cluster_manifests.sh
```

`orig/` 파일을 클러스터 디렉토리로 복사 후 `openshift-install agent create cluster-manifests` 를 실행합니다.

#### Step 9. Agent ISO 생성

```bash
bash air-gapped/09_create_agent_iso.sh
```

`{CLUSTER_NAME}/ocp-v{OCP_VERSION}-agent.x86_64.iso` 파일이 생성됩니다.

#### Step 10. 설치 모니터링

모든 노드를 생성된 ISO로 부팅한 후 실행합니다.

```bash
bash air-gapped/10_monitor_install.sh
```

Bootstrap 완료 → 최종 설치 완료 순서로 모니터링하며, 완료 시 kubeadmin 패스워드를 출력합니다.

---

### [노드 추가 - 선택사항]

설치 완료 후 워커 노드를 추가할 때 사용합니다.

```bash
# config.env 의 ADD_NODES 배열 설정 후 실행

# Step 1. nodes-config.yaml 생성
bash add-nodes/01_create_nodes_config.sh

# Step 2. 노드 추가 ISO 생성 (oc login 필요)
bash add-nodes/02_create_nodes_iso.sh
```

생성된 `ocp-v{OCP_VERSION}-add-nodes.x86_64.iso` 를 추가할 노드에 부팅합니다.

---

### [Operator 추가 - 선택사항]

설치 완료 후 운영 중인 클러스터에 Operator를 추가할 때 사용합니다.

#### Step 1. config.env 설정

```bash
ADD_OPERATORS=(
    "elasticsearch-operator:redhat"
    "amq-streams:redhat"
)
```

형식: `"operator-name:catalog"` (`catalog`: `redhat` | `certified` | `community`)

#### Step 2. ISC 파일 생성 (Connected 환경)

```bash
bash add-operators/01_create_add_operators_isc.sh
```

실행마다 타임스탬프 디렉토리(`mirror-added/YYYYMMDD-HHMMSS/`)를 새로 생성합니다.

```
mirror-added/
└── 20260316-143022/
    ├── olm-redhat/add-redhat-isc.yaml
    └── olm-certified/add-certified-isc.yaml
```

완료 시 `RUN_ID`와 다음 단계 명령어가 출력됩니다.

#### Step 3. 이미지 미러링 (Connected 환경)

```bash
# RUN_ID 직접 지정
bash add-operators/02_mirror_add_operators.sh 20260316-143022

# 또는 목록에서 선택
bash add-operators/02_mirror_add_operators.sh
```

카탈로그별 개별 선택 또는 전체 미러링이 가능합니다.

#### Step 4. Air-gap 환경으로 전송 및 업로드

```bash
# Connected → Air-gap 전송
rsync -avzP ./mirror-added/ user@air-gap-server:/path/to/mirror-added/

# Air-gap 환경에서 Registry 업로드
# mirror-added/{RUN_ID}/ 의 이미지를 04_upload_mirror.sh 방식으로 업로드
```

---

## 참고

- 상세 구현 명세: [SPEC.md](./SPEC.md)
- ISC 포맷: `mirror.openshift.io/v2alpha1` (oc-mirror v2, OCP 4.14+ 권장)
- Pull Secret 발급: https://console.redhat.com/openshift/install/pull-secret
