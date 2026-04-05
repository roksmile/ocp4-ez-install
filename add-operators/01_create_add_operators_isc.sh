#!/usr/bin/env bash
# =============================================================================
# 01_create_add_operators_isc.sh - 추가 Operator ISC 파일 생성
# =============================================================================
# 운영 중인 OCP4 클러스터에 Operator 를 추가 설치할 때 사용합니다.
# config.env 의 ADD_OPERATORS 목록을 카탈로그별로 분류하여
# ImageSetConfiguration 파일을 생성합니다.
#
# 실행마다 RUN_ID(YYYYMMDD + 순번 01~99) 디렉토리를 새로 생성하므로 덮어쓰지 않습니다.
# 같은 날짜에 재실행 시 기존 디렉토리의 최대 순번 + 1 을 사용합니다 (예: 2026032001 → 2026032002).
#
# 생성 위치:
#   ${ADD_OPERATORS_MIRROR_DIR}/YYYYMMDDNN/olm-redhat/add-redhat-isc.yaml
#   ${ADD_OPERATORS_MIRROR_DIR}/YYYYMMDDNN/olm-certified/add-certified-isc.yaml
#   ${ADD_OPERATORS_MIRROR_DIR}/YYYYMMDDNN/olm-community/add-community-isc.yaml
#   (NN: 당일 실행 순번 01~99)
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
# 전역 변수 (main 에서 초기화)
# =============================================================================
RUN_ID=""
RUN_DIR=""
RENDER_CACHE_DIR=""

init_render_cache() {
    RENDER_CACHE_DIR=$(mktemp -d)
    trap "rm -rf '${RENDER_CACHE_DIR}'" EXIT
}

_catalog_cache_file() {
    local catalog_url="$1"
    local safe_name
    safe_name=$(echo "${catalog_url}" | tr '/:.' '_')
    echo "${RENDER_CACHE_DIR}/${safe_name}.json"
}

_render_catalog() {
    local catalog_url="$1"
    local cache_file
    cache_file=$(_catalog_cache_file "${catalog_url}")

    if [[ -f "${cache_file}" ]]; then
        return
    fi

    echo "[INFO] 카탈로그 렌더링 중 (시간이 걸릴 수 있습니다): ${catalog_url}" >&2
    echo "[CMD]  opm render ${catalog_url} -o json" >&2
    if ! opm render "${catalog_url}" -o json > "${cache_file}" 2>/dev/null; then
        echo "[WARN] opm render 실패: ${catalog_url} - defaultChannel 을 'stable' 로 대체합니다." >&2
        rm -f "${cache_file}"
    fi
}

get_default_channel() {
    local catalog_url="$1"
    local pkg_name="$2"
    local cache_file
    cache_file=$(_catalog_cache_file "${catalog_url}")

    _render_catalog "${catalog_url}"

    if [[ ! -f "${cache_file}" ]]; then
        echo "stable"
        return
    fi

    local ch
    ch=$(jq -r --arg pkg "${pkg_name}" \
        'select(.schema == "olm.package" and .name == $pkg) | .defaultChannel' \
        "${cache_file}" 2>/dev/null | head -1)

    if [[ -z "${ch}" || "${ch}" == "null" ]]; then
        echo "[WARN] ${pkg_name} defaultChannel 조회 실패 - 'stable' 로 대체" >&2
        echo "stable"
    else
        echo "${ch}"
    fi
}

