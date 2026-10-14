#!/usr/bin/env bash
# Task 3.1 — baseline before the upgrade: definition (1.0 / 1), Package ID, state of the business objects.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
use_org 1
OUT="$EVIDENCE/task3/30_pre_upgrade"; mkdir -p "$OUT"
start_log task3 30_pre_upgrade_snapshot

step "querycommitted payment — до обновления"
qc="$(peer lifecycle chaincode querycommitted --channelID "$CHANNEL" --name payment --output json 2>/dev/null)"
echo "$qc" | tee "$OUT/querycommitted_v1.json"
[[ "$(jq -r .version <<<"$qc")" == 1.0 && "$(jq -r .sequence <<<"$qc")" == 1 ]] && ok "payment: Version 1.0, Sequence 1" || die "ожидалось 1.0 / 1 — остановка"
[[ "$(jq -r '.approvals.Org1MSP and .approvals.Org2MSP' <<<"$qc")" == true ]] && ok "approvals Org1MSP, Org2MSP"
[[ "$(jq -r .validation_parameter <<<"$qc")" == "CiwSDBIKCAISAggAEgIIARoNEgsKB09yZzFNU1AQAxoNEgsKB09yZzJNU1AQAw==" ]] && ok "политика AND('Org1MSP.peer','Org2MSP.peer') (validation_parameter)"

step "queryinstalled на обоих peers"
for org in 1 2; do
  use_org "$org"
  peer lifecycle chaincode queryinstalled --output json 2>/dev/null | tee "$OUT/queryinstalled_org$org.json" \
    | jq -r '.installed_chaincodes[] | "  peer0.org'"$org"': \(.package_id)  label=\(.label)  references=\([.references | keys[]] | join(","))"'
  pid="$(jq -r '.installed_chaincodes[] | select(.label=="payment_1.0") | .package_id' "$OUT/queryinstalled_org$org.json")"
  ok "peer0.org$org: Package ID payment 1.0 = $pid"
done
use_org 1

step "Состояние бизнес-объектов (ReadPaymentOrder)"
for id in PO-0001 PO-0002 PO-0003; do
  js="$(cc_query payment "{\"Args\":[\"ReadPaymentOrder\",\"$id\"]}" 2>/dev/null)"
  echo "$js" | jq -S . >"$OUT/$id.json"
  echo "  $id: status=$(jq -r .status <<<"$js") amount=$(jq -r .amount <<<"$js") $(jq -r .currency <<<"$js") lastTxId=$(jq -r .lastTxId <<<"$js")"
done
[[ "$(jq -r .status "$OUT/PO-0001.json")" == SETTLED ]] && ok "PO-0001 SETTLED"
[[ "$(jq -r .status "$OUT/PO-0002.json")" == CANCELLED ]] && ok "PO-0002 CANCELLED"
[[ "$(jq -r .status "$OUT/PO-0003.json")" == CREATED ]] && ok "PO-0003 CREATED"

step "GetAllPaymentOrders (все страницы) → state_v1.json (jq -S) + sha256"
bm=""; all="[]"
while :; do
  res="$(cc_query payment "{\"Args\":[\"GetAllPaymentOrders\",\"50\",\"$bm\"]}" 2>/dev/null)"
  all="$(jq -s '.[0] + .[1].records' <(echo "$all") <(echo "$res"))"
  n="$(jq '.records | length' <<<"$res")"; bm="$(jq -r .bookmark <<<"$res")"
  (( n < 50 )) && break
done
jq -S . <<<"$all" >"$OUT/state_v1.json"
(cd "$OUT" && sha256sum state_v1.json | tee state_v1.json.sha256)
ok "state_v1.json: $(jq length "$OUT/state_v1.json") объектов"

step "История PO-0001 и высота канала"
cc_query payment '{"Args":["GetPaymentOrderHistory","PO-0001"]}' 2>/dev/null | jq . >"$OUT/history_PO-0001.json"
jq -r '.[] | "  \(.txId)  → \(.value.status)"' "$OUT/history_PO-0001.json"
peer channel getinfo -c "$CHANNEL" 2>/dev/null | tee "$OUT/getinfo.txt"
ok "высота до обновления: $(sed 's/^Blockchain info: //' "$OUT/getinfo.txt" | jq .height)"

step "Контейнеры chaincode 1.0"
docker ps --filter name=dev-peer --format 'table {{.Names}}\t{{.Status}}' | tee "$OUT/docker_ps_devpeer.txt"

step "Golden-фикстуры для unit-тестов совместимости v2.0"
mkdir -p "$ROOT/chaincode/payment-v2/chaincode/testdata"
cc_query payment '{"Args":["ReadPaymentOrder","PO-0001"]}' 2>/dev/null >"$ROOT/chaincode/payment-v2/chaincode/testdata/v1_PO-0001.json"
cc_query payment '{"Args":["ReadPaymentOrder","PO-0003"]}' 2>/dev/null >"$ROOT/chaincode/payment-v2/chaincode/testdata/v1_PO-0003.json"
ok "реальный JSON PO-0001 и PO-0003 (как его вернул payment 1.0) сохранён в chaincode/payment-v2/chaincode/testdata/"
summary
