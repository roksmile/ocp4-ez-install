#!/usr/bin/env bash
# =============================================================================
# 01_download_ocp_tools.sh - OCP4 CLI 도구 다운로드 및 설치
# =============================================================================
# 인터넷에서 OCP 도구들을 다운로드하여 /usr/local/bin/ 에 설치합니다.
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
# RHEL 9 체크
# -----------------------------------------------------------------------------
check_rhel9() {
    if [[ ! -f /etc/redhat-release ]]; then
        echo "[ERROR] RHEL 환경이 아닙니다. 이 스크립트는 RHEL 9에서 실행해야 합니다."
        exit 1
    fi

    local os_version
    os_version=$(grep -oP '(?<=release )\d+' /etc/redhat-release)
    if [[ "${os_version}" != "9" ]]; then
        echo "[ERROR] RHEL 9 가 필요합니다. 현재 버전: $(cat /etc/redhat-release)"
        exit 1
    fi

    echo "[INFO] OS 확인: $(cat /etc/redhat-release)"
}

# -----------------------------------------------------------------------------
# root 권한 체크
# -----------------------------------------------------------------------------
check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "[ERROR] /usr/local/bin/ 에 설치하려면 root 권한이 필요합니다."
        echo "        sudo 또는 root 로 실행하세요."
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# 다운로드 디렉토리 생성
# -----------------------------------------------------------------------------
prepare_dirs() {
    run mkdir -p "${DOWNLOAD_DIR}"
    run mkdir -p "${LOG_DIR}"
    echo "[INFO] 다운로드 디렉토리: ${DOWNLOAD_DIR}"
}

# -----------------------------------------------------------------------------
# 파일 다운로드 함수
# -----------------------------------------------------------------------------
# 이미 존재하면 스킵
download_file() {
    local url="$1"
    local dest="$2"

    if [[ -f "${dest}" ]]; then
        echo "[SKIP] 이미 존재: ${dest}"
        return 0
    fi

    echo "[DOWN] ${url}"
    run curl -fSL --progress-bar -o "${dest}" "${url}"
    echo "[DONE] 저장: ${dest}"
}

# -----------------------------------------------------------------------------
# OCP 도구 다운로드 및 설치 (tar.gz → 압축 해제 → /usr/local/bin/)
# -----------------------------------------------------------------------------
install_ocp_tools() {
    echo ""
    echo "================================================================="
    echo " OCP ${OCP_VERSION} 도구 다운로드 및 설치"
    echo "================================================================="

    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap "rm -rf '${tmp_dir}'" RETURN

    for filename in "${OCP_TOOL_FILES[@]}"; do
        local url="${OCP_CLIENT_URL}/${filename}"
        local dest="${DOWNLOAD_DIR}/${filename}"

        download_file "${url}" "${dest}"

        echo "[EXTR] ${filename} 압축 해제 중..."
        run tar -xzf "${dest}" -C "${tmp_dir}"
    done

    # Red Hat tarball 은 바이너리가 tmp 직하위가 아니라 하위 디렉터리에 둘 수 있음
    # (예: oc-mirror.rhel9.tar.gz → oc-mirror/oc-mirror). 이름으로 재귀 탐색 후 설치.
    echo "[INST] /usr/local/bin/ 에 실행 파일 설치 중..."
    local -a cli_names=(oc kubectl oc-mirror openshift-install opm)
    local name bin_path
    for name in "${cli_names[@]}"; do
        bin_path=$(find "${tmp_dir}" -type f -name "${name}" 2>/dev/null | head -1 || true)
        if [[ -z "${bin_path}" || ! -f "${bin_path}" ]]; then
            echo "[WARN] ${name} 바이너리를 압축 해제 결과에서 찾지 못했습니다."
            continue
        fi
        [[ -x "${bin_path}" ]] || chmod +x "${bin_path}"
        run install -m 755 "${bin_path}" "/usr/local/bin/${name}"
        echo "[INST] /usr/local/bin/${name}"
    done
}

# -----------------------------------------------------------------------------
# Butane 다운로드 및 설치 (단일 바이너리, butane-amd64 → butane)
# -----------------------------------------------------------------------------
install_butane() {
    echo ""
    echo "================================================================="
    echo " Butane 다운로드 및 설치"
    echo "================================================================="

    local dest="${DOWNLOAD_DIR}/butane-amd64"
    download_file "${BUTANE_URL}" "${dest}"

    run install -m 755 "${dest}" /usr/local/bin/butane
    echo "[INST] /usr/local/bin/butane"
}

# -----------------------------------------------------------------------------
# Helm 다운로드 및 설치 (tar.gz → helm-linux-amd64 → /usr/local/bin/)
# -----------------------------------------------------------------------------
install_helm() {
    echo ""
    echo "================================================================="
    echo " Helm ${HELM_VERSION} 다운로드 및 설치"
    echo "================================================================="

    local filename="helm-linux-amd64.tar.gz"
    local dest="${DOWNLOAD_DIR}/${filename}"

    download_file "${HELM_URL}" "${dest}"

    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap "rm -rf '${tmp_dir}'" RETURN

    echo "[EXTR] ${filename} 압축 해제 중..."
    run tar -xzf "${dest}" -C "${tmp_dir}"

    run install -m 755 "${tmp_dir}/helm-linux-amd64" /usr/local/bin/helm
    echo "[INST] /usr/local/bin/helm"
}

# -----------------------------------------------------------------------------
# 설치 결과 확인
# -----------------------------------------------------------------------------
verify_installation() {
    echo ""
    echo "================================================================="
    echo " 설치 결과 확인"
    echo "================================================================="

    local tools=("oc" "kubectl" "oc-mirror" "openshift-install" "opm" "butane" "helm")
    local all_ok=true

    for tool in "${tools[@]}"; do
        if command -v "${tool}" &>/dev/null; then
            local ver
            case "${tool}" in
                butane)
                    ver=$("${tool}" -V 2>/dev/null | head -1 || echo "(버전 확인 불가)") ;;
                *)
                    ver=$("${tool}" version --client 2>/dev/null | head -1 \
                          || "${tool}" version 2>/dev/null | head -1 \
                          || echo "(버전 확인 불가)") ;;
            esac
            printf "[OK]   %-20s %s\n" "${tool}" "${ver}"
        else
            printf "[MISS] %-20s 설치되지 않음\n" "${tool}"
            all_ok=false
        fi
    done

    echo ""
    if [[ "${all_ok}" == true ]]; then
        echo "[INFO] 모든 도구가 정상적으로 설치되었습니다."
    else
        echo "[WARN] 일부 도구가 설치되지 않았습니다. 위 로그를 확인하세요."
    fi
}

# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------
main() {
    echo "================================================================="
    echo " OCP4 CLI 도구 설치 스크립트"
    echo " OCP Version : ${OCP_VERSION}"
    echo " Install Dir : /usr/local/bin/"
    echo " Download Dir: ${DOWNLOAD_DIR}"
    echo "================================================================="

    check_rhel9
    check_root
    prepare_dirs

    install_ocp_tools
    install_butane
    install_helm

    verify_installation

    echo ""
    echo "[DONE] 설치 완료."
}

main "$@"
