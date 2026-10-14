#!/usr/bin/env bash
# Step 13 (task 1.7) — ledger exploration: height, newest block, hash-chain verification, genesis block.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
use_org 1
TASK="${TASK:-task1}"
start_log "$TASK" 13_ledger_info
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
OF=(-o "$ORDERER_ADDR" --ordererTLSHostnameOverride "$ORDERER_HOST" --tls --cafile "$ORDERER_CA")

step "Высота Blockchain канала $CHANNEL"
run peer channel getinfo -c "$CHANNEL"
info_json="$(peer channel getinfo -c "$CHANNEL" 2>/dev/null | sed 's/^Blockchain info: //')"
H="$(jq -r .height <<<"$info_json")"; CUR="$(jq -r .currentBlockHash <<<"$info_json")"; PREV="$(jq -r .previousBlockHash <<<"$info_json")"
ok "высота = $H (блоки 0..$((H - 1)))"
echo "  currentBlockHash  = $CUR"
echo "  previousBlockHash = $PREV"

step "Последний блок (peer channel fetch newest)"
run peer channel fetch newest "$W/newest.pb" -c "$CHANNEL" "${OF[@]}"
configtxlator proto_decode --type common.Block --input "$W/newest.pb" --output "$W/newest.json"
N="$(jq -r .header.number "$W/newest.json")"
echo "  number        = $N"
echo "  data_hash     = $(jq -r .header.data_hash "$W/newest.json")"
echo "  previous_hash = $(jq -r .header.previous_hash "$W/newest.json")"
echo "  транзакций    = $(jq '.data.data | length' "$W/newest.json")"
# Validation codes exist only in the peer's committed copy (the orderer does not validate transactions).
fetch_block_by_number "$N" "$W/newest_peer.json"
echo "  TRANSACTIONS_FILTER в копии orderer   : \"$(jq -r '.metadata.metadata[2]' "$W/newest.json")\" (пусто — orderer не валидирует)"
echo "  TRANSACTIONS_FILTER в ledger peer0.org1: \"$(jq -r '.metadata.metadata[2]' "$W/newest_peer.json")\" (qscc GetBlockByNumber)"
[[ "$(jq -c .header "$W/newest.json")" == "$(jq -c .header "$W/newest_peer.json")" ]] && ok "заголовки копий orderer и peer идентичны"
mapfile -t codes < <(block_codes "$W/newest_peer.json")
i=0
while read -r tx typ; do
  echo "  tx[$i] $tx  type=$typ  validation=$(validation_code_name "${codes[$i]}")"
  i=$((i + 1))
done < <(jq -r '.data.data[].payload.header.channel_header | "\(.tx_id) \(.type)"' "$W/newest.json")
jq '{header: .header, tx: [.data.data[] | {tx_id: .payload.header.channel_header.tx_id, type: .payload.header.channel_header.type, creator: .payload.header.signature_header.creator.mspid, chaincode: .payload.data.actions[0].payload.chaincode_proposal_payload.input.chaincode_spec.chaincode_id.name}]}' \
  "$W/newest.json" >"$EVIDENCE/$TASK/13_newest_block_decoded_fragment.json"
[[ "$N" == "$((H - 1))" ]] && ok "номер последнего блока = высота − 1 = $N"

step "Проверка связности хэш-цепочки"
[[ "$(jq -r .header.previous_hash "$W/newest.json")" == "$PREV" ]] \
  && ok "previous_hash блока #$N совпадает с previousBlockHash из getinfo" || fail "previous_hash ≠ previousBlockHash"
calc_cur="$(python3 "$ROOT/scripts/blockhash.py" "$W/newest.json")"
echo "  SHA-256(ASN.1(header #$N))     = $calc_cur"
[[ "$calc_cur" == "$CUR" ]] && ok "хэш заголовка блока #$N, пересчитанный локально, = currentBlockHash" || fail "currentBlockHash mismatch"
run peer channel fetch "$((N - 1))" "$W/prev.pb" -c "$CHANNEL" "${OF[@]}"
configtxlator proto_decode --type common.Block --input "$W/prev.pb" --output "$W/prev.json"
calc_prev="$(python3 "$ROOT/scripts/blockhash.py" "$W/prev.json")"
echo "  SHA-256(ASN.1(header #$((N - 1)))) = $calc_prev"
echo "  previous_hash в блоке #$N    = $(jq -r .header.previous_hash "$W/newest.json")"
[[ "$calc_prev" == "$(jq -r .header.previous_hash "$W/newest.json")" ]] \
  && ok "блок #$((N - 1)) → блок #$N: хэш заголовка N−1 записан в previous_hash блока N" || fail "цепочка N-1 → N разорвана"

