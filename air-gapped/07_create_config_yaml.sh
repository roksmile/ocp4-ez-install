#!/usr/bin/env bash
# =============================================================================
# 07_create_config_yaml.sh - 클러스터 설치 후 적용할 매니페스트 생성
# =============================================================================
# ${CLUSTER_DIR}/orig/openshift/ 디렉토리에 매니페스트 파일들을 생성합니다.
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# config.env 로드
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.env"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "[ERROR] config.env 파일을 찾을 수 없습니다: ${CONFIG_FILE}"
    exit 1
fi

# shellcheck source=../config.env
source "${CONFIG_FILE}"

# -----------------------------------------------------------------------------
# 출력 디렉토리 설정
# -----------------------------------------------------------------------------
MANIFEST_DIR="${CLUSTER_DIR}/orig/openshift"

# -----------------------------------------------------------------------------
# 디렉토리 생성
# -----------------------------------------------------------------------------
mkdir -p "${MANIFEST_DIR}"
echo "[INFO] 매니페스트 디렉토리: ${MANIFEST_DIR}"

# -----------------------------------------------------------------------------
# 매니페스트 생성 함수
# -----------------------------------------------------------------------------
write_manifest() {
    local filename="$1"
    local content="$2"
    local filepath="${MANIFEST_DIR}/${filename}"
    cat > "${filepath}" <<EOF
${content}
EOF
    echo "[INFO] 생성: ${filepath}"
}

# -----------------------------------------------------------------------------
# 1. OperatorHub 기본 소스 비활성화
# -----------------------------------------------------------------------------
write_manifest "operatorhub-disabled.yaml" \
"apiVersion: config.openshift.io/v1
kind: OperatorHub
metadata:
  name: cluster
spec:
  disableAllDefaultSources: true"

# -----------------------------------------------------------------------------
# 2. Sample Operator 제거 (air-gap 환경에서 불필요)
# -----------------------------------------------------------------------------
write_manifest "sample-operator.yaml" \
"apiVersion: samples.operator.openshift.io/v1
kind: Config
metadata:
  name: cluster
spec:
  architectures:
  - x86_64
  managementState: Removed"

# -----------------------------------------------------------------------------
# 3. Red Hat Operator Index CatalogSource
# -----------------------------------------------------------------------------
write_manifest "cs-redhat-operator-index.yaml" \
"apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: cs-redhat-operator-index
  namespace: openshift-marketplace
spec:
  image: ${MIRROR_REGISTRY}/olm-redhat/redhat/redhat-operator-index:v${OCP_MAJOR_VERSION}
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 20m"

# -----------------------------------------------------------------------------
# 4. ImageDigestMirrorSet - OLM Red Hat
# -----------------------------------------------------------------------------
write_manifest "idms-olm-redhat.yaml" \
"apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: idms-olm-redhat
spec:
  imageDigestMirrors:
  - mirrors:
    - ${MIRROR_REGISTRY}/olm-redhat
    source: registry.redhat.io"

# -----------------------------------------------------------------------------
# 5. Master KubeletConfig
# -----------------------------------------------------------------------------
write_manifest "master-kubeletconfig.yaml" \
"apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: master-set-kubelet-config
spec:
  autoSizingReserved: true
  logLevel: 3
  machineConfigPoolSelector:
    matchLabels:
      pools.operator.machineconfiguration.openshift.io/master: \"\""

# -----------------------------------------------------------------------------
# 6. Worker KubeletConfig
# -----------------------------------------------------------------------------
write_manifest "worker-kubeletconfig.yaml" \
"apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: worker-set-kubelet-config
spec:
  autoSizingReserved: true
  logLevel: 3
  machineConfigPoolSelector:
    matchLabels:
      pools.operator.machineconfiguration.openshift.io/worker: \"\""

# -----------------------------------------------------------------------------
# 완료
# -----------------------------------------------------------------------------
echo ""
echo "[INFO] 매니페스트 생성 완료."
echo "[INFO] 생성된 파일 목록:"
ls -1 "${MANIFEST_DIR}"
