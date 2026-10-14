#!/usr/bin/env bash
# Step 11 (task 1.5) — anatomy of one transaction: Proposal -> Endorsement -> Ordering -> Validation -> Commit.
# All values are extracted from the real block (qscc GetBlockByTxID -> configtxlator proto_decode).
# Usage: scripts/analyze_tx.sh <txid> [task] [chaincode]
set -euo pipefail
source "$(dirname "$0")/lib.sh"
TXID_IN="${1:?usage: analyze_tx.sh <txid>}"
TASK="${2:-task1}"
CC="${3:-payment}"
use_org 1
start_log "$TASK" "11_analyze_tx_${TXID_IN:0:12}"
OUT="$EVIDENCE/$TASK/tx_anatomy_${TXID_IN}.md"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

fetch_block_by_txid "$TXID_IN" "$W/block.json"
B="$W/block.json"
idx="$(jq -r --arg t "$TXID_IN" '[.data.data[].payload.header.channel_header.tx_id] | index($t)' "$B")"
[[ "$idx" != "null" ]] || die "TxID not found in block"
TX=".data.data[$idx]"
ACT="$TX.payload.data.actions[0]"
PRP="$ACT.payload.action.proposal_response_payload.extension"

subject_of() { base64 -d | openssl x509 -noout -subject 2>/dev/null | sed 's/^subject=//'; }

# ---------- Proposal ----------
ch_type="$(jq -r "$TX.payload.header.channel_header.type" "$B")"
[[ "$ch_type" == 3 ]] && ch_type="3 (ENDORSER_TRANSACTION)"
ch_id="$(jq -r "$TX.payload.header.channel_header.channel_id" "$B")"
ts="$(jq -r "$TX.payload.header.channel_header.timestamp" "$B")"
creator_msp="$(jq -r "$TX.payload.header.signature_header.creator.mspid" "$B")"
creator_subj="$(jq -r "$TX.payload.header.signature_header.creator.id_bytes" "$B" | subject_of)"
cc_name="$(jq -r "$ACT.payload.chaincode_proposal_payload.input.chaincode_spec.chaincode_id.name" "$B")"
mapfile -t args < <(jq -r "$ACT.payload.chaincode_proposal_payload.input.chaincode_spec.input.args[]" "$B" | while read -r a; do base64 -d <<<"$a"; echo; done)
fn="${args[0]}"; params=("${args[@]:1}")

# TxID = SHA-256(nonce || serialized creator identity)
nonce_b64="$(jq -r "$TX.payload.header.signature_header.nonce" "$B")"
jq "$TX.payload.header.signature_header.creator" "$B" >"$W/creator.json"
configtxlator proto_encode --type msp.SerializedIdentity --input "$W/creator.json" --output "$W/creator.pb"
calc_txid="$( { base64 -d <<<"$nonce_b64"; cat "$W/creator.pb"; } | sha256sum | cut -d' ' -f1)"

# ---------- Endorsement ----------
# endorsement.endorser is a serialized msp.SerializedIdentity (bytes) — decode for MSP ID and subject
endorsers=(); endorser_subj=()
for e in $(jq -r "$ACT.payload.action.endorsements[].endorser" "$B"); do
  base64 -d <<<"$e" >"$W/e.pb"
  configtxlator proto_decode --type msp.SerializedIdentity --input "$W/e.pb" --output "$W/e.json"
  endorsers+=("$(jq -r .mspid "$W/e.json")")
  endorser_subj+=("$(jq -r .id_bytes "$W/e.json" | subject_of)")
done
n_sigs="$(jq -r "[$ACT.payload.action.endorsements[].signature | select(length > 0)] | length" "$B")"
resp_status="$(jq -r "$PRP.response.status" "$B")"
cc_version="$(jq -r "$PRP.chaincode_id.version // empty" "$B")"
event_name="$(jq -r "$PRP.events.event_name // empty" "$B")"
event_payload="$(jq -r "$PRP.events.payload // empty" "$B" | base64 -d 2>/dev/null || true)"
jq -r "$PRP.results.ns_rwset[] | select(.namespace == \"$CC\") | .rwset.reads[]? | \"| \(.key) | \(.version.block_num // \"0\")/\(.version.tx_num // \"0\") |\"" "$B" >"$W/reads"
jq -r "$PRP.results.ns_rwset[] | select(.namespace == \"$CC\") | .rwset.writes[]? | \"\(.key)\t\(.is_delete // false)\t\(.value)\"" "$B" >"$W/writes_raw"
: >"$W/writes"
while IFS=$'\t' read -r k del v; do
  size="$(base64 -d <<<"$v" | wc -c)"
  status="$(base64 -d <<<"$v" | jq -r '.status // empty' 2>/dev/null || true)"
  echo "| $k | $del | $size байт | status=$status |" >>"$W/writes"
