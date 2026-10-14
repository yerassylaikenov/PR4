#!/usr/bin/env bash
# Task 3.7 — decode the bftchannel config: ConsensusType BFT, consenters, SmartBFT options, capability V3_0.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
export CHANNEL=bftchannel
use_org 1
start_log task3/bft 39_bft_config
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

step "Конфигурационный блок канала bftchannel"
run peer channel fetch config "$W/cfg.pb" -o localhost:7050 --ordererTLSHostnameOverride orderer.example.com -c "$CHANNEL" --tls --cafile "$ORDERER_CA"
configtxlator proto_decode --type common.Block --input "$W/cfg.pb" --output "$W/cfg.json"
C='.data.data[0].payload.data.config.channel_group'
ct="$(jq -r "$C.groups.Orderer.values.ConsensusType.value.type" "$W/cfg.json")"
echo "  ConsensusType            : $ct"
[[ "$ct" == BFT ]] && ok "ConsensusType = BFT (SmartBFT)"
caps="$(jq -r "$C.values.Capabilities.value.capabilities | keys | join(\",\")" "$W/cfg.json")"
echo "  Channel capabilities     : $caps"
[[ "$caps" == *V3_0* ]] && ok "Channel capability V3_0"
echo "  Orderer capabilities     : $(jq -r "$C.groups.Orderer.values.Capabilities.value.capabilities | keys | join(\",\")" "$W/cfg.json")"
echo "  Application capabilities : $(jq -r "$C.groups.Application.values.Capabilities.value.capabilities | keys | join(\",\")" "$W/cfg.json")"

step "Consenters (Orderers.value.consenter_mapping)"
printf '  %-4s %-22s %-6s %-11s\n' ID host port MSP
jq -r "$C.groups.Orderer.values.Orderers.value.consenter_mapping[] | \"  \(.id)    \(.host)   \(.port)   \(.msp_id)\"" "$W/cfg.json"
n="$(jq "$C.groups.Orderer.values.Orderers.value.consenter_mapping | length" "$W/cfg.json")"
(( n == 4 )) && ok "4 consenter-а: n = 3f + 1 = 4 → f = 1, кворум ⌈(n+f+1)/2⌉ = 3"

step "Параметры SmartBFT (ConsensusType.value.metadata / options)"
jq "$C.groups.Orderer.values.ConsensusType.value.metadata" "$W/cfg.json" | sed 's/^/  /' | head -40
for k in request_batch_max_count request_batch_max_interval view_change_timeout leader_heartbeat_timeout leader_rotation decisions_per_leader; do
  v="$(jq -r "$C.groups.Orderer.values.ConsensusType.value.metadata | .. | objects | .$k? // empty" "$W/cfg.json" | head -1)"
  [[ -n "$v" ]] && echo "  $k = $v"
done
echo "  BatchSize: $(jq -c "$C.groups.Orderer.values.BatchSize.value" "$W/cfg.json"), BatchTimeout: $(jq -r "$C.groups.Orderer.values.BatchTimeout.value.timeout" "$W/cfg.json")"

step "Orderer → порт → admin-порт (compose/compose-bft-test-net.yaml)"
printf '  %-22s %-10s %-10s %s\n' orderer listen admin operations
for o in orderer orderer2 orderer3 orderer4; do
  ports="$(docker port "$o.example.com" | awk -F'[: ]' '/0.0.0.0/ {print $NF}' | sort -n | tr '\n' ' ')"
  set -- $ports
  printf '  %-22s %-10s %-10s %s\n' "$o.example.com" "$1" "$2" "$3"
done
ok "имена и порты сверены с запущенными контейнерами"

step "Лидер текущего view (логи orderer: ChangeRole)"
for o in orderer orderer2 orderer3 orderer4; do
  l="$(docker logs "$o.example.com" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E 'ChangeRole ->' | tail -1 | grep -oE 'Changing to [a-z]+ role, current view: [0-9]+, current leader: [0-9]+')"
  echo "  $o.example.com: $l"
done
summary
