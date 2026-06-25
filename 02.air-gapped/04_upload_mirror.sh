#!/usr/bin/env bash
# =============================================================================
# 04_upload_mirror.sh - 미러링된 이미지를 내부 Registry 로 업로드
# =============================================================================
# connected/03_mirror_images.sh 로 저장된 미러링 파일을 air-gap 환경의
# 내부 Registry 로 업로드합니다.
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
# ISC 정의: 서브디렉토리 → ISC 파일명 매핑 (03_mirror_images.sh 와 동일)
# =============================================================================
declare -A ISC_FILES=(
    ["ocp"]="ocp-isc.yaml"
    ["olm-redhat"]="olm-redhat-isc.yaml"
    ["olm-certified"]="olm-certified-isc.yaml"
    ["olm-community"]="olm-community-isc.yaml"
    ["add-images"]="add-images-isc.yaml"
)

ISC_ORDER=("ocp" "olm-redhat" "olm-certified" "olm-community" "add-images")

# =============================================================================
# Registry 정보 입력 및 로그인 (config.env 값을 기본값으로 제시)
# =============================================================================
prompt_with_default() {
    local prompt="$1"
    local default="$2"
    local result

    if [[ -n "${default}" ]]; then
        echo -n "  ${prompt} [${default}]: " >&2
    else
        echo -n "  ${prompt}: " >&2
    fi
    read -r result
    echo "${result:-${default}}"
}

configure_registry() {
    echo ""
    echo "================================================================="
    echo " Registry 접속 정보 (Enter 입력 시 기본값 사용)"
    echo "================================================================="

    MIRROR_REGISTRY="$(prompt_with_default "Registry 주소 (host:port)" "${MIRROR_REGISTRY:-}")"
    if [[ -z "${MIRROR_REGISTRY}" ]]; then
        echo "[ERROR] Registry 주소를 입력해야 합니다."
        exit 1
    fi

    MIRROR_REGISTRY_USER="$(prompt_with_default "사용자 이름" "${MIRROR_REGISTRY_USER:-}")"
    if [[ -z "${MIRROR_REGISTRY_USER}" ]]; then
        echo "[ERROR] 사용자 이름을 입력해야 합니다."
        exit 1
    fi

    local default_pass="${MIRROR_REGISTRY_PASS:-}"
    if [[ -n "${default_pass}" ]]; then
        echo -n "  비밀번호 [****]: "
    else
        echo -n "  비밀번호: "
    fi
    read -rs input_pass
    echo ""
    MIRROR_REGISTRY_PASS="${input_pass:-${default_pass}}"
    if [[ -z "${MIRROR_REGISTRY_PASS}" ]]; then
        echo "[ERROR] 비밀번호를 입력해야 합니다."
        exit 1
    fi

    echo ""
    echo "[OK]   Registry : ${MIRROR_REGISTRY}"
    echo "[OK]   User     : ${MIRROR_REGISTRY_USER}"

    echo ""
    echo "================================================================="
    echo " Registry 로그인: ${MIRROR_REGISTRY}"
    echo "================================================================="

    if ! run podman login \
            --username "${MIRROR_REGISTRY_USER}" \
            --password "${MIRROR_REGISTRY_PASS}" \
            "${MIRROR_REGISTRY}"; then
        echo "[ERROR] Registry 로그인 실패: ${MIRROR_REGISTRY}"
        exit 1
    fi

    echo "[OK]   Registry 로그인 완료."
}

