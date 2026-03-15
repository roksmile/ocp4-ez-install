#!/usr/bin/env bash
# =============================================================================
# 09_create_agent_iso.sh - Agent ISO 생성
# =============================================================================
# cluster_dir 의 manifests 파일을 이용하여 agent ISO 를 생성하고
# ocp-v{OCP_VERSION}-agent.iso 로 이름을 변경합니다.
#
# 사전 조건:
#   - cluster_name/cluster-manifests/ 디렉토리 존재
#   - openshift-install 바이너리가 PATH에 있을 것
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 명령어 출력 후 실행 헬퍼
# -----------------------------------------------------------------------------
run() {
    echo "[CMD] $*"
    "$@"
}

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
# 사전 조건 확인
# -----------------------------------------------------------------------------
check_prerequisites() {
    echo "[INFO] 사전 조건 확인 중..."

    if [[ ! -d "${CLUSTER_DIR}/cluster-manifests" ]]; then
        echo "[ERROR] cluster-manifests 디렉토리가 없습니다: ${CLUSTER_DIR}/cluster-manifests"
        echo "[INFO]  08_create_cluster_manifests.sh 를 먼저 실행하세요."
        exit 1
    fi

    if ! command -v openshift-install &>/dev/null; then
        echo "[ERROR] openshift-install 명령어를 찾을 수 없습니다. PATH를 확인하세요."
        exit 1
    fi

    echo "[INFO] 사전 조건 확인 완료"
}

# -----------------------------------------------------------------------------
# Agent ISO 생성
# -----------------------------------------------------------------------------
create_agent_iso() {
    echo "[INFO] Agent ISO 생성 중..."
    run openshift-install agent create image --dir "${CLUSTER_DIR}"
    echo "[INFO] Agent ISO 생성 완료"
}

# -----------------------------------------------------------------------------
# ISO 파일 이름 변경
# -----------------------------------------------------------------------------
rename_iso() {
    local src_iso="${CLUSTER_DIR}/agent.x86_64.iso"
    local dest_iso="${CLUSTER_DIR}/ocp-v${OCP_VERSION}-agent.x86_64.iso"

    if [[ ! -f "${src_iso}" ]]; then
        echo "[ERROR] agent.x86_64.iso 파일을 찾을 수 없습니다: ${src_iso}"
        exit 1
    fi

    run mv "${src_iso}" "${dest_iso}"
    echo "[INFO] ISO 파일 이름 변경 완료: $(basename "${dest_iso}")"
}

# -----------------------------------------------------------------------------
# 메인
# -----------------------------------------------------------------------------
main() {
    echo "============================================================"
    echo " OCP4 Agent ISO 생성"
    echo " 클러스터: ${CLUSTER_NAME}"
    echo " 클러스터 디렉토리: ${CLUSTER_DIR}"
    echo " OCP 버전: ${OCP_VERSION}"
    echo "============================================================"

    check_prerequisites
    create_agent_iso
    rename_iso

    echo ""
    echo "[INFO] 완료. 생성된 ISO 파일:"
    ls -lh "${CLUSTER_DIR}/ocp-v${OCP_VERSION}-agent.x86_64.iso"
}

main "$@"
