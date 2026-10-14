#!/usr/bin/env bash
# Task 3.6 (part 1) — backward compatibility of payment 2.0 with the world state written by 1.0 (C1–C9).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
use_org 1
SNAP="$EVIDENCE/task3/30_pre_upgrade"
CSV="$EVIDENCE/task3/txids.csv"
TAB="$EVIDENCE/task3/compat_table.md"
if [[ -f "$TAB" ]] && cc_query payment '{"Args":["PaymentOrderExists","PO-0006"]}' 2>/dev/null | grep -q true; then
  info "проверки уже выполнены — см. evidence/task3/36_compat.log и compat_table.md"; cat "$TAB"; exit 0
fi
start_log task3 36_compat
rm -f "$CSV"
ROWS=()
row() { ROWS+=("| $1 | $2 | $3 | $4 | $5 | **$6** |"); }
inv() { # <n> <org> <json>
  use_org "$2"
  cc_invoke payment "$3" || true
  record_tx "$CSV" "$1" "$(jq -r .function <<<"$3")" "$(jq -c .Args <<<"$3")"
}
ver() { cc_query payment "{\"Args\":[\"ReadPaymentOrder\",\"$1\"]}" 2>/dev/null; }

step "Определение: $(peer lifecycle chaincode querycommitted -C "$CHANNEL" -n payment --output json 2>/dev/null | jq -r '"version \(.version), sequence \(.sequence)"')"

step "C1 — ReadPaymentOrder(PO-0001), созданного и исполненного v1.0"
now="$(ver PO-0001)"; echo "$now" | jq -c . | sed 's/^/  /'
if diff <(jq -S . <<<"$now") "$SNAP/PO-0001.json" >/dev/null; then
  ok "C1: JSON идентичен снимку v1 (diff пуст); schemaVersion отсутствует → трактуется как 1"
  row C1 "ReadPaymentOrder(PO-0001) через v2.0" "идентично снимку v1" "diff пуст, \`schemaVersion\` отсутствует" - PASS
else fail "C1"; row C1 "ReadPaymentOrder(PO-0001)" "идентично" "различается" - FAIL; fi

step "C2 — GetAllPaymentOrders → state_after.json; сравнение со state_v1.json до первой записи через v2.0"
all="$(cc_query payment '{"Args":["GetAllPaymentOrders","50",""]}' 2>/dev/null | jq '.records')"
jq -S . <<<"$all" >"$EVIDENCE/task3/state_after.json"
h1="$(cut -d' ' -f1 "$SNAP/state_v1.json.sha256")"; h2="$(sha256sum "$EVIDENCE/task3/state_after.json" | cut -d' ' -f1)"
echo "  sha256 state_v1.json    = $h1"
echo "  sha256 state_after.json = $h2"
if [[ "$h1" == "$h2" ]] && diff "$SNAP/state_v1.json" "$EVIDENCE/task3/state_after.json" >/dev/null; then
  ok "C2: World State после смены пакета идентичен (sha256 и diff совпадают)"
  row C2 "GetAllPaymentOrders → state_after.json" "sha256 = state_v1" "\`${h2:0:16}…\` = \`${h1:0:16}…\`" - PASS
else fail "C2"; row C2 "state_after vs state_v1" "идентичны" "различаются" - FAIL; fi

step "C3 — старые операции v1.0 над PO-0003 (создан v1.0): Submit → Accept → Settle"
inv C3a 1 '{"function":"SubmitPaymentOrder","Args":["PO-0003"]}'; show_tx "Submit PO-0003"; t1="$TXID"
inv C3b 2 '{"function":"AcceptPaymentOrder","Args":["PO-0003"]}'; show_tx "Accept PO-0003"; t2="$TXID"
inv C3c 2 '{"function":"SettlePaymentOrder","Args":["PO-0003"]}'; show_tx "Settle PO-0003"; t3="$TXID"
po3="$(ver PO-0003)"
if [[ "$(jq -r .status <<<"$po3")" == SETTLED && "$(jq -r .schemaVersion <<<"$po3")" == 2 ]]; then
  ok "C3: PO-0003 SETTLED, после первой записи через v2.0 получил schemaVersion: 2 (ленивая миграция)"
  row C3 "Submit → Accept → Settle PO-0003 (объект v1.0)" "VALID, затем schemaVersion 2" "VALID ×3, schemaVersion=2" "\`${t1:0:12}…\` \`${t2:0:12}…\` \`${t3:0:12}…\`" PASS
else fail "C3"; row C3 "старая операция" "VALID" "$(jq -r .status <<<"$po3")" - FAIL; fi

step "C4 — новая функция v2.0: ReturnPaymentOrder(PO-0001)"
inv C4 2 '{"function":"ReturnPaymentOrder","Args":["PO-0001","ACCOUNT_CLOSED"]}'; show_tx "Return PO-0001"; t4="$TXID"
po1="$(ver PO-0001)"; echo "  $(jq -c '{status, returnReason, returnedAt, schemaVersion, amount}' <<<"$po1")"
[[ "$(jq -r .status <<<"$po1")" == RETURNED ]] && { ok "C4: PO-0001 RETURNED"; row C4 "ReturnPaymentOrder(PO-0001)" "VALID, RETURNED" "VALID, RETURNED, returnReason=ACCOUNT_CLOSED" "\`${t4:0:16}…\`" PASS; } \
  || { fail C4; row C4 "Return" "VALID" "$TX_STATUS" - FAIL; }