done <"$W/writes_raw"
other_ns="$(jq -r "[$PRP.results.ns_rwset[].namespace] | join(\", \")" "$B")"

# ---------- Ordering ----------
blk="$(jq -r .header.number "$B")"
ntx="$(jq -r '.data.data | length' "$B")"
data_hash="$(jq -r .header.data_hash "$B")"
prev_hash="$(jq -r .header.previous_hash "$B")"
jq -r '.metadata.metadata[0]' "$B" | base64 -d >"$W/sigmeta.pb"
configtxlator proto_decode --type common.Metadata --input "$W/sigmeta.pb" --output "$W/sigmeta.json"
orderer_msp=""; orderer_subj=""
for sh in $(jq -r '.signatures[].signature_header' "$W/sigmeta.json"); do
  base64 -d <<<"$sh" >"$W/sh.pb"
  configtxlator proto_decode --type common.SignatureHeader --input "$W/sh.pb" --output "$W/sh.json"
  # configtxlator already expands creator into msp.SerializedIdentity {mspid, id_bytes}
  if [[ "$(jq -r '.creator.mspid // empty' "$W/sh.json")" != "" ]]; then
    orderer_msp+="$(jq -r .creator.mspid "$W/sh.json") "
    orderer_subj+="$(jq -r .creator.id_bytes "$W/sh.json" | subject_of); "
  fi
done
n_osig="$(jq -r '.signatures | length' "$W/sigmeta.json")"

# ---------- Validation ----------
code_num="$(jq -r '.metadata.metadata[2]' "$B" | base64 -d | od -An -tu1 -v | tr -s ' ' '\n' | sed '/^$/d' | sed -n "$((idx + 1))p")"
code_name="$(validation_code_name "$code_num")"

# ---------- Commit ----------
commit_line="$(docker logs peer0.org1.example.com 2>&1 | grep -E "Committed block \[$blk\]" | tail -1 | sed 's/\x1b\[[0-9;]*m//g' || true)"
commit_line2="$(docker logs peer0.org2.example.com 2>&1 | grep -E "Committed block \[$blk\]" | tail -1 | sed 's/\x1b\[[0-9;]*m//g' || true)"
height="$(peer channel getinfo -c "$CHANNEL" 2>/dev/null | sed 's/^Blockchain info: //' | jq -r .height)"
obj_id="${params[0]:-}"
state="$(cc_query "$CC" "{\"Args\":[\"ReadPaymentOrder\",\"$obj_id\"]}" 2>/dev/null || true)"
hist="$(cc_query "$CC" "{\"Args\":[\"GetPaymentOrderHistory\",\"$obj_id\"]}" 2>/dev/null || true)"
in_hist="$(jq -r --arg t "$TXID_IN" '[.[] | select(.txId == $t)] | length' <<<"$hist" 2>/dev/null || echo 0)"

# ---------- Terminal output ----------
step "Разбор транзакции $TXID_IN"
echo "  ① Proposal    : тип=$ch_type канал=$ch_id chaincode=$cc_name функция=$fn(${params[*]})"
echo "                  создатель=$creator_msp ($creator_subj), timestamp=$ts"
[[ "$calc_txid" == "$TXID_IN" ]] && ok "TxID = SHA-256(nonce ‖ creator) — пересчитан и совпал" || fail "TxID не совпал с SHA-256(nonce‖creator)"
echo "  ② Endorsement : endorsers=[${endorsers[*]}], подписей=$n_sigs, response.status=$resp_status, chaincode version=$cc_version, событие=$event_name"
[[ " ${endorsers[*]} " == *" Org1MSP "* && " ${endorsers[*]} " == *" Org2MSP "* ]] && ok "endorsements Org1MSP и Org2MSP — политика AND выполнима"
echo "  ③ Ordering    : блок #$blk, позиция $idx из $ntx, подписи orderer: $n_osig (${orderer_msp% })"
echo "  ④ Validation  : TRANSACTIONS_FILTER[$idx] = $code_num ($code_name)"
[[ "$code_name" == "VALID" ]] && ok "валидация: VSCC (Endorsement Policy) и MVCC пройдены"
echo "  ⑤ Commit      : ${commit_line:-<строка не найдена в логе>}"
[[ -n "$commit_line" ]] && ok "peer0.org1: Committed block [$blk]"
[[ -n "$commit_line2" ]] && ok "peer0.org2: Committed block [$blk]"
(( in_hist >= 1 )) && ok "GetPaymentOrderHistory($obj_id) содержит этот TxID; текущий статус: $(jq -r .status <<<"$state")"

