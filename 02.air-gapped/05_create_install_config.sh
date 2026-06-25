#!/usr/bin/env bash
# =============================================================================
# 05_create_install_config.sh - install-config.yaml 생성 (Agent-Based Install)
# =============================================================================
# config.env 의 NODES 배열을 파싱하여 master/worker 수를 확인하고,
# agent-based install 방식에 필요한 install-config.yaml 을 생성합니다.
# NTP 는 OpenShift Agent 설치에서 install-config(platform: none)에 넣을 수 없으며
# 06_create_agent_config.sh 가 생성하는 agent-config.yaml 의 additionalNTPSources
# (config.env 의 NTP_SERVERS)를 사용합니다.
#
# 출력 파일: ${BASE_DIR}/${CLUSTER_NAME}/orig/install-config.yaml
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
# 노드 파싱 함수
# 형식: "role:hostname:ip:nic:mac"
# -----------------------------------------------------------------------------
parse_nodes() {
    MASTER_COUNT=0
    WORKER_COUNT=0
    MASTER_NODES=()
    WORKER_NODES=()

    for entry in "${NODES[@]}"; do
        local role hostname ip nic mac
        IFS='|' read -r role hostname ip nic mac <<< "${entry}"

        case "${role}" in
            master)
                MASTER_COUNT=$(( MASTER_COUNT + 1 ))
                MASTER_NODES+=("${entry}")
                ;;
            worker)
                WORKER_COUNT=$(( WORKER_COUNT + 1 ))
                WORKER_NODES+=("${entry}")
                ;;
            *)
                echo "[WARN] 알 수 없는 노드 role: '${role}' (항목: ${entry}) — 건너뜁니다."
                ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# SSH 공개 키 확인 및 멀티라인 블록 구성
# SSH_PUB_KEY 는 config.env 에서 배열로 정의 (1개 이상)
# → YAML sshKey: | 멀티라인 블록용 SSH_KEY_BLOCK 변수에 저장
# -----------------------------------------------------------------------------
check_ssh_pub_key() {
    if [[ "${#SSH_PUB_KEY[@]}" -eq 0 ]]; then
        echo "[ERROR] SSH_PUB_KEY 가 config.env 에 설정되지 않았습니다."
        echo "        ssh-keygen 으로 키를 생성한 후 공개 키 내용을 SSH_PUB_KEY 배열에 추가하세요."
        exit 1
    fi

    SSH_KEY_BLOCK=""
    for key in "${SSH_PUB_KEY[@]}"; do
        [[ -z "${key}" ]] && continue
        SSH_KEY_BLOCK+="${key}"$'\n'
    done

    echo "[INFO] SSH 공개 키 ${#SSH_PUB_KEY[@]}개 확인 완료"
}

# -----------------------------------------------------------------------------
# Pull Secret 읽기
# -----------------------------------------------------------------------------
load_pull_secret() {
    if [[ ! -f "${PULL_SECRET_FILE}" ]]; then
        echo "[ERROR] Pull Secret 파일을 찾을 수 없습니다: ${PULL_SECRET_FILE}"
        echo "        https://console.redhat.com/openshift/install/pull-secret 에서 다운로드 후"
        echo "        ${PULL_SECRET_FILE} 에 저장하세요."
        exit 1
    fi
    PULL_SECRET=$(cat "${PULL_SECRET_FILE}")
    echo "[INFO] Pull Secret 로드: ${PULL_SECRET_FILE}"
}

