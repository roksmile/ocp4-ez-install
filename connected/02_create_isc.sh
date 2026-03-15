#!/usr/bin/env bash
# =============================================================================
# 02_create_isc.sh - ImageSetConfiguration 파일 생성
# =============================================================================
# oc-mirror v2 에서 사용할 ISC 파일을 생성합니다.
# 생성 위치: ${MIRROR_DIR}/{ocp,olm-redhat,olm-certified,olm-community,add-images}/
# =============================================================================

set -uo pipefail

# -----------------------------------------------------------------------------
# 명령어 출력 후 실행 헬퍼
# -----------------------------------------------------------------------------
run() {
    echo "[CMD] $*"
    "$@"
}

# 파일 쓰기 전 출력 헬퍼
write_file() {
    echo "[CMD] cat > $1"
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
# 전역 변수
# -----------------------------------------------------------------------------
SELECTED_OPERATORS=()
RENDER_CACHE_DIR=""

# =============================================================================
# opm render 캐시 관련
# =============================================================================
init_render_cache() {
    RENDER_CACHE_DIR=$(mktemp -d)
    trap "rm -rf '${RENDER_CACHE_DIR}'" EXIT
}

# 카탈로그 URL → 안전한 파일명
_catalog_cache_file() {
    local catalog_url="$1"
    local safe_name
    safe_name=$(echo "${catalog_url}" | tr '/:.' '_')
    echo "${RENDER_CACHE_DIR}/${safe_name}.json"
}

# 카탈로그 렌더 (캐시 있으면 스킵)
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

# defaultChannel 조회 (실패 시 "stable" 반환)
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
# mirror 하위 디렉토리 초기화
# =============================================================================
cleanup_mirror_dirs() {
    local -a isc_dirs=("ocp" "olm-redhat" "olm-certified" "olm-community" "add-images")
    local found=false

    for dir in "${isc_dirs[@]}"; do
        [[ -d "${MIRROR_DIR}/${dir}" ]] && found=true && break
    done

    if [[ "${found}" == "true" ]]; then
        echo "[WARN] mirror 하위 디렉토리가 존재합니다. 삭제 후 재생성합니다."
        for dir in "${isc_dirs[@]}"; do
            [[ -d "${MIRROR_DIR}/${dir}" ]] && run rm -rf "${MIRROR_DIR}/${dir}"
        done
        echo ""
    fi
}

# =============================================================================
# OCP ISC 생성
# =============================================================================
create_ocp_isc() {
    local ocp_dir="${MIRROR_DIR}/ocp"
    local isc_file="${ocp_dir}/ocp-isc.yaml"

    echo ""
    echo "================================================================="
    echo " OCP ${OCP_VERSION} ISC 파일 생성"
    echo "================================================================="

    run mkdir -p "${ocp_dir}"

    write_file "${isc_file}"
    cat > "${isc_file}" << EOF
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  platform:
    channels:
    - name: ${OCP_CHANNEL}
      minVersion: ${OCP_VERSION}
      maxVersion: ${OCP_VERSION}
EOF

    echo "[OK]   OCP ISC 파일 생성: ${isc_file}"
}

# =============================================================================
# Operator ISC 생성
# =============================================================================

# 카탈로그별 OLM ISC 파일 생성 (내부 함수)
# 인자: <dir_name> <file_name> <catalog_url> <catalog_type>
_write_olm_isc() {
    local dir_name="$1"
    local file_name="$2"
    local catalog_url="$3"
    local catalog_type="$4"

    local -a packages=()

    # BASE_OPERATORS 에서 이 카탈로그에 해당하는 것 추가
    for op in "${BASE_OPERATORS[@]}"; do
        [[ "${op##*:}" == "${catalog_type}" ]] && packages+=("${op%%:*}")
    done

    # 선택된 Operator 에서 이 카탈로그에 해당하는 것 추가
    for op in "${SELECTED_OPERATORS[@]}"; do
        [[ "${op##*:}" == "${catalog_type}" ]] && packages+=("${op%%:*}")
    done

    if [[ ${#packages[@]} -eq 0 ]]; then
        echo "[SKIP] ${dir_name}: 포함할 패키지 없음 - 파일 생성 건너뜀"
        return
    fi

    local isc_dir="${MIRROR_DIR}/${dir_name}"
    run mkdir -p "${isc_dir}"

    write_file "${isc_dir}/${file_name}"
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
    } > "${isc_dir}/${file_name}"

    echo "[OK]   ${dir_name} ISC 파일 생성: ${isc_dir}/${file_name}"
}

create_operator_isc() {
    echo ""
    echo "================================================================="
    echo " Operator ISC 파일 생성"
    echo "================================================================="

    if [[ ${#SELECTED_OPERATORS[@]} -eq 0 && ${#BASE_OPERATORS[@]} -eq 0 ]]; then
        echo "[WARN] 선택된 Operator 가 없습니다. Operator ISC 파일을 생성하지 않습니다."
        return
    fi

    _write_olm_isc "olm-redhat"    "olm-redhat-isc.yaml"    "${REDHAT_OPERATOR_INDEX}"    "redhat"
    _write_olm_isc "olm-certified" "olm-certified-isc.yaml" "${CERTIFIED_OPERATOR_INDEX}" "certified"
    _write_olm_isc "olm-community" "olm-community-isc.yaml" "${COMMUNITY_OPERATOR_INDEX}" "community"
}

# =============================================================================
# Add-images ISC 생성
# =============================================================================
create_add_images_isc() {
    local img_dir="${MIRROR_DIR}/add-images"
    local isc_file="${img_dir}/add-images-isc.yaml"

    echo ""
    echo "================================================================="
    echo " Add-images ISC 파일 생성"
    echo "================================================================="

    run mkdir -p "${img_dir}"

    write_file "${isc_file}"
    {
        echo "kind: ImageSetConfiguration"
        echo "apiVersion: mirror.openshift.io/v2alpha1"
        echo "mirror:"
        echo "  additionalImages:"
        if [[ ${#ADDITIONAL_IMAGES[@]} -gt 0 ]]; then
            for img in "${ADDITIONAL_IMAGES[@]}"; do
                echo "  - name: ${img}"
            done
        else
            echo "  # 추가 이미지 없음 - config.env 의 ADDITIONAL_IMAGES 를 확인하세요."
        fi
    } > "${isc_file}"

    echo "[OK]   Add-images ISC 파일 생성: ${isc_file}"
}

# =============================================================================
# Operator 선택
# =============================================================================
select_operators_interactive() {
    SELECTED_OPERATORS=()

    echo ""
    echo "================================================================="
    echo " Operator 선택"
    echo "================================================================="
    echo ""

    for group_entry in "${OPERATOR_GROUPS[@]}"; do
        local group_id="${group_entry%%:*}"
        local group_desc="${group_entry##*:}"

        # base 는 자동 포함 - 선택 메뉴에서 제외
        [[ "${group_id}" == "base" ]] && continue

        echo -n "  ${group_desc} 를 추가 하시겠습니까? (y/n): "
        read -r answer

        if [[ "${answer,,}" == "y" ]]; then
            local array_name="${group_id^^}_OPERATORS[@]"
            local -a ops=("${!array_name}")
            for op in "${ops[@]}"; do
                SELECTED_OPERATORS+=("${op}")
                echo "[ADD]  ${op%%:*} [${op##*:}-operator-index]"
            done
        fi
    done

    echo ""
    if [[ ${#SELECTED_OPERATORS[@]} -gt 0 ]]; then
        echo "[INFO] 선택된 Operator: ${#SELECTED_OPERATORS[@]} 개"
    else
        echo "[INFO] 선택된 Operator 없음"
    fi
}

# =============================================================================
# main
# =============================================================================
main() {
    echo ""
    echo "================================================================="
    echo " ImageSetConfiguration 파일 생성"
    echo "  MIRROR_DIR : ${MIRROR_DIR}"
    echo "================================================================="

    # jq 설치 확인 (opm render 결과 파싱용)
    if ! command -v jq &>/dev/null; then
        echo "[WARN] jq 가 설치되어 있지 않습니다. defaultChannel 조회를 건너뛰고 'stable' 로 대체합니다."
        echo "[WARN] jq 설치: dnf install -y jq"
    fi

    # opm 설치 확인
    if ! command -v opm &>/dev/null; then
        echo "[WARN] opm 이 설치되어 있지 않습니다. defaultChannel 조회를 건너뛰고 'stable' 로 대체합니다."
    fi

    # mirror 하위 디렉토리 초기화
    cleanup_mirror_dirs

    # opm render 캐시 초기화
    init_render_cache

    # Operator 선택
    select_operators_interactive

    # ISC 파일 생성
    create_ocp_isc
    create_operator_isc
    create_add_images_isc

    echo ""
    echo "================================================================="
    echo "[DONE] ISC 파일 생성 완료."
    echo "================================================================="
}

main "$@"
