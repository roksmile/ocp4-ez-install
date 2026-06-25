#!/usr/bin/env bash
# =============================================================================
# 03_create_registry.sh - Mirror Registry 구성 (Air-Gap 환경)
# =============================================================================
# Podman 기반 컨테이너 레지스트리를 구성합니다.
#
# 사전 조건:
#   - 02_create_certs.sh 로 서버 인증서가 생성되어 있어야 합니다.
#     경로: certs/${BASE_DOMAIN}/domain_certs/${MIRROR_REGISTRY_HOST}.*
#
# 구성 요소:
#   - /opt/registry/{auth,data,certs}  - 레지스트리 데이터 디렉토리
#   - htpasswd 인증 (admin / MIRROR_REGISTRY_PASS)
#   - TLS 활성화
#   - systemd 서비스 등록 (mirror-registry.service)
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 헬퍼 함수
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

info()  { echo "[INFO] $*"; }
warn()  { echo "[WARN] $*"; }
error() { echo "[ERROR] $*" >&2; }
title() {
    echo ""
    echo "================================================================="
    echo "  $*"
    echo "================================================================="
    echo ""
}

# -----------------------------------------------------------------------------
# 레지스트리 설정 (config.env 기반 - 대화형으로 재확인)
# -----------------------------------------------------------------------------
REGISTRY_BASE_HOME="/opt/registry"
REGISTRY_CONTAINER_NAME="mirror-registry"
REGISTRY_IMAGE="docker.io/library/registry:2"

# 인증서 경로는 prompt_registry_info() 호출 후 설정됩니다.
DOMAIN_CRT=""
DOMAIN_KEY=""
CA_CRT=""

# -----------------------------------------------------------------------------
# 대화형 레지스트리 정보 입력
# -----------------------------------------------------------------------------
prompt_registry_info() {
    echo ""
    echo "================================================================="
    echo "  레지스트리 설정 확인 (Enter 입력 시 config.env 기본값 사용)"
    echo "================================================================="
    echo ""

    local input

    read -rp "  Registry Host  [${MIRROR_REGISTRY_HOST}]: " input
    MIRROR_REGISTRY_HOST="${input:-${MIRROR_REGISTRY_HOST}}"

    read -rp "  Registry Port  [${MIRROR_REGISTRY_PORT}]: " input
    MIRROR_REGISTRY_PORT="${input:-${MIRROR_REGISTRY_PORT}}"

    read -rp "  Registry User  [${MIRROR_REGISTRY_USER}]: " input
    MIRROR_REGISTRY_USER="${input:-${MIRROR_REGISTRY_USER}}"

    read -rsp "  Registry Pass  [엔터=기본값 유지]: " input
    echo ""
    MIRROR_REGISTRY_PASS="${input:-${MIRROR_REGISTRY_PASS}}"

    # 의존 변수 재설정
    MIRROR_REGISTRY="${MIRROR_REGISTRY_HOST}:${MIRROR_REGISTRY_PORT}"
    DOMAIN_CRT="${CERTS_DIR}/${BASE_DOMAIN}/domain_certs/${MIRROR_REGISTRY_HOST}.crt"
    DOMAIN_KEY="${CERTS_DIR}/${BASE_DOMAIN}/domain_certs/${MIRROR_REGISTRY_HOST}.key"
    CA_CRT="${CERTS_DIR}/${BASE_DOMAIN}/root_ca/ca.crt"

    echo ""
    echo "  --- 설정 확인 ---"
    printf "  %-20s %s\n" "Registry"  ": ${MIRROR_REGISTRY}"
    printf "  %-20s %s\n" "User"      ": ${MIRROR_REGISTRY_USER}"
    printf "  %-20s %s\n" "Cert"      ": ${DOMAIN_CRT}"
    echo ""
    read -rp "  위 설정으로 진행하시겠습니까? (Y/n): " confirm
    if [[ "${confirm,,}" == "n" ]]; then
        echo "[INFO] 취소되었습니다."
        exit 0
    fi
}

# -----------------------------------------------------------------------------
# RHEL 9 체크
# -----------------------------------------------------------------------------
check_rhel9() {
    if [[ ! -f /etc/redhat-release ]]; then
        error "RHEL 환경이 아닙니다. 이 스크립트는 RHEL 9에서 실행해야 합니다."
        exit 1
    fi

    local os_version
    os_version=$(grep -oP '(?<=release )\d+' /etc/redhat-release)
    if [[ "${os_version}" != "9" ]]; then
        error "RHEL 9 가 필요합니다. 현재 버전: $(cat /etc/redhat-release)"
        exit 1
    fi

    info "OS 확인: $(cat /etc/redhat-release)"
}

# -----------------------------------------------------------------------------
# root 권한 체크
# -----------------------------------------------------------------------------
check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        error "이 스크립트는 root 권한으로 실행해야 합니다."
        error "  sudo ${BASH_SOURCE[0]}"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# htpasswd 설치 확인