# -----------------------------------------------------------------------------
# Mirror Registry CA 인증서 선택 (additionalTrustBundle)
# 02_create_certs.sh 가 생성한 ${CERTS_DIR}/{domain}/root_ca/ca.crt 중 선택
# -----------------------------------------------------------------------------
load_ca_cert() {
    CA_CERT=""

    # CERTS_DIR 하위의 CA 인증서 목록 스캔
    local ca_list=()
    if [[ -d "${CERTS_DIR}" ]]; then
        while IFS= read -r -d '' ca_file; do
            ca_list+=("${ca_file}")
        done < <(find "${CERTS_DIR}" -mindepth 3 -maxdepth 3 \
                      -path "*/root_ca/ca.crt" -print0 2>/dev/null | sort -z)
    fi

    if [[ "${#ca_list[@]}" -eq 0 ]]; then
        echo "[WARN] ${CERTS_DIR} 에 CA 인증서가 없습니다."
        echo "       additionalTrustBundle 섹션은 생략됩니다."
        echo "       air-gap 환경에서는 02_create_certs.sh 를 먼저 실행하세요."
        return 0
    fi

    echo ""
    echo "  사용 가능한 CA 인증서 목록:"
    local idx=1
    for ca_file in "${ca_list[@]}"; do
        local domain
        domain=$(basename "$(dirname "$(dirname "${ca_file}")")")
        printf "    %d) [%s]  %s\n" "${idx}" "${domain}" "${ca_file}"
        idx=$(( idx + 1 ))
    done
    echo "    s) 건너뛰기 (additionalTrustBundle 생략)"
    echo ""

    local selected_ca=""
    while true; do
        read -rp "  CA 인증서를 선택하세요 [1]: " input
        input="${input:-1}"

        if [[ "${input}" == "s" || "${input}" == "S" ]]; then
            echo "[INFO] additionalTrustBundle 생략합니다."
            return 0
        fi

        if [[ "${input}" =~ ^[0-9]+$ ]] && \
           (( input >= 1 && input <= ${#ca_list[@]} )); then
            selected_ca="${ca_list[$(( input - 1 ))]}"
            break
        fi
        echo "  [WARN] 올바른 번호를 입력하세요."
    done

    CA_CERT=$(cat "${selected_ca}")
    echo "[INFO] CA 인증서 로드: ${selected_ca}"
}

# -----------------------------------------------------------------------------
# 출력 디렉토리 준비
# -----------------------------------------------------------------------------
prepare_output_dir() {
    local out_dir="${CLUSTER_DIR}/orig"
    mkdir -p "${out_dir}"
    OUTPUT_FILE="${out_dir}/install-config.yaml"
    echo "[INFO] 출력 경로: ${OUTPUT_FILE}"
}

# -----------------------------------------------------------------------------
# install-config.yaml 생성
# -----------------------------------------------------------------------------
generate_install_config() {
    local art_mirror="${MIRROR_REGISTRY}/openshift/release"
    local art_source="quay.io/openshift-release-dev/ocp-v4.0-art-dev"
    local release_mirror="${MIRROR_REGISTRY}/openshift/release-images"
    local release_source="quay.io/openshift-release-dev/ocp-release"

    # ── 기본 섹션 ──────────────────────────────────────────────────────────
    cat > "${OUTPUT_FILE}" <<EOF
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
compute:
- architecture: amd64
  hyperthreading: Enabled
  name: worker
  replicas: ${WORKER_COUNT}
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  replicas: ${MASTER_COUNT}
networking:
  clusterNetwork:
  - cidr: ${CLUSTER_NETWORK_CIDR}
    hostPrefix: ${CLUSTER_NETWORK_HOST_PREFIX}
  machineNetwork:
  - cidr: ${MACHINE_NETWORK}
  networkType: OVNKubernetes
  serviceNetwork:
  - ${SERVICE_NETWORK}
platform:
  none: {}
fips: false
pullSecret: '${PULL_SECRET}'
EOF

    # ── sshKey (1개: 단일행 / 2개 이상: | 블록) ────────────────────────────
    if [[ "${#SSH_PUB_KEY[@]}" -eq 1 ]]; then
        printf 'sshKey: %s\n' "${SSH_PUB_KEY[0]}" >> "${OUTPUT_FILE}"
    else
        printf 'sshKey: |\n' >> "${OUTPUT_FILE}"
        for key in "${SSH_PUB_KEY[@]}"; do
            [[ -z "${key}" ]] && continue
            printf '  %s\n' "${key}" >> "${OUTPUT_FILE}"
        done
    fi

    # ── additionalTrustBundle (CA 인증서가 있을 때만, sshKey 바로 다음) ────
    if [[ -n "${CA_CERT}" ]]; then
        printf 'additionalTrustBundle: |\n' >> "${OUTPUT_FILE}"
        while IFS= read -r line; do
            printf '  %s\n' "${line}" >> "${OUTPUT_FILE}"
        done <<< "${CA_CERT}"
    fi

    # ── imageDigestSources ─────────────────────────────────────────────────
    cat >> "${OUTPUT_FILE}" <<EOF
imageDigestSources:
- mirrors:
  - ${art_mirror}
  source: ${art_source}
- mirrors:
  - ${release_mirror}
  source: ${release_source}
EOF
}

# -----------------------------------------------------------------------------
# 노드 정보 요약 출력
# -----------------------------------------------------------------------------
print_node_summary() {
    echo ""
    echo "================================================================="
    echo " 노드 구성 요약"
    echo "================================================================="
    printf "%-10s %-12s %-18s %-10s %s\n" "ROLE" "HOSTNAME" "IP" "NIC" "MAC"
    printf '%s\n' "-------------------------------------------------------------------"

    for entry in "${MASTER_NODES[@]}"; do
        IFS='|' read -r role hostname ip nic mac <<< "${entry}"
        printf "%-10s %-12s %-18s %-10s %s\n" "${role}" "${hostname}" "${ip}" "${nic}" "${mac}"
    done

    for entry in "${WORKER_NODES[@]}"; do
        IFS='|' read -r role hostname ip nic mac <<< "${entry}"
        printf "%-10s %-12s %-18s %-10s %s\n" "${role}" "${hostname}" "${ip}" "${nic}" "${mac}"
    done

    echo ""
    echo " Master 수 : ${MASTER_COUNT}"
    echo " Worker 수 : ${WORKER_COUNT}"
    echo " Machine Network : ${MACHINE_NETWORK}"
    echo " Cluster Network : ${CLUSTER_NETWORK_CIDR} (hostPrefix: /${CLUSTER_NETWORK_HOST_PREFIX})"
    echo " Service Network : ${SERVICE_NETWORK}"
    echo "================================================================="
}

# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------
main() {
    echo "================================================================="
    echo " OCP4 install-config.yaml 생성 스크립트 (Agent-Based Install)"
    echo " OCP Version  : ${OCP_VERSION}"
    echo " Cluster      : ${CLUSTER_NAME}.${BASE_DOMAIN}"
    echo " Mirror       : ${MIRROR_REGISTRY}"
    echo "================================================================="

    parse_nodes

    if [[ "${MASTER_COUNT}" -eq 0 ]]; then
        echo "[ERROR] config.env 의 NODES 배열에 master 노드가 없습니다."
        exit 1
    fi

    if [[ "${MASTER_COUNT}" -ne 1 && "${MASTER_COUNT}" -ne 3 ]]; then
        echo "[WARN] master 노드 수가 ${MASTER_COUNT}대입니다. 일반적으로 1대(SNO) 또는 3대를 권장합니다."
    fi

    print_node_summary

    check_ssh_pub_key
    load_pull_secret
    load_ca_cert
    prepare_output_dir
    generate_install_config

    echo ""
    echo "[DONE] install-config.yaml 생성 완료: ${OUTPUT_FILE}"
    echo ""
    echo "[NEXT] 다음 단계:"
    echo "       06_create_agent_config.sh — agent-config.yaml 생성"
}

main "$@"
