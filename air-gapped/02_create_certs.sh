#!/usr/bin/env bash
# =============================================================================
# 02_create_certs.sh - 인증서 생성 (Air-Gap 환경)
# =============================================================================
# CA 인증서 및 서버 인증서를 대화형으로 생성합니다.
#
# 디렉토리 구조:
#   certs/{domain}/root_ca/           - CA 인증서 (ca.crt, ca.key)
#   certs/{domain}/domain_certs/      - 서버 인증서 ({name}.crt, {name}.key)
#
# 사용 용도:
#   - HTTPS 서버
#   - Mirror Registry (Quay) 서버 인증
#   - Nexus Repository 서버 인증
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
# 색상 출력 헬퍼
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
title() { echo -e "\n${BOLD}${CYAN}=================================================================${NC}"; \
          echo -e "${BOLD}${CYAN}  $*${NC}"; \
          echo -e "${BOLD}${CYAN}=================================================================${NC}\n"; }

# 런타임에 설정되는 경로 변수 (prompt_domain 에서 초기화)
DOMAIN=""
CERT_DIR=""
ROOT_CA_DIR=""
DOMAIN_CERTS_DIR=""

# -----------------------------------------------------------------------------
# openssl 설치 확인
# -----------------------------------------------------------------------------
check_openssl() {
    if ! command -v openssl &>/dev/null; then
        error "openssl 이 설치되어 있지 않습니다."
        error "  sudo dnf install openssl"
        exit 1
    fi
    info "openssl: $(openssl version)"
}

# -----------------------------------------------------------------------------
# 도메인 입력받기 (디렉토리 경로 결정)
# -----------------------------------------------------------------------------
prompt_domain() {
    echo ""
    read -rp "도메인을 입력하세요 [기본값: ${BASE_DOMAIN}]: " input
    DOMAIN="${input:-${BASE_DOMAIN}}"

    CERT_DIR="${CERTS_DIR}/${DOMAIN}"
    ROOT_CA_DIR="${CERT_DIR}/root_ca"
    DOMAIN_CERTS_DIR="${CERT_DIR}/domain_certs"

    info "도메인    : ${DOMAIN}"
    info "인증서 경로: ${CERT_DIR}"
}

# -----------------------------------------------------------------------------
# Subject DN 입력받기 (config.env 기본값 사용)
# -----------------------------------------------------------------------------
prompt_subject_dn() {
    echo ""
    echo "  Subject DN 정보 (Enter 입력 시 config.env 기본값 사용)"
    echo "  ──────────────────────────────────────────────────────"
    read -rp "  Country (C)         [${CERT_C}]: " input;  local _c="${input:-${CERT_C}}"
    read -rp "  State (ST)          [${CERT_ST}]: " input; local _st="${input:-${CERT_ST}}"
    read -rp "  Locality (L)        [${CERT_L}]: " input;  local _l="${input:-${CERT_L}}"
    read -rp "  Organization (O)    [${CERT_O}]: " input;  local _o="${input:-${CERT_O}}"
    read -rp "  Org Unit (OU)       [${CERT_OU}]: " input; local _ou="${input:-${CERT_OU}}"

    # 호출자에게 반환 (nameref 또는 전역 변수)
    DN_C="${_c}"
    DN_ST="${_st}"
    DN_L="${_l}"
    DN_O="${_o}"
    DN_OU="${_ou}"
}