# -----------------------------------------------------------------------------
check_htpasswd() {
    if ! command -v htpasswd &>/dev/null; then
        info "htpasswd 명령어가 없습니다. httpd-tools 를 설치합니다."
        run dnf install -y httpd-tools
    fi
    info "htpasswd: $(htpasswd -v 2>&1 | head -1 || echo 'OK')"
}

# -----------------------------------------------------------------------------
# 인증서 존재 여부 확인
# -----------------------------------------------------------------------------
check_certs() {
    local missing=false

    if [[ ! -f "${DOMAIN_CRT}" ]]; then
        error "서버 인증서를 찾을 수 없습니다: ${DOMAIN_CRT}"
        missing=true
    fi
    if [[ ! -f "${DOMAIN_KEY}" ]]; then
        error "서버 개인키를 찾을 수 없습니다: ${DOMAIN_KEY}"
        missing=true
    fi
    if [[ ! -f "${CA_CRT}" ]]; then
        error "CA 인증서를 찾을 수 없습니다: ${CA_CRT}"
        missing=true
    fi

    if [[ "${missing}" == true ]]; then
        error "air-gapped/02_create_certs.sh 를 먼저 실행하여 인증서를 생성하세요."
        exit 1
    fi

    info "인증서 확인 완료."
    echo "  서버 Cert: ${DOMAIN_CRT}"
    echo "  서버 Key : ${DOMAIN_KEY}"
    echo "  CA Cert  : ${CA_CRT}"
}

# -----------------------------------------------------------------------------
# 디렉토리 생성
# -----------------------------------------------------------------------------
create_dirs() {
    title "디렉토리 생성"

    info "${REGISTRY_BASE_HOME}/{auth,data,certs} 생성 중..."
    run mkdir -p "${REGISTRY_BASE_HOME}/"{auth,data,certs}
}

# -----------------------------------------------------------------------------
# 인증서 복사
# -----------------------------------------------------------------------------
copy_certs() {
    title "인증서 복사"

    run cp "${DOMAIN_CRT}" "${REGISTRY_BASE_HOME}/certs/registry.crt"
    run cp "${DOMAIN_KEY}"  "${REGISTRY_BASE_HOME}/certs/registry.key"
    run cp "${CA_CRT}"      "${REGISTRY_BASE_HOME}/certs/ca.crt"
    chmod 600 "${REGISTRY_BASE_HOME}/certs/registry.key"

    info "인증서 복사 완료."
    echo "  → ${REGISTRY_BASE_HOME}/certs/registry.crt"
    echo "  → ${REGISTRY_BASE_HOME}/certs/registry.key"
    echo "  → ${REGISTRY_BASE_HOME}/certs/ca.crt"
}

# -----------------------------------------------------------------------------
# htpasswd 인증 파일 생성
# -----------------------------------------------------------------------------
create_htpasswd() {
    title "인증 계정 생성"

    info "계정 생성: ${MIRROR_REGISTRY_USER}"
    run htpasswd -bBc "${REGISTRY_BASE_HOME}/auth/htpasswd" \
        "${MIRROR_REGISTRY_USER}" "${MIRROR_REGISTRY_PASS}"

    info "htpasswd 파일: ${REGISTRY_BASE_HOME}/auth/htpasswd"
}

# -----------------------------------------------------------------------------
# Docker / Podman 인증 설정 (~/.docker/config.json)
# -----------------------------------------------------------------------------
configure_docker_auth() {
    title "Docker 인증 설정"

    local auth_encoded
    auth_encoded=$(echo -n "${MIRROR_REGISTRY_USER}:${MIRROR_REGISTRY_PASS}" | base64 -w0)

    mkdir -p ~/.docker
    cat > ~/.docker/config.json <<EOF
{
  "auths": {
    "${MIRROR_REGISTRY}": {
      "auth": "${auth_encoded}"
    }
  }
}
EOF

    info "Docker 인증 설정 완료: ~/.docker/config.json"
    echo "  Registry: ${MIRROR_REGISTRY}"
    echo "  User    : ${MIRROR_REGISTRY_USER}"
}

# -----------------------------------------------------------------------------
# CA 인증서 시스템 신뢰 저장소에 등록
# -----------------------------------------------------------------------------
trust_ca() {
    title "CA 인증서 시스템 등록"

    run cp "${REGISTRY_BASE_HOME}/certs/ca.crt" \
        "/etc/pki/ca-trust/source/anchors/${MIRROR_REGISTRY_HOST}-ca.crt"
    run update-ca-trust extract

    info "CA 인증서가 시스템 신뢰 저장소에 등록되었습니다."
}

# -----------------------------------------------------------------------------
# 기존 컨테이너 정리
# -----------------------------------------------------------------------------
cleanup_container() {
    if podman container exists "${REGISTRY_CONTAINER_NAME}" 2>/dev/null; then
        warn "기존 컨테이너(${REGISTRY_CONTAINER_NAME})가 존재합니다. 제거합니다."
        run podman rm -f "${REGISTRY_CONTAINER_NAME}"
    fi
}

