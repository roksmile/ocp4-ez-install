# OCP4 Air-Gap Easy Install

Air-gap 환경에서 OpenShift Container Platform 4 를 쉽게 설치할 수 있는 쉘 스크립트 모음입니다.

## 디렉토리 구조

```
ocp4-ez-install/
├── config.env                          # 공통 환경설정 파일
├── connected/                          # 인터넷 연결 환경에서 실행
│   ├── 01_download_ocp_tools.sh        # OCP 도구 다운로드 및 설치
│   ├── 02_create_isc.sh                # ImageSetConfiguration 파일 생성
│   └── 03_mirror_images.sh             # 이미지 미러링 (oc-mirror)
├── air-gapped/                         # 인터넷 차단 환경에서 실행 (향후 추가)
└── {CLUSTER_NAME}/                     # 클러스터별 ISC 파일 (자동 생성)
    ├── ocp/
    │   └── ocp-isc.yaml
    ├── olm-redhat/
    │   └── olm-redhat-isc.yaml
    ├── olm-certified/
    │   └── olm-certified-isc.yaml
    └── olm-community/
        └── olm-community-isc.yaml
```

## 요구사항

| 항목 | 요구사항 |
|------|---------|
| OS | RHEL 9 |
| 디스크 | `/data` 에 최소 500GB 이상 권장 |
| 권한 | root (도구 설치 시) |
| 네트워크 | mirror.openshift.com, registry.redhat.io 접근 가능 |
| Pull Secret | Red Hat 계정 필요 |

## 빠른 시작

### 1. 환경설정 편집

```bash
vi config.env
```

주요 설정:
- `CLUSTER_NAME`: 클러스터 이름 (ISC 디렉토리 이름으로 사용)
- `OCP_VERSION`: 설치할 OCP 버전 (기본값: 4.20.14)
- `PULL_SECRET_FILE`: Pull Secret 파일 경로
- `MIRROR_REGISTRY_HOST`: Air-gap 환경의 Mirror Registry 주소

### 2. Pull Secret 저장

[Red Hat Console](https://console.redhat.com/openshift/install/pull-secret) 에서 Pull Secret 을 다운로드하여 저장합니다.

```bash
mkdir -p ~/.config
# 다운로드한 pull-secret.txt 를 지정 경로에 저장
cp ~/Downloads/pull-secret.txt ~/.config/ocp-pull-secret.json
```

### 3. OCP 도구 다운로드 (Connected 환경)

```bash
sudo bash connected/01_download_ocp_tools.sh
```

설치되는 도구:
- `oc` / `kubectl` : OpenShift CLI
- `oc-mirror` : 이미지 미러링 도구
- `openshift-install` : 클러스터 설치 도구
- `opm` : Operator Package Manager
- `butane` : Ignition 설정 파일 생성 도구

### 4. ISC 파일 생성 (Connected 환경)

```bash
bash connected/02_create_isc.sh
```

인터랙티브 메뉴에서 선택:
1. **OCP Platform** - OCP 플랫폼 이미지
2. **RedHat OLM** - RedHat Operator 이미지
3. **Certified OLM** - Certified Operator 이미지 (NVIDIA GPU 등)
4. **Community OLM** - Community Operator 이미지

Operator 그룹 선택 (복수 선택 가능):
- **GPU Operators**: nfd, nvidia-gpu-operator, nvidia-network-operator
- **Virtualization Operators**: kubevirt-hyperconverged, local-storage-operator, mtv-operator 등
- **CI/CD Operators**: openshift-gitops-operator, rhbk-operator, openshift-pipelines-operator-rh 등

### 5. 이미지 미러링 (Connected 환경)

```bash
bash connected/03_mirror_images.sh
```

인터랙티브 메뉴에서 미러링 대상 선택 후 실행합니다.
다운로드 결과물은 `/data/mirror/` 에 저장됩니다.

### 6. Air-gap 환경으로 데이터 전송

```bash
# 예: rsync 로 전송
rsync -avzP /data/mirror user@air-gap-server:/data/

# 또는 외장 드라이브에 복사
cp -r /data/mirror /mnt/external-drive/
```

## Operator 그룹 상세

| 그룹 | Operator | Catalog |
|------|---------|---------|
| GPU | nfd | redhat-operator-index |
| GPU | nvidia-gpu-operator | certified-operator-index |
| GPU | nvidia-network-operator | certified-operator-index |
| Virtualization | kubevirt-hyperconverged | redhat-operator-index |
| Virtualization | local-storage-operator | redhat-operator-index |
| Virtualization | mtc-operator | redhat-operator-index |
| Virtualization | mtv-operator | redhat-operator-index |
| Virtualization | redhat-oadp-operator | redhat-operator-index |
| Virtualization | fence-agents-remediation | redhat-operator-index |
| CI/CD | openshift-gitops-operator | redhat-operator-index |
| CI/CD | rhbk-operator | redhat-operator-index |
| CI/CD | openshift-pipelines-operator-rh | redhat-operator-index |
| CI/CD | web-terminal | redhat-operator-index |

## 로그

모든 스크립트의 실행 로그는 `/data/logs/` 디렉토리에 저장됩니다.

```bash
ls -la /data/logs/
```