# =============================================================================
# 1) CA 인증서 생성
# =============================================================================
create_ca() {
    title "CA 인증서 생성"
    prompt_domain

    local ca_key="${ROOT_CA_DIR}/ca.key"
    local ca_crt="${ROOT_CA_DIR}/ca.crt"

    # 이미 존재하는 경우 덮어쓰기 확인
    if [[ -f "${ca_crt}" ]]; then
        warn "CA 인증서가 이미 존재합니다: ${ca_crt}"
        read -rp "  덮어쓰시겠습니까? (y/N): " overwrite
        if [[ "${overwrite,,}" != "y" ]]; then
            info "취소되었습니다."
            return 0
        fi
    fi

    # Subject DN 입력
    prompt_subject_dn

    echo ""
    local default_cn="${DOMAIN} Root CA"
    read -rp "  Common Name (CN)    [${default_cn}]: " input
    local cn="${input:-${default_cn}}"

    mkdir -p "${ROOT_CA_DIR}"

    # CA 전용 OpenSSL 설정 파일 생성
    local ca_conf
    ca_conf=$(mktemp --suffix=".cnf")
    cat > "${ca_conf}" <<EOF
[req]
distinguished_name = req_dn
x509_extensions    = v3_ca
prompt             = no

[req_dn]
C  = ${DN_C}
ST = ${DN_ST}
L  = ${DN_L}
O  = ${DN_O}
OU = ${DN_OU}
CN = ${cn}

[v3_ca]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints       = critical, CA:TRUE
keyUsage               = critical, digitalSignature, cRLSign, keyCertSign
EOF

    echo ""
    info "CA 개인키 생성 중... (4096 bit RSA)"
    openssl genrsa -out "${ca_key}" 4096 2>/dev/null
    chmod 600 "${ca_key}"

    info "CA 인증서 자가 서명 중... (유효기간: 10년 / 3650일)"
    openssl req -new -x509 \
        -key    "${ca_key}" \
        -out    "${ca_crt}" \
        -days   3650 \
        -config "${ca_conf}" 2>/dev/null

    rm -f "${ca_conf}"

    echo ""
    info "CA 인증서 생성 완료!"
    echo "  CA Key : ${ca_key}"
    echo "  CA Cert: ${ca_crt}"
    echo ""
    info "인증서 정보:"
    openssl x509 -in "${ca_crt}" -noout -subject -dates 2>/dev/null
}

