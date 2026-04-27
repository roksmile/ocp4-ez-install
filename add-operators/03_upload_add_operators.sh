#!/usr/bin/env bash
# =============================================================================
# 03_upload_add_operators.sh - 추가 Operator 이미지 Registry 업로드
# =============================================================================
# 02_mirror_add_operators.sh 에서 다운로드한 이미지를 air-gap 환경의
# 내부 Registry 로 업로드합니다.
#
# 사용법:
#   ./03_upload_add_operators.sh                 # mirror-added/ 하위 디렉토리 목록에서 선택
#   ./03_upload_add_operators.sh <ADD_OPERATORS_TARGET>  # 해당 이름의 미러 결과 디렉토리
#
# 업로드 목적지:
#   docker://<MIRROR_REGISTRY>/mirror_registry/<RUN_ID>/olm-redhat
#   docker://<MIRROR_REGISTRY>/mirror_registry/<RUN_ID>/olm-certified
#   docker://<MIRROR_REGISTRY>/mirror_registry/<RUN_ID>/olm-community
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
# ISC 정의: 서브디렉토리 → ISC 파일명 매핑 (02_mirror_add_operators.sh 와 동일)
# =============================================================================
declare -A ISC_FILES=(
    ["olm-redhat"]="add-redhat-isc.yaml"
    ["olm-certified"]="add-certified-isc.yaml"
    ["olm-community"]="add-community-isc.yaml"
)

ISC_ORDER=("olm-redhat" "olm-certified" "olm-community")

# 선택된 실행 디렉토리 (select_run 에서 설정)
RUN_ID=""
RUN_DIR=""

# =============================================================================
# Registry 정보 입력 및 로그인
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

    # ADD_OPERATORS_MIRROR_DIR 존재 확인
    if [[ ! -d "${ADD_OPERATORS_MIRROR_DIR}" ]]; then
        echo "[ERROR] 미러링 디렉토리가 없습니다: ${ADD_OPERATORS_MIRROR_DIR}"
        echo "        02_mirror_add_operators.sh 를 먼저 실행하세요."
        (( errors++ )) || true
    else
        echo "[OK]   미러링 디렉토리 확인: ${ADD_OPERATORS_MIRROR_DIR}"
    fi

    if [[ ${errors} -gt 0 ]]; then
        echo ""
        echo "[ERROR] 사전 확인 실패 (${errors}건). 종료합니다."
        exit 1
    fi
}

