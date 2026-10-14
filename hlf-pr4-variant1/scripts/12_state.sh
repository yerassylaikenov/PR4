#!/usr/bin/env bash
# Step 12 (task 1.6) — current state of business objects after the transactions.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
use_org 1
start_log task1 12_state
CSV="$EVIDENCE/task1/txids.csv"

step "ReadPaymentOrder — текущее состояние объектов (World State)"
declare -A expected=([PO-0001]=SETTLED [PO-0002]=CANCELLED [PO-0003]=CREATED [PO-0005]="SUBMITTED|CANCELLED")
rows=()
for id in PO-0001 PO-0002 PO-0003 PO-0005; do
  printf '%s$ peer chaincode query -C %s -n payment -c {"Args":["ReadPaymentOrder","%s"]}%s\n' "$C_D" "$CHANNEL" "$id" "$C_0"
  js="$(cc_query payment "{\"Args\":[\"ReadPaymentOrder\",\"$id\"]}" 2>/dev/null)"
  jq -C . <<<"$js" | sed 's/^/  /'
  actual="$(jq -r .status <<<"$js")"
  if [[ "$actual" =~ ^(${expected[$id]})$ ]]; then ok "$id: ожидается ${expected[$id]}, фактически $actual"; else fail "$id: ожидается ${expected[$id]}, фактически $actual"; fi
  rows+=("| $id | ${expected[$id]} | $actual | $(jq -r .amount <<<"$js") $(jq -r .currency <<<"$js") | \`$(jq -r .lastTxId <<<"$js")\` | $( [[ "$actual" =~ ^(${expected[$id]})$ ]] && echo ✅ || echo ❌) |")
done

step "GetAllPaymentOrders — пагинация (pageSize = 2)"
bm=""; page=1; total=0
while :; do
  res="$(cc_query payment "{\"Args\":[\"GetAllPaymentOrders\",\"2\",\"$bm\"]}" 2>/dev/null)"
  n="$(jq '.records | length' <<<"$res")"; total=$((total + n))
  echo "  страница $page: $(jq -r '[.records[] | "\(.id)=\(.status)"] | join(", ")' <<<"$res")  (fetched=$(jq .fetchedRecordsCount <<<"$res"), bookmark=\"$(jq -r .bookmark <<<"$res")\")"
  bm="$(jq -r .bookmark <<<"$res")"
  [[ -z "$bm" || "$n" == 0 ]] && break
  page=$((page + 1))
done
ok "всего объектов PaymentOrder: $total, страниц: $page"
check "pageSize=51 отклоняется (OWASP SC10)" bash -c "! peer chaincode query -C $CHANNEL -n payment -c '{\"Args\":[\"GetAllPaymentOrders\",\"51\",\"\"]}' 2>&1 | grep -q records"

step "GetPaymentOrderHistory(PO-0001) — все версии ключа"
hist="$(cc_query payment '{"Args":["GetPaymentOrderHistory","PO-0001"]}' 2>/dev/null)"
jq -r '.[] | "  \(.timestamp)  \(.txId)  status=\(.value.status)"' <<<"$hist"
for n in T1 T2 T3 T4; do
  t="$(csv_field "$CSV" "$n" txid)"
  jq -e --arg t "$t" 'any(.[]; .txId == $t)' <<<"$hist" >/dev/null && ok "$n ($t) присутствует в истории PO-0001" || fail "$n отсутствует в истории"
done

step "CouchDB peer0.org1 (couchdb0:5984) — документ PO-0001 в базе paymentchannel_payment"
# credentials are taken from the compose file into variables and never printed
COUCH_USER="$(grep -m1 'COUCHDB_USER=' "$TEST_NETWORK/compose/compose-couch.yaml" | sed 's/.*COUCHDB_USER=//' | tr -d ' "')"
COUCH_PASS="$(grep -m1 'COUCHDB_PASSWORD=' "$TEST_NETWORK/compose/compose-couch.yaml" | sed 's/.*COUCHDB_PASSWORD=//' | tr -d ' "')"
printf '%s$ curl -s -u "$COUCH_USER:$COUCH_PASS" http://localhost:5984/_all_dbs%s\n' "$C_D" "$C_0"
curl -s -u "$COUCH_USER:$COUCH_PASS" http://localhost:5984/_all_dbs | jq -c . | sed 's/^/  /'
printf '%s$ curl -s -u "$COUCH_USER:$COUCH_PASS" http://localhost:5984/paymentchannel_payment/PO-0001%s\n' "$C_D" "$C_0"
doc="$(curl -s -u "$COUCH_USER:$COUCH_PASS" http://localhost:5984/paymentchannel_payment/PO-0001)"
jq -C . <<<"$doc" | sed 's/^/  /'
ver="$(jq -r '."~version"' <<<"$doc")"
[[ "$ver" != "null" ]] && ok "поле ~version = $ver (версия ключа для MVCC: блок:транзакция в формате Fabric)" || fail "~version не найден"
[[ "$(jq -r .status <<<"$doc")" == "SETTLED" ]] && ok "CouchDB (World State) хранит PO-0001 со статусом SETTLED"
unset COUCH_USER COUCH_PASS

step "Сравнение «ожидаемый / фактический статус»"
{
  echo "| Объект | Ожидаемый статус | Фактический статус | Сумма | lastTxId | Совпадение |"
  echo "|---|---|---|---|---|---|"
  printf '%s\n' "${rows[@]}"
} | tee "$EVIDENCE/task1/state_table.md"
summary