# =============================================================================
# 2) 서버 인증서 생성
# =============================================================================
create_server_cert() {
    title "서버 인증서 생성"

    # ── STEP 1: 사용할 CA 선택 ──────────────────────────────────────────────
    # CA는 별도 도메인(CA 생성 시 입력한 값)으로 찾습니다.
    # 서버의 FQDN(CN)과 CA 도메인은 다를 수 있습니다.
    # 예) CA 도메인: kdneri.com
    #     서버 CN  : registry.kscada.kdneri.com

    # 등록된 CA 목록 자동 탐색
    local ca_domains=()
    if [[ -d "${CERTS_DIR}" ]]; then
        while IFS= read -r -d '' d; do
            local candidate_ca="${d}/root_ca/ca.crt"
            [[ -f "${candidate_ca}" ]] && ca_domains+=("$(basename "${d}")")
        done < <(find "${CERTS_DIR}" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
    fi

    echo ""
    local ca_domain
    if [[ ${#ca_domains[@]} -gt 0 ]]; then
        echo "  사용 가능한 CA 목록:"
        local idx=1
        for d in "${ca_domains[@]}"; do
            printf "    %d) %s\n" "${idx}" "${d}"
            idx=$((idx + 1))
        done
        echo ""
        read -rp "  CA 도메인을 선택하거나 직접 입력하세요 [기본값: ${ca_domains[0]}]: " input

        # 숫자 선택인지 확인
        if [[ "${input}" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= ${#ca_domains[@]} )); then
            ca_domain="${ca_domains[$((input - 1))]}"
        else
            ca_domain="${input:-${ca_domains[0]}}"
        fi
    else
        read -rp "  CA 도메인을 입력하세요 (CA 생성 시 입력한 도메인): " ca_domain
        if [[ -z "${ca_domain}" ]]; then
            error "CA 도메인은 필수 입력입니다. 먼저 메뉴 1번으로 CA를 생성하세요."
            return 1
        fi
    fi

    local ca_dir="${CERTS_DIR}/${ca_domain}"
    local ca_key="${ca_dir}/root_ca/ca.key"
    local ca_crt="${ca_dir}/root_ca/ca.crt"
    local domain_certs_dir="${ca_dir}/domain_certs"

    info "CA 도메인  : ${ca_domain}"
    info "CA 경로    : ${ca_dir}/root_ca/"

    # CA 인증서 존재 확인
    if [[ ! -f "${ca_crt}" || ! -f "${ca_key}" ]]; then
        error "CA 인증서를 찾을 수 없습니다: ${ca_dir}/root_ca/"
        error "먼저 메뉴 1번으로 CA 인증서를 생성하세요."
        return 1
    fi

    mkdir -p "${domain_certs_dir}"

    # ── STEP 2: 서버 CN 입력 (와일드카드 허용) ──────────────────────────────
    echo ""
    echo "  서버 Common Name (CN) - 실제 서버 FQDN 또는 와일드카드"
    echo "  예) registry.kscada.${ca_domain}  또는  *.${ca_domain}"
    read -rp "  Common Name (CN): " cn
    if [[ -z "${cn}" ]]; then
        error "CN은 필수 입력입니다."
        return 1
    fi

    # 파일명: *.example.com → wildcard.example.com
    local cert_name="${cn//\*./wildcard.}"
    local server_key="${domain_certs_dir}/${cert_name}.key"
    local server_csr="${domain_certs_dir}/${cert_name}.csr"
    local server_crt="${domain_certs_dir}/${cert_name}.crt"

    if [[ -f "${server_crt}" ]]; then
        warn "서버 인증서가 이미 존재합니다: ${server_crt}"
        read -rp "  덮어쓰시겠습니까? (y/N): " overwrite
        if [[ "${overwrite,,}" != "y" ]]; then
            info "취소되었습니다."
            return 0
        fi
    fi

    # Subject DN 입력
    prompt_subject_dn

    # ── SAN DNS 항목 입력 ──────────────────────────────────────────────────
    echo ""
    echo "  SAN DNS 항목 (CN은 자동으로 DNS.1 에 추가됩니다)"
    echo "  빈 값 입력 시 종료합니다."

    local san_dns=("${cn}")
    local dns_idx=2
    while true; do
        read -rp "  DNS.${dns_idx} (빈값=종료): " dns_entry
        [[ -z "${dns_entry}" ]] && break
        san_dns+=("${dns_entry}")
        dns_idx=$((dns_idx + 1))
    done

    # ── SAN IP 항목 입력 ───────────────────────────────────────────────────
    echo ""
    echo "  SAN IP 항목 (빈 값 입력 시 종료합니다)"

    local san_ip=()
    local ip_idx=1
    while true; do
        read -rp "  IP.${ip_idx} (빈값=종료): " ip_entry
        [[ -z "${ip_entry}" ]] && break
        san_ip+=("${ip_entry}")
        ip_idx=$((ip_idx + 1))
    done

    # ── [alt_names] 섹션 문자열 구성 ──────────────────────────────────────
    local alt_names=""
    local i=1
    for dns in "${san_dns[@]}"; do
        alt_names+="DNS.${i} = ${dns}"$'\n'
        i=$((i + 1))
    done
    i=1
    for ip in "${san_ip[@]}"; do
        alt_names+="IP.${i} = ${ip}"$'\n'
        i=$((i + 1))
    done

    # ── CSR 생성용 OpenSSL 설정 ────────────────────────────────────────────
    local req_conf
    req_conf=$(mktemp --suffix=".cnf")
    cat > "${req_conf}" <<EOF
[req]
distinguished_name = req_dn
req_extensions     = v3_req
prompt             = no

[req_dn]
C  = ${DN_C}
ST = ${DN_ST}
L  = ${DN_L}
O  = ${DN_O}
OU = ${DN_OU}
CN = ${cn}

[v3_req]
basicConstraints     = CA:FALSE
keyUsage             = critical, digitalSignature, keyEncipherment
extendedKeyUsage     = serverAuth, clientAuth
subjectAltName       = @alt_names

[alt_names]
${alt_names}
EOF

    # ── 서명용 extension 파일 (openssl x509 -extfile 용) ──────────────────
    # openssl x509 -req 로 서명할 때는 별도 extfile 에서 extension 을 읽습니다.
    local ext_conf
    ext_conf=$(mktemp --suffix=".cnf")
    cat > "${ext_conf}" <<EOF
[v3_req]
basicConstraints       = CA:FALSE
keyUsage               = critical, digitalSignature, keyEncipherment
extendedKeyUsage       = serverAuth, clientAuth
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid,issuer
subjectAltName         = @alt_names

[alt_names]
${alt_names}
EOF

    echo ""
    info "서버 개인키 생성 중... (2048 bit RSA)"
    openssl genrsa -out "${server_key}" 2048 2>/dev/null
    chmod 600 "${server_key}"

    info "CSR 생성 중..."
    openssl req -new \
        -key    "${server_key}" \
        -out    "${server_csr}" \
        -config "${req_conf}" 2>/dev/null

    info "CA로 서버 인증서 서명 중... (유효기간: 10년 / 3650일)"
    openssl x509 -req \
        -in         "${server_csr}" \
        -CA         "${ca_crt}" \
        -CAkey      "${ca_key}" \
        -CAcreateserial \
        -out        "${server_crt}" \
        -days       3650 \
        -sha256 \
        -extensions v3_req \
        -extfile    "${ext_conf}" 2>/dev/null

    rm -f "${server_csr}" "${req_conf}" "${ext_conf}"

    echo ""
    info "서버 인증서 생성 완료!"
    echo "  Key : ${server_key}"
    echo "  Cert: ${server_crt}"
    echo ""
    info "인증서 상세 정보:"
    openssl x509 -in "${server_crt}" -noout -subject -dates 2>/dev/null
    echo ""
    openssl x509 -in "${server_crt}" -noout -ext subjectAltName 2>/dev/null

    # 체인 검증
    echo ""
    info "CA 서명 체인 검증:"
    if openssl verify -CAfile "${ca_crt}" "${server_crt}" &>/dev/null; then
        info "검증 성공 - CA에 의해 올바르게 서명된 인증서입니다."
    else
        warn "검증 실패 - 인증서 체인에 문제가 있을 수 있습니다."
    fi
}

# =============================================================================
# 현재 인증서 목록 출력
# =============================================================================
list_certs() {
    title "생성된 인증서 목록"

    if [[ ! -d "${CERTS_DIR}" ]]; then
        info "아직 생성된 인증서가 없습니다."
        return 0
    fi

    local found=false
    while IFS= read -r -d '' domain_dir; do
        local domain_name
        domain_name=$(basename "${domain_dir}")
        echo -e "  ${BOLD}[${domain_name}]${NC}"

        # CA 인증서
        local ca_crt="${domain_dir}/root_ca/ca.crt"
        if [[ -f "${ca_crt}" ]]; then
            local expiry
            expiry=$(openssl x509 -in "${ca_crt}" -noout -enddate 2>/dev/null | cut -d= -f2)
            printf "    %-12s %s  (만료: %s)\n" "CA" "${ca_crt}" "${expiry}"
        fi

        # 서버 인증서
        while IFS= read -r -d '' crt_file; do
            local expiry
            expiry=$(openssl x509 -in "${crt_file}" -noout -enddate 2>/dev/null | cut -d= -f2)
            printf "    %-12s %s  (만료: %s)\n" "Server" "${crt_file}" "${expiry}"
        done < <(find "${domain_dir}/domain_certs" -maxdepth 1 -name "*.crt" -print0 2>/dev/null)

        echo ""
        found=true
    done < <(find "${CERTS_DIR}" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)

    [[ "${found}" == false ]] && info "아직 생성된 인증서가 없습니다."
}

# =============================================================================
# 메인 메뉴
# =============================================================================
show_menu() {
    echo ""
    echo -e "${BOLD}=============================================${NC}"
    echo -e "${BOLD}  OCP4 인증서 생성 도구${NC}"
    echo -e "${BOLD}=============================================${NC}"
    printf "  %-16s %s\n" "BASE_DOMAIN"  ": ${BASE_DOMAIN}"
    printf "  %-16s %s\n" "CERT_O / OU"  ": ${CERT_O} / ${CERT_OU}"
    printf "  %-16s %s\n" "CERTS_DIR"    ": ${CERTS_DIR}"
    echo -e "${BOLD}=============================================${NC}"
    echo ""
    echo "  1) CA 인증서 생성"
    echo "  2) 서버 인증서 생성"
    echo "  3) 생성된 인증서 목록 보기"
    echo "  q) 종료"
    echo ""
}

main() {
    check_openssl

    while true; do
        show_menu
        read -rp "선택 [1/2/3/q]: " choice
        case "${choice}" in
            1) create_ca ;;
            2) create_server_cert ;;
            3) list_certs ;;
            q|Q)
                echo ""
                info "종료합니다."
                exit 0
                ;;
            *)
                warn "올바른 메뉴를 선택하세요."
                ;;
        esac
        echo ""
        read -rp "메뉴로 돌아가려면 Enter를 누르세요..."
    done
}

main "$@"
