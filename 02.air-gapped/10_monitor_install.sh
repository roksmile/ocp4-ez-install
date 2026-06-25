#!/usr/bin/env bash
# =============================================================================
# 10_monitor_install.sh - OCP4 Agent 설치 모니터링
# =============================================================================
# agent ISO 로 노드를 부팅한 후 설치 진행 상황을 모니터링합니다.
#
# 사전 조건:
#   - 모든 노드가 agent ISO 로 부팅된 상태
#   - cluster_dir/auth/ 디렉토리가 생성되어 있을 것 (ISO 생성 시 자동 생성)
#   - openshift-install 바이너리가 PATH에 있을 것
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
# 사전 조건 확인
# -----------------------------------------------------------------------------
check_prerequisites() {
    echo "[INFO] 사전 조건 확인 중..."

    if [[ ! -d "${CLUSTER_DIR}" ]]; then
        echo "[ERROR] 클러스터 디렉토리가 없습니다: ${CLUSTER_DIR}"
        exit 1
    fi

    if ! command -v openshift-install &>/dev/null; then
        echo "[ERROR] openshift-install 명령어를 찾을 수 없습니다. PATH를 확인하세요."
        exit 1
    fi

    echo "[INFO] 사전 조건 확인 완료"
}

# -----------------------------------------------------------------------------
# Rendezvous IP 조회 (agent-config.yaml 에서 첫 번째 master IP 사용)
# -----------------------------------------------------------------------------
get_rendezvous_ip() {
    local agent_config="${CLUSTER_DIR}/orig/agent-config.yaml"
    if [[ -f "${agent_config}" ]]; then
        grep -m1 'address:' "${agent_config}" | awk '{print $2}' || true
    fi
}

# -----------------------------------------------------------------------------
# Bootstrap 완료 대기
# -----------------------------------------------------------------------------
wait_bootstrap_complete() {
    echo ""
    echo "[STEP 1] 모든 노드를 ISO로 부팅하세요."
    local rendezvous_ip
    rendezvous_ip="$(get_rendezvous_ip)"
    if [[ -n "${rendezvous_ip}" ]]; then
        echo "         Rendezvous IP: ${rendezvous_ip} 로 노드들이 모이기 시작합니다."
    fi
    echo "--------------------------------------------------------"
    echo "[INFO] Bootstrap 완료를 기다리는 중... (약 20~40분 소요)"

    if openshift-install agent wait-for bootstrap-complete \
            --dir "${CLUSTER_DIR}" --log-level info; then
        echo "--------------------------------------------------------"
        echo "[SUCCESS] Bootstrap 단계가 완료되었습니다!"
        echo "[INFO]    kubeconfig 경로: ${CLUSTER_DIR}/auth/kubeconfig"
        echo "          export KUBECONFIG=${CLUSTER_DIR}/auth/kubeconfig"
        echo "--------------------------------------------------------"
    else
        echo "[ERROR] Bootstrap 과정 중 시간이 초과되었거나 오류가 발생했습니다."
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# 최종 설치 완료 대기
# -----------------------------------------------------------------------------
wait_install_complete() {
    echo ""
    echo "[INFO] 최종 설치 완료를 기다리는 중... (추가 시간 소요)"

    if openshift-install agent wait-for install-complete \
            --dir "${CLUSTER_DIR}" --log-level info; then
        echo ""
        echo "========================================================"
        echo " [CONGRATULATIONS] OpenShift 클러스터 설치가 완료되었습니다!"
        echo " kubeadmin password: $(cat "${CLUSTER_DIR}/auth/kubeadmin-password")"
        echo "========================================================"
    else
        echo "[ERROR] 최종 설치 확인 중 오류가 발생했습니다."
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# 메인
# -----------------------------------------------------------------------------
main() {
    echo "========================================================"
    echo " OCP4 Agent 설치 모니터링"
    echo " 클러스터: ${CLUSTER_NAME}"
    echo " 클러스터 디렉토리: ${CLUSTER_DIR}"
    echo "========================================================"

    check_prerequisites
    wait_bootstrap_complete
    wait_install_complete
}

main "$@"