# -----------------------------------------------------------------------------
# Registry 컨테이너 실행
# -----------------------------------------------------------------------------
run_registry() {
    title "Registry 컨테이너 실행"

    cleanup_container

    run podman run -d --name "${REGISTRY_CONTAINER_NAME}" \
        -p "${MIRROR_REGISTRY_PORT}":5000 \
        -v "${REGISTRY_BASE_HOME}/data:/var/lib/registry:z" \
        -v "${REGISTRY_BASE_HOME}/auth:/auth:z" \
        -v "${REGISTRY_BASE_HOME}/certs:/certs:z" \
        -e REGISTRY_AUTH=htpasswd \
        -e REGISTRY_AUTH_HTPASSWD_REALM="Registry Realm" \
        -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
        -e REGISTRY_HTTP_SECRET="$(openssl rand -hex 16)" \
        -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/registry.crt \
        -e REGISTRY_HTTP_TLS_KEY=/certs/registry.key \
        "${REGISTRY_IMAGE}"

    info "컨테이너 실행 완료: ${REGISTRY_CONTAINER_NAME}"
}

# -----------------------------------------------------------------------------
# systemd 서비스 등록
# -----------------------------------------------------------------------------
create_systemd_service() {
    title "systemd 서비스 등록"

    local service_file="/etc/systemd/system/${REGISTRY_CONTAINER_NAME}.service"

    run podman generate systemd --new --name "${REGISTRY_CONTAINER_NAME}" \
        > "${service_file}"

    # 컨테이너는 systemd 로 관리하므로 수동 실행 컨테이너 중지
    run podman stop "${REGISTRY_CONTAINER_NAME}" 2>/dev/null || true
    run podman rm   "${REGISTRY_CONTAINER_NAME}" 2>/dev/null || true

    run systemctl daemon-reload
    run systemctl enable --now "${REGISTRY_CONTAINER_NAME}.service"

    info "서비스 등록 완료: ${REGISTRY_CONTAINER_NAME}.service"
}

# -----------------------------------------------------------------------------
# 방화벽 포트 오픈
# -----------------------------------------------------------------------------
configure_firewall() {
    title "방화벽 설정"

    if systemctl is-active --quiet firewalld; then
        info "firewalld 에 ${MIRROR_REGISTRY_PORT}/tcp 포트를 추가합니다."
        run firewall-cmd --add-port="${MIRROR_REGISTRY_PORT}/tcp" --permanent
        run firewall-cmd --reload
    else
        info "firewalld 가 실행 중이지 않습니다. 방화벽 설정을 건너뜁니다."
    fi
}

# -----------------------------------------------------------------------------
# 레지스트리 동작 확인
# -----------------------------------------------------------------------------
verify_registry() {
    title "레지스트리 동작 확인"

    info "서비스 상태:"
    systemctl status "${REGISTRY_CONTAINER_NAME}.service" --no-pager -l || true

    echo ""
    info "Registry 접속 테스트: https://${MIRROR_REGISTRY}/v2/"
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        --cacert "${REGISTRY_BASE_HOME}/certs/ca.crt" \
        -u "${MIRROR_REGISTRY_USER}:${MIRROR_REGISTRY_PASS}" \
        "https://${MIRROR_REGISTRY}/v2/" 2>/dev/null || echo "000")

    if [[ "${http_code}" == "200" ]]; then
        info "Registry 응답 OK (HTTP ${http_code})"
    else
        warn "Registry 응답 코드: ${http_code}"
        warn "서비스가 완전히 시작되지 않았을 수 있습니다. 잠시 후 다시 확인하세요."
        warn "  systemctl status ${REGISTRY_CONTAINER_NAME}.service"
    fi
}

# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------
main() {
    echo ""
    echo "================================================================="
    echo "  OCP4 Mirror Registry 구성 스크립트 (Air-Gap)"
    echo "================================================================="
    printf "  %-20s %s\n" "Registry"     ": ${MIRROR_REGISTRY}"
    printf "  %-20s %s\n" "User"         ": ${MIRROR_REGISTRY_USER}"
    printf "  %-20s %s\n" "Base Dir"     ": ${REGISTRY_BASE_HOME}"
    printf "  %-20s %s\n" "Container"    ": ${REGISTRY_CONTAINER_NAME}"
    printf "  %-20s %s\n" "Cert (Src)"   ": ${DOMAIN_CRT}"
    echo "================================================================="
    echo ""

    prompt_registry_info

    check_rhel9
    check_root
    check_htpasswd
    check_certs

    create_dirs
    copy_certs
    create_htpasswd
    configure_docker_auth
    trust_ca
    run_registry
    create_systemd_service
    configure_firewall
    verify_registry

    echo ""
    echo "================================================================="
    info "Mirror Registry 구성이 완료되었습니다."
    echo ""
    echo "  Registry URL : https://${MIRROR_REGISTRY}"
    echo "  사용자 계정  : ${MIRROR_REGISTRY_USER} / ${MIRROR_REGISTRY_PASS}"
    echo "  데이터 경로  : ${REGISTRY_BASE_HOME}/data"
    echo "  서비스       : systemctl status ${REGISTRY_CONTAINER_NAME}.service"
    echo "================================================================="
    echo ""
    info "다음 단계: air-gapped/04_upload_mirror.sh 를 실행하여 이미지를 업로드하세요."
}

main "$@"
