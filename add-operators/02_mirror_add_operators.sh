#!/usr/bin/env bash
# =============================================================================
# 02_mirror_add_operators.sh - 추가 Operator 이미지 미러링
# =============================================================================
# 01_create_add_operators_isc.sh 에서 생성한 ISC 파일을 사용하여
# 추가 Operator 이미지를 다운로드합니다.
#
# 사용법:
#   ./02_mirror_add_operators.sh                 # ADD_OPERATORS_MIRROR_DIR 직하위 디렉터리 목록에서 선택
#   ./02_mirror_add_operators.sh <name>          # 보통 config.env 의 ADD_OPERATORS_TARGET 과 동일한 이름
#
# 다운로드 위치: ${ADD_OPERATORS_MIRROR_DIR}/<name>/{olm-redhat,...}/
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
    ["olm-redhat"]="add-redhat-isc.yaml"
    ["olm-certified"]="add-certified-isc.yaml"
    ["olm-community"]="add-community-isc.yaml"
)

ISC_ORDER=("olm-redhat" "olm-certified" "olm-community")

# 미러 결과 루트 (select_mirror_target 에서 설정)
#   MIRROR_TARGET : ADD_OPERATORS_MIRROR_DIR 직하위 이름 (보통 ADD_OPERATORS_TARGET)
#   RUN_DIR       : ${ADD_OPERATORS_MIRROR_DIR}/${MIRROR_TARGET}
MIRROR_TARGET=""
RUN_DIR=""

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

    if [[ ${errors} -gt 0 ]]; then
        echo ""
        echo "[ERROR] 사전 확인 실패 (${errors}건). 종료합니다."
        exit 1
    fi
}