# =============================================================================
# 사전 확인
# =============================================================================
check_prerequisites() {
    local errors=0

    echo ""
    echo "================================================================="
    echo " 사전 확인"
    echo "================================================================="

    # oc-mirror 설치 확인
    if ! command -v oc-mirror &>/dev/null; then
        echo "[ERROR] oc-mirror 가 설치되어 있지 않습니다."
        echo "        01_install_tools.sh 를 먼저 실행하세요."
        (( errors++ )) || true
    else
        echo "[OK]   oc-mirror 확인: $(command -v oc-mirror)"
    fi

    # MIRROR_DIR 존재 확인
    if [[ ! -d "${MIRROR_DIR}" ]]; then
        echo "[ERROR] mirror 디렉토리가 없습니다: ${MIRROR_DIR}"
        echo "        connected/03_mirror_images.sh 를 먼저 실행하세요."
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
# 단일 업로드 실행
# =============================================================================
run_upload() {
    local target="$1"
    local isc_dir="${MIRROR_DIR}/${target}"
    local isc_file="${isc_dir}/${ISC_FILES[${target}]}"
    local cache_dir="${CACHE_DIR}/${target}"
    local dest_registry
    # add-images 는 ISC에 정의된 경로 그대로 레지스트리 루트(host:port)에 푸시
    if [[ "${target}" == "add-images" ]]; then
        dest_registry="docker://${MIRROR_REGISTRY}"
    else
        dest_registry="docker://${MIRROR_REGISTRY}/${target}"
    fi

    echo ""
    echo "================================================================="
    echo " 업로드 시작: ${target}"
    echo "  ISC   : ${isc_file}"
    echo "  FROM  : file://${isc_dir}"
    echo "  TO    : ${dest_registry}"
    echo "  CACHE : ${cache_dir}"
    echo "================================================================="

    if [[ ! -d "${isc_dir}" ]]; then
        echo "[ERROR] 미러링 디렉토리가 없습니다: ${isc_dir}"
        echo "        connected/03_mirror_images.sh 를 먼저 실행하세요."
        return 1
    fi

    if [[ ! -f "${isc_file}" ]]; then
        echo "[ERROR] ISC 파일이 없습니다: ${isc_file}"
        echo "        connected/03_mirror_images.sh 를 먼저 실행하세요."
        return 1
    fi

    # cache 디렉토리 생성
    mkdir -p "${cache_dir}"

    run oc-mirror \
        --v2 \
        --config "${isc_file}" \
        --from "file://${isc_dir}" \
        --cache-dir "${cache_dir}" \
        --dest-tls-verify=false \
        "${dest_registry}"

    local rc=$?
    if [[ ${rc} -eq 0 ]]; then
        echo "[OK]   ${target} 업로드 완료."
    else
        echo "[ERROR] ${target} 업로드 실패 (exit code: ${rc})."
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
    echo " 업로드 대상 선택" >&2
    echo "=================================================================" >&2
    echo "" >&2
    echo "  1) ocp           - OpenShift Platform 이미지" >&2
    echo "  2) olm-redhat    - Red Hat Operator 이미지" >&2
    echo "  3) olm-certified - Certified Operator 이미지" >&2
    echo "  4) olm-community - Community Operator 이미지" >&2
    echo "  5) add-images    - 추가 이미지 (ADDITIONAL_IMAGES, Registry 루트로 업로드)" >&2
    echo "  6) all           - 전체 업로드 (존재하는 미러링 디렉토리 모두)" >&2
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
    echo " oc-mirror 이미지 업로드 (disk → registry)"
    echo "  MIRROR_DIR : ${MIRROR_DIR}"
    echo "  CACHE_DIR  : ${CACHE_DIR}/<target>"
    echo "================================================================="

    configure_registry

    check_prerequisites

    select_target

    local failed=0

    if [[ "${TARGET}" == "all" ]]; then
        echo ""
        echo "[INFO] 전체 업로드를 시작합니다."
        for t in "${ISC_ORDER[@]}"; do
            if [[ -d "${MIRROR_DIR}/${t}" ]]; then
                run_upload "${t}" || (( failed++ )) || true
            else
                echo "[SKIP] 미러링 디렉토리 없음, 건너뜀: ${MIRROR_DIR}/${t}"
            fi
        done
    else
        run_upload "${TARGET}" || (( failed++ )) || true
    fi

    echo ""
    echo "================================================================="
    if [[ ${failed} -eq 0 ]]; then
        echo "[DONE] 업로드 완료."
    else
        echo "[WARN] 업로드 완료 (실패: ${failed}건)."
    fi
    echo "================================================================="
}

main "$@"
