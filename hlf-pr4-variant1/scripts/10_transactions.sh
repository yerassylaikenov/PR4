#!/usr/bin/env bash
# Step 10 (task 1.5) — business transactions with real TxIDs, block numbers and validation codes.
# T1–T7 valid, N1/N2 rejected at endorsement, M1/M2 — MVCC_READ_CONFLICT demo.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
use_org 1
CSV="$EVIDENCE/task1/txids.csv"
CLIENT="$ROOT/client/payment-client"

# Idempotency guard runs before start_log so the evidence log of the real run is never truncated.
if cc_query payment '{"Args":["PaymentOrderExists","PO-0001"]}' 2>/dev/null | grep -q true; then
  info "Сценарий уже выполнен (PO-0001 существует) — повтор не нужен; реальные TxID (evidence/task1/txids.csv):"
  column -t -s, "$CSV"
  exit 0
fi
start_log task1 10_transactions
rm -f "$CSV"

inv() { # inv <n> <org> <label> <fn> <args-json-array>
  local n="$1" org="$2" label="$3" fn="$4" args="$5"
  use_org "$org"
  printf '\n%s[%s] %s — %s/%s%s\n' "$C_B" "$n" "$label" "$CORE_PEER_LOCALMSPID" "$ORG_USER" "$C_0"
  printf '%s$ peer chaincode invoke -C %s -n payment -c %s --peerAddresses peer0.org1 --peerAddresses peer0.org2 --waitForEvent%s\n' \
    "$C_D" "$CHANNEL" "{\"function\":\"$fn\",\"Args\":$args}" "$C_0"
  cc_invoke payment "{\"function\":\"$fn\",\"Args\":$args}" || true
  grep -E 'ClientWait|Chaincode invoke successful|Error' <<<"$TX_OUT" | sed 's/^/  /'
  record_tx "$CSV" "$n" "$fn" "$args"
}

step "Задание 1.5 — транзакции chaincode payment v1.0 (канал $CHANNEL)"
inv T1 1 "Create PO-0001 (5 000 000 тиын, KZT, КНП 119)" CreatePaymentOrder '["PO-0001","Org2MSP","5000000","KZT","119","Оплата по счёту №42 за услуги"]'
show_tx "T1 Create PO-0001 (block $TX_BLOCK)"
inv T2 1 "Submit PO-0001 (авторизация списания)" SubmitPaymentOrder '["PO-0001"]'
show_tx "T2 Submit PO-0001 (block $TX_BLOCK)"
inv T3 2 "Accept PO-0001 (банк-получатель)" AcceptPaymentOrder '["PO-0001"]'
show_tx "T3 Accept PO-0001 (block $TX_BLOCK)"
inv T4 2 "Settle PO-0001 — ОСНОВНАЯ БИЗНЕС-ОПЕРАЦИЯ (исполнение платежа)" SettlePaymentOrder '["PO-0001"]'
show_tx "T4 Settle PO-0001 (block $TX_BLOCK)"
echo "$TXID" >"$EVIDENCE/task1/T4.txid"

step "T5 через Fabric Gateway (Go, fabric-gateway SDK) — компонент Gateway на схеме реален"
use_org 1
printf '%s$ client/payment-client -org 1 -user Admin submit payment CreatePaymentOrder PO-0002 Org2MSP 120000000 USD 710 "..."%s\n' "$C_D" "$C_0"
gw_out="$(ROOT="$ROOT" "$CLIENT" -org 1 -user Admin submit payment CreatePaymentOrder PO-0002 Org2MSP 120000000 USD 710 "Импорт оборудования, контракт 2026/17" 2>&1)" || true
echo "$gw_out" | sed 's/^/  /'
TXID="$(awk '/^TxID/ {print $3}' <<<"$gw_out")"
TX_STATUS="$(awk '/^Status/ {print $3}' <<<"$gw_out")"
TX_OUT="$gw_out"
record_tx "$CSV" T5 "CreatePaymentOrder (Gateway)" '["PO-0002","Org2MSP","120000000","USD","710","Импорт оборудования; контракт 2026/17"]'
gw_block="$(awk '/^Block/ {print $3}' <<<"$gw_out")"
[[ "$gw_block" == "$TX_BLOCK" ]] && ok "Gateway: блок $gw_block совпадает с qscc GetBlockByTxID"
show_tx "T5 Create PO-0002 via Gateway (block $TX_BLOCK)"

inv T6 1 "Cancel PO-0002" CancelPaymentOrder '["PO-0002"]'
show_tx "T6 Cancel PO-0002 (block $TX_BLOCK)"
inv T7 1 "Create PO-0003 (остаётся в CREATED для Задания 3)" CreatePaymentOrder '["PO-0003","Org2MSP","75000000","KZT","342","Возврат займа по договору 15-К"]'
show_tx "T7 Create PO-0003 (block $TX_BLOCK)"

step "Негативные сценарии — отказ на этапе endorsement (в ledger не попадают)"
inv N1 2 "Settle PO-0003 из CREATED (недопустимый переход)" SettlePaymentOrder '["PO-0003"]'
expect_reject "N1 Settle PO-0003" "ERR_INVALID_TRANSITION"
inv N2 2 "Create PO-0004 от Org2 (банк-получатель не создаёт поручения)" CreatePaymentOrder '["PO-0004","Org1MSP","100","KZT","119","Попытка от Org2"]'
expect_reject "N2 Create PO-0004 by Org2" "ERR_UNAUTHORIZED"
use_org 1
cc_query payment '{"Args":["PaymentOrderExists","PO-0004"]}' 2>/dev/null | grep -q false && ok "PO-0004 отсутствует в World State"
[[ -z "$(grep '^N1,' "$CSV" | cut -d, -f5 | tr -d '-')" || "$(grep '^N1,' "$CSV" | cut -d, -f6)" == "-" ]] && ok "N1/N2: блок не создан (TxID не попал в ledger)"

step "Демонстрация MVCC: Submit и Cancel одного ключа PO-0005 параллельно"
inv T8 1 "Create PO-0005" CreatePaymentOrder '["PO-0005","Org2MSP","990000","EUR","119","MVCC demo"]'
show_tx "T8 Create PO-0005 (block $TX_BLOCK)"
use_org 1
"$ROOT/scripts/10b_mvcc_demo.sh" | grep -E '✔|✘|блок #|M[12]:' || true

step "Итоговая таблица TxID (evidence/task1/txids.csv)"
column -t -s, "$CSV"
valid=$(grep -c ',VALID$' "$CSV")
(( valid >= 4 )) && ok "VALID-транзакций: $valid (требуется ≥ 4), одна из них через Gateway (T5)"
summary
