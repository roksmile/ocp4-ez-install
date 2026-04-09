#!/usr/bin/env bash
# =============================================================================
# 06_create_agent_config.sh - agent-config.yaml 생성 (Agent-Based Install)
# =============================================================================
# config.env 의 NODES 배열을 파싱하여 각 노드의 NMState 네트워크 설정을 포함한
# agent-config.yaml 을 생성합니다.
#
# 참조:
#   config.env        - NODES, MACHINE_NETWORK, GATEWAY, DNS_SERVERS, NTP_SERVERS
#   05_create_install_config.sh 와 동일한 NODES 형식 사용
#
# 출력 파일: ${BASE_DIR}/${CLUSTER_NAME}/orig/agent-config.yaml
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

# NTP_SERVERS 미정의 config.env 호환
if ! declare -p NTP_SERVERS &>/dev/null; then
    declare -ga NTP_SERVERS=()
fi

# -----------------------------------------------------------------------------
# 노드 파싱
# 형식: "role|hostname|ip|nic|mac"
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
# MACHINE_NETWORK 에서 prefix-length 추출
# 예: "192.168.100.0/24" → "24"
# -----------------------------------------------------------------------------
get_prefix_length() {
    echo "${MACHINE_NETWORK##*/}"
}

# -----------------------------------------------------------------------------
# rendezvousIP: 첫 번째 master 노드 IP
# -----------------------------------------------------------------------------
get_rendezvous_ip() {
    local first_master="${MASTER_NODES[0]}"
    local role hostname ip nic mac
    IFS='|' read -r role hostname ip nic mac <<< "${first_master}"
    echo "${ip}"
}

# -----------------------------------------------------------------------------
# NTP_SERVERS → additionalNTPSources (비어 있으면 YAML 에 넣지 않음)
# -----------------------------------------------------------------------------
append_additional_ntp_sources() {
    local -a servers=()
    local s
    for s in "${NTP_SERVERS[@]}"; do
        [[ -z "${s// }" ]] && continue
        servers+=("${s}")
    done
    [[ ${#servers[@]} -eq 0 ]] && return 0

    printf '%s\n' "additionalNTPSources:" >> "${OUTPUT_FILE}"
    for s in "${servers[@]}"; do
        printf '  - %s\n' "${s}" >> "${OUTPUT_FILE}"
    done
}

# -----------------------------------------------------------------------------
# 출력 디렉토리 준비
# -----------------------------------------------------------------------------
prepare_output_dir() {
    local out_dir="${CLUSTER_DIR}/orig"
    mkdir -p "${out_dir}"
    OUTPUT_FILE="${out_dir}/agent-config.yaml"
    echo "[INFO] 출력 경로: ${OUTPUT_FILE}"
}

# -----------------------------------------------------------------------------
# 단일 노드의 hosts 엔트리 생성
# -----------------------------------------------------------------------------
write_host_entry() {
    local role="$1"
    local hostname="$2"
    local ip="$3"
    local nic="$4"
    local mac="$5"
    local prefix_length="$6"

    cat >> "${OUTPUT_FILE}" <<EOF
- hostname: ${hostname}
  role: ${role}
  interfaces:
  - name: ${nic}
    macAddress: ${mac}
  networkConfig:
    interfaces:
    - name: ${nic}
      type: ethernet
      state: up
      mac-address: ${mac}
      ipv4:
        enabled: true
        address:
        - ip: ${ip}
          prefix-length: ${prefix_length}
        dhcp: false
    dns-resolver:
      config:
        server:
EOF

    for dns in "${DNS_SERVERS[@]}"; do
        printf '        - %s\n' "${dns}" >> "${OUTPUT_FILE}"
    done

    cat >> "${OUTPUT_FILE}" <<EOF
    routes:
      config:
      - destination: 0.0.0.0/0
        next-hop-address: ${GATEWAY}
        next-hop-interface: ${nic}
        table-id: 254
EOF
}

# -----------------------------------------------------------------------------
# agent-config.yaml 생성
# -----------------------------------------------------------------------------
generate_agent_config() {
    local prefix_length
    prefix_length=$(get_prefix_length)
    local rendezvous_ip
    rendezvous_ip=$(get_rendezvous_ip)

    # 헤더
    cat > "${OUTPUT_FILE}" <<EOF
apiVersion: v1alpha1
kind: AgentConfig
metadata:
  name: ${CLUSTER_NAME}
rendezvousIP: ${rendezvous_ip}
EOF

    append_additional_ntp_sources

    printf '%s\n' "hosts:" >> "${OUTPUT_FILE}"

    # master 노드
    for entry in "${MASTER_NODES[@]}"; do
        local role hostname ip nic mac
        IFS='|' read -r role hostname ip nic mac <<< "${entry}"
        write_host_entry "${role}" "${hostname}" "${ip}" "${nic}" "${mac}" "${prefix_length}"
    done

    # worker 노드
    for entry in "${WORKER_NODES[@]}"; do
        local role hostname ip nic mac
        IFS='|' read -r role hostname ip nic mac <<< "${entry}"
        write_host_entry "${role}" "${hostname}" "${ip}" "${nic}" "${mac}" "${prefix_length}"
    done
}

# -----------------------------------------------------------------------------
# 노드 정보 요약 출력
# -----------------------------------------------------------------------------
print_summary() {
    local rendezvous_ip
    rendezvous_ip=$(get_rendezvous_ip)
    local prefix_length
    prefix_length=$(get_prefix_length)

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
    echo " rendezvousIP    : ${rendezvous_ip}"
    echo " Prefix Length   : /${prefix_length}"
    echo " Gateway         : ${GATEWAY}"
    printf " DNS Servers     :"
    for dns in "${DNS_SERVERS[@]}"; do printf " %s" "${dns}"; done
    echo ""
    printf " NTP Servers     :"
    if [[ ${#NTP_SERVERS[@]} -eq 0 ]]; then
        echo " (없음 — additionalNTPSources 생략)"
    else
        local shown=false
        for s in "${NTP_SERVERS[@]}"; do
            [[ -z "${s// }" ]] && continue
            printf " %s" "${s}"
            shown=true
        done
        [[ "${shown}" == false ]] && printf " (없음 — additionalNTPSources 생략)"
        echo ""
    fi
    echo "================================================================="
}

# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------
main() {
    echo "================================================================="
    echo " OCP4 agent-config.yaml 생성 스크립트 (Agent-Based Install)"
    echo " OCP Version  : ${OCP_VERSION}"
    echo " Cluster      : ${CLUSTER_NAME}.${BASE_DOMAIN}"
    echo "================================================================="

    parse_nodes

    if [[ "${MASTER_COUNT}" -eq 0 ]]; then
        echo "[ERROR] config.env 의 NODES 배열에 master 노드가 없습니다."
        exit 1
    fi

    print_summary
    prepare_output_dir
    generate_agent_config

    echo ""
    echo "[DONE] agent-config.yaml 생성 완료: ${OUTPUT_FILE}"
    echo ""
    echo "[NEXT] 다음 단계:"
    echo "       07_create_cluster_config.sh — 클러스터 환경설정 파일 생성"
}

main "$@"