# =============================================================================
# 미러 결과 디렉터리(MIRROR_TARGET) 선택
# =============================================================================
select_mirror_target() {
    local arg_name="$1"

    # CLI 인자로 디렉터리 이름이 지정된 경우 바로 사용
    if [[ -n "${arg_name}" ]]; then
        local dir="${ADD_OPERATORS_MIRROR_DIR}/${arg_name}"
        if [[ ! -d "${dir}" ]]; then
            echo "[ERROR] 지정한 미러 디렉터리가 없습니다: ${dir}"
            exit 1
        fi
        MIRROR_TARGET="${arg_name}"
        RUN_DIR="${dir}"
        echo "[INFO] MIRROR_TARGET 지정됨: ${MIRROR_TARGET}"
        return
    fi

    # ADD_OPERATORS_MIRROR_DIR 직하위의 모든 하위 디렉터리 (이름은 보통 ADD_OPERATORS_TARGET 과 동일)
    local -a targets=()
    local name
    if [[ -d "${ADD_OPERATORS_MIRROR_DIR}" ]]; then
        while IFS= read -r -d '' d; do
            name="$(basename "${d}")"
            targets+=("${name}")
        done < <(find "${ADD_OPERATORS_MIRROR_DIR}" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null)
        if [[ ${#targets[@]} -gt 0 ]]; then
            readarray -t targets < <(printf '%s\n' "${targets[@]}" | sort -r)
        fi
    fi

    if [[ ${#targets[@]} -eq 0 ]]; then
        echo "[ERROR] 미러링할 디렉터리가 없습니다: ${ADD_OPERATORS_MIRROR_DIR}"
        echo "        01_create_add_operators_isc.sh 를 먼저 실행하세요."
        exit 1
    fi

    echo "" >&2
    echo "=================================================================" >&2
    echo " 미러링할 디렉터리(MIRROR_TARGET) 선택" >&2
    echo "=================================================================" >&2
    echo "" >&2

    local idx=1
    for r in "${targets[@]}"; do
        printf "  %d) %s\n" "${idx}" "${r}" >&2
        (( idx++ ))
    done

    echo "" >&2
    echo -n "  선택 (1-$(( idx - 1 ))): " >&2
    read -r choice

    if [[ "${choice}" -ge 1 && "${choice}" -le $(( idx - 1 )) ]]; then
        MIRROR_TARGET="${targets[$(( choice - 1 ))]}"
        RUN_DIR="${ADD_OPERATORS_MIRROR_DIR}/${MIRROR_TARGET}"
    else
        echo "[ERROR] 잘못된 선택입니다: ${choice}" >&2
        exit 1
    fi

    echo "[INFO] 선택된 MIRROR_TARGET: ${MIRROR_TARGET}" >&2
}

# =============================================================================
# 단일 미러링 실행
# =============================================================================
run_mirror() {
    local target="$1"
    local isc_dir="${RUN_DIR}/${target}"
    local isc_file="${isc_dir}/${ISC_FILES[${target}]}"
    local cache_dir="${ADD_OPERATORS_CACHE_DIR}/${MIRROR_TARGET}/${target}"

    echo ""
    echo "================================================================="
    echo " 미러링 시작: ${target}"
    echo "  ISC  : ${isc_file}"
    echo "  DEST : file://${isc_dir}"
    echo "  CACHE: ${cache_dir}"
    echo "================================================================="

    if [[ ! -f "${isc_file}" ]]; then
        echo "[ERROR] ISC 파일이 없습니다: ${isc_file}"
        echo "        MIRROR_TARGET(${MIRROR_TARGET}) 에 해당 카탈로그 ISC 가 없습니다."
        return 1
    fi

    mkdir -p "${cache_dir}"

    run oc-mirror \
        --v2 \
        --config "${isc_file}" \
        --cache-dir "${cache_dir}" \
        --authfile "${PULL_SECRET_FILE}" \
        "file://${isc_dir}"

    local rc=$?
    if [[ ${rc} -eq 0 ]]; then
        echo "[OK]   ${target} 미러링 완료."
    else
        echo "[ERROR] ${target} 미러링 실패 (exit code: ${rc})."
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
        echo "[ERROR] RUN_DIR 에 미러링할 ISC 파일이 없습니다: ${RUN_DIR}"
        echo "        01_create_add_operators_isc.sh 를 먼저 실행하세요."
        exit 1
    fi

    echo "" >&2
    echo "=================================================================" >&2
    echo " 미러링 대상 선택 (MIRROR_TARGET: ${MIRROR_TARGET})" >&2
    echo "=================================================================" >&2
    echo "" >&2

    local idx=1
    for t in "${available[@]}"; do
        printf "  %d) %-16s - %s\n" "${idx}" "${t}" "${ISC_FILES[${t}]}" >&2
        (( idx++ ))
    done
    printf "  %d) %-16s - %s\n" "${idx}" "all" "전체 미러링" >&2

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
    local arg_mirror_target="${1:-}"

    echo ""
    echo "================================================================="
    echo " 추가 Operator 이미지 미러링"
    echo "  ADD_OPERATORS_MIRROR_DIR : ${ADD_OPERATORS_MIRROR_DIR}"
    echo "  ADD_OPERATORS_CACHE_DIR  : ${ADD_OPERATORS_CACHE_DIR}/<MIRROR_TARGET>/<catalog>"
    echo "================================================================="

    check_prerequisites

    # MIRROR_TARGET 선택 (인자 있으면 직접 지정, 없으면 목록에서 선택)
    select_mirror_target "${arg_mirror_target}"

    echo "[INFO] RUN_DIR : ${RUN_DIR}"

    select_target

    local failed=0

    if [[ "${TARGET}" == "all" ]]; then
        echo ""
        echo "[INFO] 전체 미러링을 시작합니다."
        for t in "${ISC_ORDER[@]}"; do
            if [[ -f "${RUN_DIR}/${t}/${ISC_FILES[${t}]}" ]]; then
                run_mirror "${t}" || (( failed++ )) || true
            else
                echo "[SKIP] ISC 파일 없음, 건너뜀: ${RUN_DIR}/${t}/${ISC_FILES[${t}]}"
            fi
        done
    else
        run_mirror "${TARGET}" || (( failed++ )) || true
    fi

    echo ""
    echo "================================================================="
    if [[ ${failed} -eq 0 ]]; then
        echo "[DONE] 미러링 완료. (MIRROR_TARGET: ${MIRROR_TARGET})"
    else
        echo "[WARN] 미러링 완료 (실패: ${failed}건). (MIRROR_TARGET: ${MIRROR_TARGET})"
    fi
    echo "================================================================="
}

main "$@"