# =============================================================================
# ADD_OPERATORS 검증
# =============================================================================
check_add_operators() {
    if [[ ${#ADD_OPERATORS[@]} -eq 0 ]]; then
        echo "[ERROR] config.env 의 ADD_OPERATORS 가 비어 있습니다."
        echo "        추가할 Operator 를 ADD_OPERATORS 배열에 정의하세요."
        exit 1
    fi

    echo "[INFO] 추가할 Operator 목록 (${#ADD_OPERATORS[@]}개):"
    for op in "${ADD_OPERATORS[@]}"; do
        echo "       - ${op%%:*} [${op##*:}-operator-index]"
    done
}

# =============================================================================
# 카탈로그별 ISC 파일 생성
# =============================================================================
_write_isc() {
    local dir_name="$1"
    local file_name="$2"
    local catalog_url="$3"
    local catalog_type="$4"

    local -a packages=()

    for op in "${ADD_OPERATORS[@]}"; do
        [[ "${op##*:}" == "${catalog_type}" ]] && packages+=("${op%%:*}")
    done

    if [[ ${#packages[@]} -eq 0 ]]; then
        echo "[SKIP] ${dir_name}: 해당 카탈로그에 포함할 패키지 없음 - 건너뜀"
        return
    fi

    local isc_dir="${RUN_DIR}/${dir_name}"
    run mkdir -p "${isc_dir}"

    local isc_file="${isc_dir}/${file_name}"
    echo "[CMD] cat > ${isc_file}"
    {
        echo "kind: ImageSetConfiguration"
        echo "apiVersion: mirror.openshift.io/v2alpha1"
        echo "mirror:"
        echo "  operators:"
        echo "  - catalog: ${catalog_url}"
        echo "    packages:"
        for pkg in "${packages[@]}"; do
            local ch
            ch=$(get_default_channel "${catalog_url}" "${pkg}")
            echo "[INFO] ${pkg} defaultChannel: ${ch}" >&2
            echo "    - name: ${pkg}"
            echo "      defaultChannel: ${ch}"
            echo "      channels:"
            echo "      - name: ${ch}"
        done
    } > "${isc_file}"

    echo "[OK]   ISC 파일 생성: ${isc_file}"
}

create_isc_files() {
    echo ""
    echo "================================================================="
    echo " 카탈로그별 ISC 파일 생성"
    echo "================================================================="

    _write_isc "olm-redhat"    "add-redhat-isc.yaml"    "${REDHAT_OPERATOR_INDEX}"    "redhat"
    _write_isc "olm-certified" "add-certified-isc.yaml" "${CERTIFIED_OPERATOR_INDEX}" "certified"
    _write_isc "olm-community" "add-community-isc.yaml" "${COMMUNITY_OPERATOR_INDEX}" "community"
}

# =============================================================================
# RUN_ID 할당: YYYYMMDD + 순번(01~99)
# =============================================================================
allocate_run_id() {
    local date_part seq next max_seq=0 name d

    date_part="$(date +%Y%m%d)"

    if [[ -z "${ADD_OPERATORS_MIRROR_DIR:-}" ]]; then
        echo "[ERROR] ADD_OPERATORS_MIRROR_DIR 가 설정되어 있지 않습니다 (config.env 확인)."
        exit 1
    fi

    mkdir -p "${ADD_OPERATORS_MIRROR_DIR}"

    while IFS= read -r d; do
        [[ -n "${d}" ]] || continue
        name="$(basename "${d}")"
        if [[ "${name}" =~ ^${date_part}([0-9]{2})$ ]]; then
            seq="${BASH_REMATCH[1]}"
            if (( 10#${seq} > max_seq )); then
                max_seq=$((10#${seq}))
            fi
        fi
    done < <(find "${ADD_OPERATORS_MIRROR_DIR}" -maxdepth 1 -mindepth 1 -type d 2>/dev/null)

    next=$((max_seq + 1))
    if (( next > 99 )); then
        echo "[ERROR] ${date_part} 일자 RUN_ID 순번이 99를 초과했습니다."
        exit 1
    fi

    RUN_ID="${date_part}$(printf '%02d' "${next}")"
}

# =============================================================================
# main
# =============================================================================
main() {
    allocate_run_id
    RUN_DIR="${ADD_OPERATORS_MIRROR_DIR}/${RUN_ID}"

    echo ""
    echo "================================================================="
    echo " 추가 Operator ISC 파일 생성"
    echo "  RUN_ID  : ${RUN_ID}"
    echo "  RUN_DIR : ${RUN_DIR}"
    echo "================================================================="

    # jq 설치 확인
    if ! command -v jq &>/dev/null; then
        echo "[WARN] jq 가 설치되어 있지 않습니다. defaultChannel 조회를 건너뛰고 'stable' 로 대체합니다."
        echo "[WARN] jq 설치: dnf install -y jq"
    fi

    # opm 설치 확인
    if ! command -v opm &>/dev/null; then
        echo "[WARN] opm 이 설치되어 있지 않습니다. defaultChannel 조회를 건너뛰고 'stable' 로 대체합니다."
    fi

    # ADD_OPERATORS 검증 및 출력
    check_add_operators

    # opm render 캐시 초기화
    init_render_cache

    # ISC 파일 생성
    create_isc_files

    echo ""
    echo "================================================================="
    echo "[DONE] ISC 파일 생성 완료."
    echo "  RUN_ID  : ${RUN_ID}"
    echo "  RUN_DIR : ${RUN_DIR}"
    echo ""
    echo "  다음 단계: ./02_mirror_add_operators.sh ${RUN_ID}"
    echo "================================================================="
}

main "$@"
