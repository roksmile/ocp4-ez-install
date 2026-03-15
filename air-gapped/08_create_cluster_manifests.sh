#!/usr/bin/env bash
# =============================================================================
# 08_create_cluster_manifests.sh - Cluster Manifests 생성
# =============================================================================
# cluster_name/orig/ 의 설치 파일을 cluster_name/ 으로 복사한 후
# openshift-install agent create cluster-manifests 를 실행합니다.
#
# 사전 조건:
#   - cluster_name/orig/install-config.yaml 존재
#   - cluster_name/orig/agent-config.yaml 존재
#   - cluster_name/orig/openshift/ 디렉토리 존재 (선택)
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
# 디렉토리 경로 설정
# -----------------------------------------------------------------------------
ORIG_DIR="${CLUSTER_DIR}/orig"

# -----------------------------------------------------------------------------
# 사전 조건 확인
# -----------------------------------------------------------------------------
check_prerequisites() {
    echo "[INFO] 사전 조건 확인 중..."

    if [[ ! -d "${ORIG_DIR}" ]]; then
        echo "[ERROR] orig 디렉토리가 없습니다: ${ORIG_DIR}"
        exit 1
    fi

    if [[ ! -f "${ORIG_DIR}/install-config.yaml" ]]; then
        echo "[ERROR] install-config.yaml 파일이 없습니다: ${ORIG_DIR}/install-config.yaml"
        exit 1
    fi

    if [[ ! -f "${ORIG_DIR}/agent-config.yaml" ]]; then
        echo "[ERROR] agent-config.yaml 파일이 없습니다: ${ORIG_DIR}/agent-config.yaml"
        exit 1
    fi

    if ! command -v openshift-install &>/dev/null; then
        echo "[ERROR] openshift-install 명령어를 찾을 수 없습니다. PATH를 확인하세요."
        exit 1
    fi

    echo "[INFO] 사전 조건 확인 완료"
}

# -----------------------------------------------------------------------------
# orig/ 파일을 cluster_dir 로 복사
# -----------------------------------------------------------------------------
copy_orig_files() {
    echo "[INFO] orig/ 파일을 ${CLUSTER_DIR}/ 로 복사 중..."

    run cp -f "${ORIG_DIR}/install-config.yaml" "${CLUSTER_DIR}/install-config.yaml"
    run cp -f "${ORIG_DIR}/agent-config.yaml"   "${CLUSTER_DIR}/agent-config.yaml"

    if [[ -d "${ORIG_DIR}/openshift" ]]; then
        if [[ -d "${CLUSTER_DIR}/openshift" ]]; then
            run rm -rf "${CLUSTER_DIR}/openshift"
            echo "[INFO] 기존 openshift/ 디렉토리 삭제 완료"
        fi
        run cp -r "${ORIG_DIR}/openshift" "${CLUSTER_DIR}/openshift"
        echo "[INFO] openshift/ 디렉토리 복사 완료"
    else
        echo "[INFO] openshift/ 디렉토리가 없으므로 건너뜁니다."
    fi

    echo "[INFO] 파일 복사 완료"
}

# -----------------------------------------------------------------------------
# cluster-manifests 생성
# -----------------------------------------------------------------------------
create_cluster_manifests() {
    echo "[INFO] cluster-manifests 생성 중..."
    run openshift-install agent create cluster-manifests --dir "${CLUSTER_DIR}"
    echo "[INFO] cluster-manifests 생성 완료: ${CLUSTER_DIR}/cluster-manifests/"
}

# -----------------------------------------------------------------------------
# 메인
# -----------------------------------------------------------------------------
main() {
    echo "============================================================"
    echo " OCP4 Cluster Manifests 생성"
    echo " 클러스터: ${CLUSTER_NAME}"
    echo " 클러스터 디렉토리: ${CLUSTER_DIR}"
    echo "============================================================"

    check_prerequisites
    copy_orig_files
    create_cluster_manifests

    echo ""
    echo "[INFO] 완료. 생성된 manifests 확인:"
    ls -la "${CLUSTER_DIR}/cluster-manifests/" 2>/dev/null || true
}

main "$@"
