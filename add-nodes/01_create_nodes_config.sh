#!/usr/bin/env bash
# =============================================================================
# 01_create_nodes_config.sh - 노드 추가용 nodes-config.yaml 생성
# =============================================================================
# config.env 의 ADD_NODES 배열을 파싱하여 각 노드의 NMState 네트워크 설정을
# 포함한 nodes-config.yaml 을 생성합니다.
#
# 참조:
#   config.env        - ADD_NODES, MACHINE_NETWORK, GATEWAY, DNS_SERVERS
#
# 출력 파일: ${CLUSTER_DIR}/orig/nodes-config.yaml
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
# 노드 파싱
# 형식: "role|hostname|ip|nic|mac"
# -----------------------------------------------------------------------------
parse_nodes() {
    NODE_COUNT=0
    PARSED_NODES=()

    for entry in "${ADD_NODES[@]}"; do
        local role hostname ip nic mac
        IFS='|' read -r role hostname ip nic mac <<< "${entry}"

        if [[ "${role}" != "master" && "${role}" != "worker" ]]; then
            echo "[WARN] 알 수 없는 노드 role: '${role}' (항목: ${entry}) — 건너뜁니다."
            continue
        fi

        NODE_COUNT=$(( NODE_COUNT + 1 ))
        PARSED_NODES+=("${entry}")
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
# 출력 디렉토리 준비
# -----------------------------------------------------------------------------
prepare_output_dir() {
    local out_dir="${CLUSTER_DIR}/orig"
    mkdir -p "${out_dir}"
    OUTPUT_FILE="${out_dir}/nodes-config.yaml"
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
# nodes-config.yaml 생성
# -----------------------------------------------------------------------------
generate_nodes_config() {
    local prefix_length
    prefix_length=$(get_prefix_length)

    # 헤더
    cat > "${OUTPUT_FILE}" <<EOF
apiVersion: v1alpha1
kind: NodeConfig
metadata:
  name: ${CLUSTER_NAME}
hosts:
EOF

    for entry in "${PARSED_NODES[@]}"; do
        local role hostname ip nic mac
        IFS='|' read -r role hostname ip nic mac <<< "${entry}"
        write_host_entry "${role}" "${hostname}" "${ip}" "${nic}" "${mac}" "${prefix_length}"
    done
}

# -----------------------------------------------------------------------------
# 노드 정보 요약 출력
# -----------------------------------------------------------------------------
print_summary() {
    local prefix_length
    prefix_length=$(get_prefix_length)

    echo ""
    echo "================================================================="
    echo " 추가 노드 구성 요약"
    echo "================================================================="
    printf "%-10s %-12s %-18s %-10s %s\n" "ROLE" "HOSTNAME" "IP" "NIC" "MAC"
    printf '%s\n' "-------------------------------------------------------------------"

    for entry in "${PARSED_NODES[@]}"; do
        IFS='|' read -r role hostname ip nic mac <<< "${entry}"
        printf "%-10s %-12s %-18s %-10s %s\n" "${role}" "${hostname}" "${ip}" "${nic}" "${mac}"
    done

    echo ""
    echo " Prefix Length   : /${prefix_length}"
    echo " Gateway         : ${GATEWAY}"
    printf " DNS Servers     :"
    for dns in "${DNS_SERVERS[@]}"; do printf " %s" "${dns}"; done
    echo ""
    echo "================================================================="
}

# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------
main() {
    echo "================================================================="
    echo " OCP4 nodes-config.yaml 생성 (노드 추가용)"
    echo " OCP Version  : ${OCP_VERSION}"
    echo " Cluster      : ${CLUSTER_NAME}.${BASE_DOMAIN}"
    echo "================================================================="

    parse_nodes

    if [[ "${NODE_COUNT}" -eq 0 ]]; then
        echo "[ERROR] config.env 의 ADD_NODES 배열에 노드가 없습니다."
        exit 1
    fi

    print_summary
    prepare_output_dir
    generate_nodes_config

    echo ""
    echo "[DONE] nodes-config.yaml 생성 완료: ${OUTPUT_FILE}"
}

main "$@"