step "C5 — повторный Return PO-0001"
use_org 2; cc_invoke payment '{"function":"ReturnPaymentOrder","Args":["PO-0001","ACCOUNT_CLOSED"]}' || true
expect_reject "C5 повторный Return" ERR_INVALID_TRANSITION
row C5 "повторный Return PO-0001" "отказ" "$(grep -oE 'ERR_[A-Z_]+: [^"]{0,60}' <<<"$TX_OUT" | head -1)" - "$(grep -q ERR_INVALID_TRANSITION <<<"$TX_OUT" && echo PASS || echo FAIL)"

step "C6 — GetPaymentOrdersByStatus(SETTLED) — rich query по индексу indexStatus"
use_org 1
r="$(cc_query payment '{"Args":["GetPaymentOrdersByStatus","SETTLED","10",""]}' 2>/dev/null)"
echo "  найдено: $(jq -r '[.records[].id] | join(", ")' <<<"$r")"
jq -e '.records[] | select(.id=="PO-0003")' <<<"$r" >/dev/null && { ok "C6: найден PO-0003 (объект v1.0, исполненный через v2.0)"; row C6 "GetPaymentOrdersByStatus(SETTLED)" "находит PO-0003" "$(jq -r '[.records[].id] | join(", ")' <<<"$r")" - PASS; } \
  || { fail C6; row C6 "ByStatus" "PO-0003" "не найден" - FAIL; }
inj="$(cc_query payment '{"Args":["GetPaymentOrdersByStatus","{\"$gt\":null}","10",""]}' 2>&1 || true)"
grep -q ERR_VALIDATION <<<"$inj" && ok "попытка инъекции в селектор отклонена: ERR_VALIDATION (SC04)"

step "C7 — новый PO-0006 через v2.0, полный цикл (+ SetValueDate)"
inv C7a 1 '{"function":"CreatePaymentOrder","Args":["PO-0006","Org2MSP","3300000","EUR","710","Оплата по инвойсу 2026-0099"]}'; show_tx "Create PO-0006"
d="$(date +%F)"
inv C7b 1 "{\"function\":\"SetValueDate\",\"Args\":[\"PO-0006\",\"$d\"]}"; show_tx "SetValueDate PO-0006 = $d"
inv C7c 1 '{"function":"SubmitPaymentOrder","Args":["PO-0006"]}'; show_tx "Submit PO-0006"
inv C7d 2 '{"function":"AcceptPaymentOrder","Args":["PO-0006"]}'; show_tx "Accept PO-0006"
inv C7e 2 '{"function":"SettlePaymentOrder","Args":["PO-0006"]}'; show_tx "Settle PO-0006"
po6="$(ver PO-0006)"; echo "  $(jq -c '{id, status, valueDate, schemaVersion}' <<<"$po6")"
[[ "$(jq -r .status <<<"$po6")" == SETTLED ]] && { ok "C7: PO-0006 SETTLED, schemaVersion 2, valueDate $(jq -r .valueDate <<<"$po6")"; row C7 "PO-0006: Create, SetValueDate, Submit, Accept, Settle" "VALID" "VALID ×5, SETTLED" "\`$(csv_field "$CSV" C7e txid | cut -c1-16)…\`" PASS; } \
  || { fail C7; row C7 "PO-0006" "VALID" "$(jq -r .status <<<"$po6")" - FAIL; }

step "C8 — GetPaymentOrderHistory(PO-0001): TxID версии 1.0 и 2.0 в одной истории"
h="$(cc_query payment '{"Args":["GetPaymentOrderHistory","PO-0001"]}' 2>/dev/null)"
jq -r '.[] | "  \(.txId)  \(.value.status)  schemaVersion=\(.value.schemaVersion // "нет (v1.0)")"' <<<"$h"
v1n=0
for n in T1 T2 T3 T4; do jq -e --arg t "$(csv_field "$EVIDENCE/task1/txids.csv" $n txid)" 'any(.[]; .txId == $t)' <<<"$h" >/dev/null && v1n=$((v1n + 1)); done
jq -e --arg t "$t4" 'any(.[]; .txId == $t)' <<<"$h" >/dev/null && v2ok=1 || v2ok=0
(( v1n == 4 && v2ok == 1 )) && { ok "C8: в истории T1–T4 (v1.0) и Return $t4 (v2.0)"; row C8 "GetPaymentOrderHistory(PO-0001)" "TxID v1.0 и v2.0" "T1–T4 (v1.0) + C4 Return (v2.0)" - PASS; } \
  || { fail C8; row C8 "History" "оба" "v1=$v1n v2=$v2ok" - FAIL; }

step "C9 — Return от Org1 (не банк-получатель)"
inv C9x 1 '{"function":"CreatePaymentOrder","Args":["PO-0007","Org2MSP","100","KZT","119","C9 setup"]}' >/dev/null
use_org 1; cc_invoke payment '{"function":"ReturnPaymentOrder","Args":["PO-0006","ACCOUNT_CLOSED"]}' || true
expect_reject "C9 Return от Org1" ERR_UNAUTHORIZED
row C9 "Return PO-0006 от Org1MSP" "отказ (SC01)" "$(grep -oE 'ERR_[A-Z_]+: [^"]{0,60}' <<<"$TX_OUT" | head -1)" - "$(grep -q ERR_UNAUTHORIZED <<<"$TX_OUT" && echo PASS || echo FAIL)"
sed -i '/^C9x,/d' "$CSV"

{
  echo "# Проверка обратной совместимости payment 2.0 (C1–C9)"
  echo
  echo "| Проверка | Действие через v2.0 | Ожидание | Факт | TxID | Итог |"
  echo "|---|---|---|---|---|---|"
  printf '%s\n' "${ROWS[@]}"
} >"$TAB"
step "Таблица совместимости → evidence/task3/compat_table.md"
cat "$TAB"
summary