# =============================================================================
# 실행 디렉토리(RUN_ID) 선택
# =============================================================================
select_run() {
    local arg_run_id="$1"

    # CLI 인자로 RUN_ID 가 지정된 경우 바로 사용
    if [[ -n "${arg_run_id}" ]]; then
        local dir="${ADD_OPERATORS_MIRROR_DIR}/${arg_run_id}"
        if [[ ! -d "${dir}" ]]; then
            echo "[ERROR] 지정한 RUN_ID 디렉토리가 없습니다: ${dir}"
            exit 1
        fi
        RUN_ID="${arg_run_id}"
        RUN_DIR="${dir}"
        echo "[INFO] RUN_ID 지정됨: ${RUN_ID}"
        return
    fi

    # 실행 디렉토리: ADD_OPERATORS_TARGET 이름 등, mirror-added/ 바로 아래의 모든 하위 디렉터리
    local -a runs=()
    local name
    if [[ -d "${ADD_OPERATORS_MIRROR_DIR}" ]]; then
        while IFS= read -r -d '' d; do
            name="$(basename "${d}")"
            runs+=("${name}")
        done < <(find "${ADD_OPERATORS_MIRROR_DIR}" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null)
        if [[ ${#runs[@]} -gt 0 ]]; then
            readarray -t runs < <(printf '%s\n' "${runs[@]}" | sort -r)
        fi
    fi

    if [[ ${#runs[@]} -eq 0 ]]; then
        echo "[ERROR] 업로드할 실행 디렉토리가 없습니다: ${ADD_OPERATORS_MIRROR_DIR}"
        echo "        02_mirror_add_operators.sh 를 먼저 실행하세요."
        exit 1
    fi

    echo "" >&2
    echo "=================================================================" >&2
    echo " 업로드할 실행(RUN_ID) 선택" >&2
    echo "=================================================================" >&2
    echo "" >&2

    local idx=1
    for r in "${runs[@]}"; do
        printf "  %d) %s\n" "${idx}" "${r}" >&2
        (( idx++ ))
    done

    echo "" >&2
    echo -n "  선택 (1-$(( idx - 1 ))): " >&2
    read -r choice

    if [[ "${choice}" -ge 1 && "${choice}" -le $(( idx - 1 )) ]]; then
        RUN_ID="${runs[$(( choice - 1 ))]}"
        RUN_DIR="${ADD_OPERATORS_MIRROR_DIR}/${RUN_ID}"
    else
        echo "[ERROR] 잘못된 선택입니다: ${choice}" >&2
        exit 1
    fi

    echo "[INFO] 선택된 RUN_ID: ${RUN_ID}" >&2
}

# =============================================================================
# 단일 업로드 실행
# =============================================================================
run_upload() {
    local target="$1"
    local isc_dir="${RUN_DIR}/${target}"
    local isc_file="${isc_dir}/${ISC_FILES[${target}]}"
    local cache_dir="${ADD_OPERATORS_CACHE_DIR}/${RUN_ID}/${target}"
    local dest_registry="docker://${MIRROR_REGISTRY}/${RUN_ID}/${target}"

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
        echo "        02_mirror_add_operators.sh 를 먼저 실행하세요."
        return 1
    fi

    if [[ ! -f "${isc_file}" ]]; then
        echo "[ERROR] ISC 파일이 없습니다: ${isc_file}"
        echo "        02_mirror_add_operators.sh 를 먼저 실행하세요."
        return 1
    fi

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
# 대화형 선택 메뉴 (카탈로그 선택)
# =============================================================================
TARGET=""

select_target() {
    # RUN_DIR 안에 존재하는 ISC 파일 목록 수집
    local -a available=()
    for t in "${ISC_ORDER[@]}"; do
        [[ -f "${RUN_DIR}/${t}/${ISC_FILES[${t}]}" ]] && available+=("${t}")
    done

    if [[ ${#available[@]} -eq 0 ]]; then
        echo "[ERROR] RUN_DIR 에 업로드할 ISC 파일이 없습니다: ${RUN_DIR}"
        echo "        02_mirror_add_operators.sh 를 먼저 실행하세요."
        exit 1
    fi

    echo "" >&2
    echo "=================================================================" >&2
    echo " 업로드 대상 선택 (RUN_ID: ${RUN_ID})" >&2
    echo "=================================================================" >&2
    echo "" >&2

    local idx=1
    for t in "${available[@]}"; do
        printf "  %d) %-16s - %s\n" "${idx}" "${t}" "${ISC_FILES[${t}]}" >&2
        (( idx++ ))
    done
    printf "  %d) %-16s - %s\n" "${idx}" "all" "전체 업로드" >&2

    echo "" >&2
    echo -n "  선택 (1-${idx}): " >&2
    read -r choice

    if [[ "${choice}" -ge 1 && "${choice}" -lt "${idx}" ]]; then
        TARGET="${available[$(( choice - 1 ))]}"
    elif [[ "${choice}" -eq "${idx}" ]]; then
        TARGET="all"
    else
        echo "[ERROR] 잘못된 선택입니다: ${choice}" >&2
        exit 1
    fi
}

# =============================================================================
# main
# =============================================================================
main() {
    local arg_run_id="${1:-}"

    echo ""
    echo "================================================================="
    echo " 추가 Operator 이미지 업로드 (disk → registry)"
    echo "  ADD_OPERATORS_MIRROR_DIR : ${ADD_OPERATORS_MIRROR_DIR}"
    echo "  ADD_OPERATORS_CACHE_DIR  : ${ADD_OPERATORS_CACHE_DIR}/<RUN_ID>/<target>"
    echo "  DEST                     : docker://${MIRROR_REGISTRY}/<RUN_ID>/<target>"
    echo "================================================================="

    configure_registry

    check_prerequisites

    # RUN_ID 선택 (인자 있으면 직접 지정, 없으면 목록에서 선택)
    select_run "${arg_run_id}"

    echo "[INFO] RUN_DIR : ${RUN_DIR}"

    select_target

    local failed=0

    if [[ "${TARGET}" == "all" ]]; then
        echo ""
        echo "[INFO] 전체 업로드를 시작합니다."
        for t in "${ISC_ORDER[@]}"; do
            if [[ -f "${RUN_DIR}/${t}/${ISC_FILES[${t}]}" ]]; then
                run_upload "${t}" || (( failed++ )) || true
            else
                echo "[SKIP] ISC 파일 없음, 건너뜀: ${RUN_DIR}/${t}/${ISC_FILES[${t}]}"
            fi
        done
    else
        run_upload "${TARGET}" || (( failed++ )) || true
    fi

    echo ""
    echo "================================================================="
    if [[ ${failed} -eq 0 ]]; then
        echo "[DONE] 업로드 완료. (RUN_ID: ${RUN_ID})"
    else
        echo "[WARN] 업로드 완료 (실패: ${failed}건). (RUN_ID: ${RUN_ID})"
    fi
    echo "================================================================="
}

main "$@"