# full chain walk 0..N
broken=0; prevh=""
for ((b = 0; b <= N; b++)); do
  peer channel fetch "$b" "$W/b.pb" -c "$CHANNEL" "${OF[@]}" >/dev/null 2>&1
  configtxlator proto_decode --type common.Block --input "$W/b.pb" --output "$W/b.json"
  if (( b > 0 )) && [[ "$(jq -r '.header.previous_hash' "$W/b.json")" != "$prevh" ]]; then broken=$((broken + 1)); fi
  prevh="$(python3 "$ROOT/scripts/blockhash.py" "$W/b.json")"
done
(( broken == 0 )) && ok "вся цепочка 0..$N проверена: $((N + 1)) блоков, разрывов нет" || fail "разрывов: $broken"

step "Блок 0 (genesis / конфигурационный блок канала)"
run peer channel fetch oldest "$W/genesis.pb" -c "$CHANNEL" "${OF[@]}"
configtxlator proto_decode --type common.Block --input "$W/genesis.pb" --output "$W/genesis.json"
G='.data.data[0].payload.data.config.channel_group'
echo "  тип транзакции        : $(jq -r '.data.data[0].payload.header.channel_header.type' "$W/genesis.json")"
echo "  организации Application: $(jq -r "$G.groups.Application.groups | keys | join(\", \")" "$W/genesis.json")"
echo "  организации Orderer    : $(jq -r "$G.groups.Orderer.groups | keys | join(\", \")" "$W/genesis.json")"
echo "  MSP Org1MSP — корневых CA: $(jq -r "$G.groups.Application.groups.Org1MSP.values.MSP.value.config.root_certs | length" "$W/genesis.json"), NodeOUs: $(jq -r "$G.groups.Application.groups.Org1MSP.values.MSP.value.config.fabric_node_ous.enable" "$W/genesis.json")"
echo "  политики канала        : $(jq -r "$G.policies | keys | join(\", \")" "$W/genesis.json")"
echo "  политики Application   : $(jq -r "$G.groups.Application.policies | to_entries | map(\"\(.key)=\(.value.policy.value.rule // .value.policy.type)\") | join(\", \")" "$W/genesis.json")"
echo "  LifecycleEndorsement   : $(jq -r "$G.groups.Application.policies.LifecycleEndorsement.policy.value | \"\(.rule) \(.sub_policy)\"" "$W/genesis.json")"
echo "  Channel capabilities   : $(jq -r "$G.values.Capabilities.value.capabilities | keys | join(\", \")" "$W/genesis.json")"
echo "  Application capabilities: $(jq -r "$G.groups.Application.values.Capabilities.value.capabilities | keys | join(\", \")" "$W/genesis.json")"
echo "  Orderer capabilities   : $(jq -r "$G.groups.Orderer.values.Capabilities.value.capabilities | keys | join(\", \")" "$W/genesis.json")"
echo "  ConsensusType          : $(jq -r "$G.groups.Orderer.values.ConsensusType.value.type" "$W/genesis.json")"
echo "  BatchSize / Timeout    : max_message_count=$(jq -r "$G.groups.Orderer.values.BatchSize.value.max_message_count" "$W/genesis.json"), timeout=$(jq -r "$G.groups.Orderer.values.BatchTimeout.value.timeout" "$W/genesis.json")"
ok "блок 0 = конфигурация канала (CONFIG), бизнес-транзакций не содержит"

if [[ -f "$EVIDENCE/task1/txids.csv" ]] && grep -q MVCC_READ_CONFLICT "$EVIDENCE/task1/txids.csv"; then
  step "Blockchain vs World State — на примере MVCC-демо"
  row="$(grep MVCC_READ_CONFLICT "$EVIDENCE/task1/txids.csv" | head -1)"
  bad_tx="$(cut -d, -f5 <<<"$row")"; bad_blk="$(cut -d, -f6 <<<"$row")"; bad_fn="$(cut -d, -f2 <<<"$row")"
  peer channel fetch "$bad_blk" "$W/m.pb" -c "$CHANNEL" "${OF[@]}" >/dev/null 2>&1
  configtxlator proto_decode --type common.Block --input "$W/m.pb" --output "$W/m.json"
  jq -e --arg t "$bad_tx" 'any(.data.data[]; .payload.header.channel_header.tx_id == $t)' "$W/m.json" >/dev/null \
    && ok "невалидная транзакция $bad_fn ($bad_tx) лежит в блоке #$bad_blk (Blockchain хранит всё)"
  st="$(cc_query payment '{"Args":["ReadPaymentOrder","PO-0005"]}' 2>/dev/null | jq -r '"\(.status) lastTxId=\(.lastTxId)"')"
  [[ "$st" != *"$bad_tx"* ]] && ok "World State PO-0005: $st — write-set невалидной транзакции не применён"
fi
summary
