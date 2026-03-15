#!/usr/bin/env bash
# =============================================================================
# 02_create_node_iso.sh - 노드 추가용 ISO 파일 생성
# =============================================================================
# 1. cluster_dir/orig/nodes-config.yaml → cluster_dir/ 복사
# 2. 운영 중인 클러스터에서 pull-secret 추출
# 3. oc adm node-image create 로 ISO 생성
#
# 사전 요건:
#   - 01_create_nodes_config.sh 실행 완료 (cluster_dir/orig/nodes-config.yaml 존재)
#   - oc CLI 로그인 완료 (기존 운영 클러스터)
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
# 변수
# -----------------------------------------------------------------------------
ORIG_NODES_CONFIG="${CLUSTER_DIR}/orig/nodes-config.yaml"
DEST_NODES_CONFIG="${CLUSTER_DIR}/nodes-config.yaml"
PULL_SECRET_FILE="${CLUSTER_DIR}/cluster-pull-secret.txt"
ISO_SRC="${CLUSTER_DIR}/node.x86_64.iso"
ISO_NAME="ocp-v${OCP_VERSION}-add-nodes.x86_64.iso"
ISO_DEST="${CLUSTER_DIR}/${ISO_NAME}"

# -----------------------------------------------------------------------------
# 사전 점검
# -----------------------------------------------------------------------------
preflight_check() {
    echo "[INFO] 사전 점검 중..."

    if [[ ! -f "${ORIG_NODES_CONFIG}" ]]; then
        echo "[ERROR] nodes-config.yaml 이 없습니다: ${ORIG_NODES_CONFIG}"
        echo "       01_create_nodes_config.sh 를 먼저 실행하세요."
        exit 1
    fi

    if ! command -v oc &>/dev/null; then
        echo "[ERROR] oc CLI 가 PATH 에 없습니다."
        exit 1
    fi

    if ! oc whoami &>/dev/null; then
        echo "[ERROR] OpenShift 클러스터에 로그인되어 있지 않습니다."
        echo "       oc login <API_URL> 을 먼저 실행하세요."
        exit 1
    fi

    echo "[INFO] 현재 로그인 계정: $(oc whoami)"
    echo "[INFO] 현재 API 서버  : $(oc whoami --show-server)"
}

# -----------------------------------------------------------------------------
# nodes-config.yaml 복사
# -----------------------------------------------------------------------------
copy_nodes_config() {
    echo ""
    echo "[INFO] nodes-config.yaml 복사"
    echo "       ${ORIG_NODES_CONFIG}"
    echo "    -> ${DEST_NODES_CONFIG}"
    cp -v "${ORIG_NODES_CONFIG}" "${DEST_NODES_CONFIG}"
}

# -----------------------------------------------------------------------------
# pull-secret 추출
# -----------------------------------------------------------------------------
fetch_pull_secret() {
    echo ""
    echo "[INFO] 클러스터에서 pull-secret 추출 중..."
    oc -n openshift-config get secret pull-secret \
        -o jsonpath='{.data.\.dockerconfigjson}' \
        | base64 -d > "${PULL_SECRET_FILE}"
    echo "[INFO] pull-secret 저장 완료: ${PULL_SECRET_FILE}"
}

# -----------------------------------------------------------------------------
# ISO 생성
# -----------------------------------------------------------------------------
create_iso() {
    echo ""
    echo "[INFO] ISO 생성 중..."

    echo "       oc adm node-image create --dir=${CLUSTER_DIR} -a ${PULL_SECRET_FILE}"
    echo ""

    oc adm node-image create \
        --dir="${CLUSTER_DIR}" \
        -a "${PULL_SECRET_FILE}"

    # node.x86_64.iso → ocp-v${OCP_VERSION}-add-nodes.x86_64.iso 로 이름 변경
    if [[ ! -f "${ISO_SRC}" ]]; then
        echo "[ERROR] 생성된 ISO 파일을 찾을 수 없습니다: ${ISO_SRC}"
        exit 1
    fi
    mv "${ISO_SRC}" "${ISO_DEST}"

    echo ""
    echo "[INFO] ISO 생성 완료: ${ISO_DEST}"
}

# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------
main() {
    echo "================================================================="
    echo " OCP4 노드 추가 ISO 생성"
    echo " OCP Version  : ${OCP_VERSION}"
    echo " Cluster      : ${CLUSTER_NAME}.${BASE_DOMAIN}"
    echo " Cluster Dir  : ${CLUSTER_DIR}"
    echo " ISO 파일     : ${ISO_NAME}"
    echo "================================================================="

    preflight_check
    copy_nodes_config
    fetch_pull_secret
    create_iso

    echo ""
    echo "================================================================="
    echo " [DONE] 완료"
    echo " ISO 파일 : ${ISO_NAME}"
    echo " 이 ISO 를 추가할 노드에 부팅하여 설치를 진행하세요."
    echo "================================================================="
}

main "$@"