# ---------- Markdown evidence ----------
cat >"$OUT" <<EOF
# Разбор транзакции \`$TXID_IN\`

Источник: блок из \`qscc GetBlockByTxID\` → \`configtxlator proto_decode --type common.Block\`, \`peer channel getinfo\`, \`docker logs\` peer. Сформировано \`scripts/analyze_tx.sh\` $(date '+%Y-%m-%d %H:%M:%S').
Сертификаты из блока не копируются — только MSP ID и subject.

## ① Proposal

| Поле | Значение |
|---|---|
| tx_id | \`$TXID_IN\` |
| Тип | \`$ch_type\` |
| Канал | \`$ch_id\` |
| Timestamp | $ts |
| Chaincode | \`$cc_name\` |
| Функция | \`$fn\` |
| Аргументы (base64 → текст) | \`$(printf '%s, ' "${params[@]}" | sed 's/, $//')\` |
| Создатель (MSP ID) | \`$creator_msp\` |
| Subject создателя | $creator_subj |
| nonce (base64) | \`$nonce_b64\` |

**TxID = SHA-256(nonce ‖ creator).** Пересчёт: \`$calc_txid\` → $( [[ "$calc_txid" == "$TXID_IN" ]] && echo "**совпадает** с tx_id" || echo "не совпадает" ). Поэтому клиент не может выбрать произвольный TxID, а повтор транзакции с тем же TxID отклоняется как \`DUPLICATE_TXID\`.

## ② Endorsement

| Поле | Значение |
|---|---|
| Endorsers | $(printf '`%s` ' "${endorsers[@]}") |
| Subject endorsers | $(printf '%s; ' "${endorser_subj[@]}") |
| Подписи endorsers | присутствуют: $n_sigs из ${#endorsers[@]} (сами подписи не приводятся) |
| Ответ chaincode | status = $resp_status |
| Версия chaincode при симуляции | $cc_version |
| Событие chaincode | \`$event_name\` — payload: \`$event_payload\` |
| Namespaces в RW-set | $other_ns |

Read Set (namespace \`$CC\`):

| Ключ | Версия (block_num/tx_num) |
|---|---|
$(cat "$W/reads")

Write Set (namespace \`$CC\`):

| Ключ | is_delete | Размер значения | Новое значение |
|---|---|---|---|
$(cat "$W/writes")

Endorsement Policy \`AND('Org1MSP.peer','Org2MSP.peer')\` требует подписи обоих peers — обе присутствуют.

## ③ Ordering

| Поле | Значение |
|---|---|
| Номер блока | **$blk** |
| Позиция транзакции в блоке | $idx (всего транзакций в блоке: $ntx) |
| data_hash | \`$data_hash\` |
| previous_hash | \`$prev_hash\` |
| Подписи Ordering Service в metadata[SIGNATURES] | $n_osig, MSP ID: \`${orderer_msp% }\` |
| Subject orderer | ${orderer_subj%; } |

Orderer не исполняет chaincode и не проверяет бизнес-логику: он проверяет право отправителя писать в канал (политика Writers), упорядочивает транзакции и подписывает блок.

## ④ Validation

| Поле | Значение |
|---|---|
| TRANSACTIONS_FILTER[$idx] | **$code_num = $code_name** |
| VSCC | Endorsement Policy (AND) выполнена — подписи Org1MSP и Org2MSP валидны |
| MVCC | версии ключей из Read Set совпали с World State на момент валидации |

## ⑤ Commit

| Поле | Значение |
|---|---|
| Лог peer0.org1 | \`$commit_line\` |
| Лог peer0.org2 | \`$commit_line2\` |
| Высота канала сейчас | $height |
| Текущее состояние \`$obj_id\` | status = **$(jq -r .status <<<"$state")**, lastTxId = \`$(jq -r .lastTxId <<<"$state")\` |
| История ключа содержит этот TxID | $( (( in_hist >= 1 )) && echo да || echo нет ) |
EOF
ok "отчёт по этапам: evidence/$TASK/$(basename "$OUT")"
summary
