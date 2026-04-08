#!/usr/bin/env bash
# =============================================================================
# 03_mirror_images.sh - oc-mirror 로 이미지 미러링
# =============================================================================
# 02_create_isc.sh 에서 생성한 ISC 파일을 사용하여 이미지를 미러링합니다.
# 미러링 결과는 ISC 파일이 위치한 디렉토리에 저장됩니다.
# =============================================================================

set -uo pipefail

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

# =============================================================================
# ISC 정의: 서브디렉토리 → ISC 파일명 매핑
# =============================================================================
declare -A ISC_FILES=(
    ["ocp"]="ocp-isc.yaml"
    ["olm-redhat"]="olm-redhat-isc.yaml"
    ["olm-certified"]="olm-certified-isc.yaml"
    ["olm-community"]="olm-community-isc.yaml"
    ["add-images"]="add-images-isc.yaml"
)

# 메뉴 순서 유지용 배열
ISC_ORDER=("ocp" "olm-redhat" "olm-certified" "olm-community" "add-images")

# =============================================================================
# 사전 확인
# =============================================================================
check_prerequisites() {
    local errors=0

    echo ""
    echo "================================================================="
    echo " 사전 확인"
    echo "================================================================="

    # pull-secret.txt 확인
    if [[ ! -f "${PULL_SECRET_FILE}" ]]; then
        echo "[ERROR] Pull Secret 파일이 없습니다: ${PULL_SECRET_FILE}"
        echo "        https://console.redhat.com/openshift/install/pull-secret 에서 다운로드하여"
        echo "        ${PULL_SECRET_FILE} 로 저장하세요."
        (( errors++ )) || true
    else
        echo "[OK]   Pull Secret 파일 확인: ${PULL_SECRET_FILE}"
    fi

    # oc-mirror 설치 확인
    if ! command -v oc-mirror &>/dev/null; then
        echo "[ERROR] oc-mirror 가 설치되어 있지 않습니다."
        echo "        01_download_ocp_tools.sh 를 먼저 실행하세요."
        (( errors++ )) || true
    else
        echo "[OK]   oc-mirror 확인: $(command -v oc-mirror)"
    fi

    # MIRROR_DIR 존재 확인
    if [[ ! -d "${MIRROR_DIR}" ]]; then
        echo "[ERROR] mirror 디렉토리가 없습니다: ${MIRROR_DIR}"
        echo "        02_create_isc.sh 를 먼저 실행하세요."
        (( errors++ )) || true
    else
        echo "[OK]   mirror 디렉토리 확인: ${MIRROR_DIR}"
    fi

    if [[ ${errors} -gt 0 ]]; then
        echo ""
        echo "[ERROR] 사전 확인 실패 (${errors}건). 종료합니다."
        exit 1
    fi
}

# =============================================================================
# 단일 미러링 실행
# =============================================================================
run_mirror() {
    local target="$1"
    local isc_dir="${MIRROR_DIR}/${target}"
    local isc_file="${isc_dir}/${ISC_FILES[${target}]}"
    local cache_dir="${CACHE_DIR}/${target}"

    echo ""
    echo "================================================================="
    echo " 미러링 시작: ${target}"
    echo "  ISC  : ${isc_file}"
    echo "  DEST : file://${isc_dir}"
    echo "  CACHE: ${cache_dir}"
    echo "================================================================="

    if [[ ! -f "${isc_file}" ]]; then
        echo "[ERROR] ISC 파일이 없습니다: ${isc_file}"
        echo "        02_create_isc.sh 를 먼저 실행하세요."
        return 1
    fi

    # cache 디렉토리 생성
    mkdir -p "${cache_dir}"

    run oc-mirror \
        --v2 \
        --config "${isc_file}" \
        --cache-dir "${cache_dir}" \
        --authfile "${PULL_SECRET_FILE}" \
        --workspace "file://${isc_dir}"

    local rc=$?
    if [[ ${rc} -eq 0 ]]; then
        echo "[OK]   ${target} 미러링 완료."
    else
        echo "[ERROR] ${target} 미러링 실패 (exit code: ${rc})."
        return ${rc}
    fi
}

# =============================================================================
# 대화형 선택 메뉴
# =============================================================================
TARGET=""

select_target() {
    echo "" >&2
    echo "=================================================================" >&2
    echo " 미러링 대상 선택" >&2
    echo "=================================================================" >&2
    echo "" >&2
    echo "  1) ocp           - OpenShift Platform 이미지" >&2
    echo "  2) olm-redhat    - Red Hat Operator 이미지" >&2
    echo "  3) olm-certified - Certified Operator 이미지" >&2
    echo "  4) olm-community - Community Operator 이미지" >&2
    echo "  5) add-images    - 추가 이미지 (ADDITIONAL_IMAGES)" >&2
    echo "  6) all           - 전체 미러링 (존재하는 ISC 파일 모두)" >&2
    echo "" >&2
    echo -n "  선택 (1-6): " >&2
    read -r choice

    case "${choice}" in
        1) TARGET="ocp" ;;
        2) TARGET="olm-redhat" ;;
        3) TARGET="olm-certified" ;;
        4) TARGET="olm-community" ;;
        5) TARGET="add-images" ;;
        6) TARGET="all" ;;
        *)
            echo "[ERROR] 잘못된 선택입니다: ${choice}" >&2
            exit 1
            ;;
    esac
}

# =============================================================================
# main
# =============================================================================
main() {
    echo ""
    echo "================================================================="
    echo " oc-mirror 이미지 미러링"
    echo "  MIRROR_DIR : ${MIRROR_DIR}"
    echo "  CACHE_DIR  : ${CACHE_DIR}/<target>"
    echo "================================================================="

    check_prerequisites

    select_target

    local failed=0

    if [[ "${TARGET}" == "all" ]]; then
        echo ""
        echo "[INFO] 전체 미러링을 시작합니다."
        for t in "${ISC_ORDER[@]}"; do
            if [[ -f "${MIRROR_DIR}/${t}/${ISC_FILES[${t}]}" ]]; then
                run_mirror "${t}" || (( failed++ )) || true
            else
                echo "[SKIP] ISC 파일 없음, 건너뜀: ${MIRROR_DIR}/${t}/${ISC_FILES[${t}]}"
            fi
        done
    else
        run_mirror "${TARGET}" || (( failed++ )) || true
    fi

    echo ""
    echo "================================================================="
    if [[ ${failed} -eq 0 ]]; then
        echo "[DONE] 미러링 완료."
    else
        echo "[WARN] 미러링 완료 (실패: ${failed}건)."
    fi
    echo "================================================================="
}

main "$@"
