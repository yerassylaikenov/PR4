#!/usr/bin/env bash
# Task 2.7 — security tests against the live network (paymentsecure + collectionSettlementDetails).
# Re-runnable: every run creates its own payment orders (PO-<RUN>-...), so it can be shown at the defence.
# Output: terminal ✔/✘, evidence/task2/security_tests.md (table), evidence/task2/security_tests.log.
set -euo pipefail
source "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib.sh"
RUN="$(date +%H%M%S)"
A="PO-${RUN}-A"   # full lifecycle with details
B="PO-${RUN}-B"   # CREATED, details set (input validation target)
C="PO-${RUN}-C"   # CREATED, no details
use_org 1 initiator1
start_log task2 security_tests
MD="$EVIDENCE/task2/security_tests.md"
SEC="$ROOT/.secrets"; mkdir -p "$SEC"; chmod 700 "$SEC"
CC=paymentsecure
ROWS=(); NPASS=0; NFAIL=0

details() { # <file> [jq-mutation]
  jq -n --arg s "$(openssl rand -hex 32)" \
    '{payerIBAN:"KZ09999TESTPAYER0001", payerBIN:"999999000001", beneficiaryIBAN:"KZ17999TESTBENEF0002",
      beneficiaryBIC:"TESTKZKAXXX", beneficiaryName:"TOO SYNTHETIC BENEFICIARY", salt:$s}' | jq "${2:-.}" >"$1"
  chmod 600 "$1"
}
tr_of() { printf '{"%s":"%s"}' "$1" "$(base64 -w0 "$2")"; }
excerpt() { grep -oE 'ERR_[A-Z_]+: [^"]{0,80}|committed with status \([A-Z_]+\)|"match":(true|false)|"payerIBAN":"KZ' <<<"$1" | head -1 | sed 's/|/\\|/g'; }

# result <id> <owasp> <desc> <who@peer> <expect> <pass:0|1> <actual> [txid]
result() {
  local id="$1" ow="$2" desc="$3" who="$4" exp="$5" pass="$6" act="$7" tx="${8:--}"
  if (( pass )); then ok "$id [$ow] $desc → $act"; NPASS=$((NPASS + 1)); v=PASS
  else fail "$id [$ow] $desc → ожидалось: $exp; факт: $act"; NFAIL=$((NFAIL + 1)); v=FAIL; fi
  local txcell="-"
  [[ "$tx" != - ]] && txcell="\`${tx:0:16}…\`"
  ROWS+=("| $id | $ow | $desc | $who | $exp | \`$act\` | $txcell | **$v** |")
}

# inv <org> <user> <peers> <json> [transient] — submit; sets TX_OUT/TX_STATUS/TXID
inv() {
  use_org "$1" "$2"
  if [[ -n "${5:-}" ]]; then cc_invoke "$CC" "$4" --peers "$3" --transient "$5" || true
  else cc_invoke "$CC" "$4" --peers "$3" || true; fi
}
# qry <org> <user> <peer> <json> [transient] — evaluate on one peer; sets Q_OUT
qry() {
  use_org "$1" "$2"
  # keep the payload or the error, drop the CLI's INFO chatter
  if [[ -n "${5:-}" ]]; then Q_OUT="$(cc_query "$CC" "$4" --peer "$3" --transient "$5" 2>&1 | grep -v 'chaincodeCmd' || true)"
  else Q_OUT="$(cc_query "$CC" "$4" --peer "$3" 2>&1 | grep -v 'chaincodeCmd' || true)"; fi
}
expect_err() { [[ "${TX_STATUS:-}" != VALID ]] && grep -q "$1" <<<"$2"; }

step "Подготовка (прогон $RUN): $A, $B — с реквизитами, $C — без реквизитов"
details "$SEC/$A.json"; details "$SEC/$B.json"
for id in "$A" "$B" "$C"; do
  inv 1 initiator1 "1 2" "{\"function\":\"CreatePaymentOrder\",\"Args\":[\"$id\",\"Org2MSP\",\"1000000\",\"KZT\",\"119\",\"Security test $RUN\"]}"
  [[ "$TX_STATUS" == VALID ]] && ok "создан $id ($TXID)" || die "не удалось создать $id: $(excerpt "$TX_OUT")"
done
for id in "$A" "$B"; do
  inv 1 initiator1 "1" "{\"function\":\"SetSettlementDetails\",\"Args\":[\"$id\"]}" "$(tr_of settlement "$SEC/$id.json")"
  [[ "$TX_STATUS" == VALID ]] && ok "реквизиты $id записаны в collectionSettlementDetails ($TXID)" || die "SetSettlementDetails $id"
done

step "Разграничение доступа к privateDetails (Org1 vs Org2)"
qry 1 initiator1 1 "{\"Args\":[\"ReadSettlementDetails\",\"$A\"]}"
masked="$(jq -r '"payerIBAN=\(.payerIBAN[0:2])**************\(.payerIBAN[-4:])"' <<<"$Q_OUT" 2>/dev/null || echo "$Q_OUT")"
result SEC-01 SC01 "initiator1 читает реквизиты на peer0.org1" "Org1MSP/initiator1@peer0.org1" "данные получены" \
  "$(jq -e .payerIBAN <<<"$Q_OUT" >/dev/null 2>&1 && echo 1 || echo 0)" "$masked"
qry 2 processor2 2 "{\"Args\":[\"ReadSettlementDetails\",\"$A\"]}"
result SEC-02 SC01 "processor2 (Org2) читает реквизиты на peer0.org2" "Org2MSP/processor2@peer0.org2" "отказ" \
  "$(grep -q ERR_UNAUTHORIZED <<<"$Q_OUT" && echo 1 || echo 0)" "$(excerpt "$Q_OUT")"
qry 2 processor2 1 "{\"Args\":[\"ReadSettlementDetails\",\"$A\"]}"
result SEC-03 SC01 "processor2 (Org2) читает реквизиты на peer0.org1" "Org2MSP/processor2@peer0.org1" "отказ" \
  "$(grep -qE 'ERR_UNAUTHORIZED|denied|not allowed' <<<"$Q_OUT" && echo 1 || echo 0)" "$(excerpt "$Q_OUT")"

step "Исправление уязвимости paymentvuln и полномочия ролей"
inv 2 processor2 "1 2" "{\"function\":\"SubmitPaymentOrder\",\"Args\":[\"$A\"]}"
result SEC-04 "SC01/SC03" "повтор эксплойта: processor2 (Org2) Submit чужого поручения" "Org2MSP/processor2" "отказ" \
  "$(expect_err ERR_UNAUTHORIZED "$TX_OUT" && echo 1 || echo 0)" "$(excerpt "$TX_OUT")"
inv 1 initiator1 "1 2" "{\"function\":\"SubmitPaymentOrder\",\"Args\":[\"$A\"]}"
result SEC-05 "SC01/SC03" "initiator1 сам авторизует своё поручение (нет роли approver, 4 глаза)" "Org1MSP/initiator1" "отказ" \
  "$(expect_err ERR_UNAUTHORIZED "$TX_OUT" && echo 1 || echo 0)" "$(excerpt "$TX_OUT")"
inv 1 norole1 "1 2" "{\"function\":\"CreatePaymentOrder\",\"Args\":[\"PO-${RUN}-N\",\"Org2MSP\",\"100\",\"KZT\",\"119\",\"no role\"]}"
result SEC-06 SC01 "norole1 (Org1 без роли) создаёт поручение" "Org1MSP/norole1" "отказ" \
  "$(expect_err ERR_UNAUTHORIZED "$TX_OUT" && echo 1 || echo 0)" "$(excerpt "$TX_OUT")"

step "Переходы состояния и повторное исполнение"
inv 1 approver1 "1 2" "{\"function\":\"SubmitPaymentOrder\",\"Args\":[\"$A\"]}"
[[ "$TX_STATUS" == VALID ]] && ok "approver1 (другой сотрудник Org1) авторизовал $A — четыре глаза соблюдены ($TXID)" || fail "Submit approver1: $(excerpt "$TX_OUT")"
inv 2 processor2 "1 2" "{\"function\":\"SettlePaymentOrder\",\"Args\":[\"$A\"]}"
result SEC-07 SC03 "Settle из SUBMITTED в обход ACCEPTED" "Org2MSP/processor2" "отказ" \
  "$(expect_err ERR_INVALID_TRANSITION "$TX_OUT" && echo 1 || echo 0)" "$(excerpt "$TX_OUT")"
inv 2 processor2 "1 2" "{\"function\":\"AcceptPaymentOrder\",\"Args\":[\"$A\"]}"
[[ "$TX_STATUS" == VALID ]] && ok "processor2 принял $A ($TXID)"
inv 2 processor2 "1 2" "{\"function\":\"SettlePaymentOrder\",\"Args\":[\"$A\"]}"
first_settle="$TXID"
[[ "$TX_STATUS" == VALID ]] && ok "processor2 исполнил $A ($TXID)"
inv 2 processor2 "1 2" "{\"function\":\"SettlePaymentOrder\",\"Args\":[\"$A\"]}"
result SEC-08 SC03 "повторный Settle уже исполненного поручения (replay)" "Org2MSP/processor2" "отказ" \
  "$(expect_err ERR_INVALID_TRANSITION "$TX_OUT" && echo 1 || echo 0)" "$(excerpt "$TX_OUT")" "$first_settle"
inv 1 initiator1 "1 2" "{\"function\":\"CreatePaymentOrder\",\"Args\":[\"$A\",\"Org2MSP\",\"1\",\"KZT\",\"119\",\"duplicate\"]}"
result SEC-09 SC03 "Create с существующим ID" "Org1MSP/initiator1" "отказ" \
  "$(expect_err ERR_ALREADY_EXISTS "$TX_OUT" && echo 1 || echo 0)" "$(excerpt "$TX_OUT")"

step "Валидация входных данных"
all=1; acts=()
for amt in -1 0 9223372036854775808 1e3; do
  inv 1 initiator1 "1 2" "{\"function\":\"CreatePaymentOrder\",\"Args\":[\"PO-${RUN}-V\",\"Org2MSP\",\"$amt\",\"KZT\",\"119\",\"x\"]}"
  expect_err ERR_VALIDATION "$TX_OUT" && acts+=("amount=$amt:✔") || { all=0; acts+=("amount=$amt:✘"); }
done
inv 1 initiator1 "1 2" "{\"function\":\"CreatePaymentOrder\",\"Args\":[\"PO-${RUN}-V\",\"Org2MSP\",\"100\",\"XXX\",\"119\",\"x\"]}"
expect_err ERR_VALIDATION "$TX_OUT" && acts+=("XXX:✔") || { all=0; acts+=("XXX:✘"); }
details "$SEC/bad.json" '.payerIBAN="KZ10999TESTPAYER0001"'
inv 1 initiator1 "1" "{\"function\":\"SetSettlementDetails\",\"Args\":[\"$B\"]}" "$(tr_of settlement "$SEC/bad.json")"
expect_err "mod-97" "$TX_OUT" && acts+=("IBAN mod-97:✔") || { all=0; acts+=("IBAN mod-97:✘"); }
result SEC-10 "SC04/SC08" "невалидные: сумма -1, 0, 2^63, 1e3; валюта XXX; IBAN с ошибкой контрольной суммы" "Org1MSP/initiator1" "отказ на каждый вариант" "$all" "${acts[*]}"

all=1; acts=()
inv 1 initiator1 "1" "{\"function\":\"SetSettlementDetails\",\"Args\":[\"$B\"]}"
expect_err ERR_VALIDATION "$TX_OUT" && acts+=("без transient:✔") || { all=0; acts+=("без transient:✘"); }
head -c 5000 /dev/zero | tr '\0' 'A' >"$SEC/big.txt"
inv 1 initiator1 "1" "{\"function\":\"SetSettlementDetails\",\"Args\":[\"$B\"]}" "{\"settlement\":\"$(base64 -w0 "$SEC/$B.json")\",\"pad\":\"$(base64 -w0 "$SEC/big.txt")\"}"
expect_err "exceeds 4096" "$TX_OUT" && acts+=(">4КБ:✔") || { all=0; acts+=(">4КБ:✘"); }
details "$SEC/bad.json" '.salt="abcd"'
inv 1 initiator1 "1" "{\"function\":\"SetSettlementDetails\",\"Args\":[\"$B\"]}" "$(tr_of settlement "$SEC/bad.json")"
expect_err "salt" "$TX_OUT" && acts+=("короткая соль:✔") || { all=0; acts+=("короткая соль:✘"); }
details "$SEC/bad.json" '.cvv="123"'
inv 1 initiator1 "1" "{\"function\":\"SetSettlementDetails\",\"Args\":[\"$B\"]}" "$(tr_of settlement "$SEC/bad.json")"
expect_err "unknown fields" "$TX_OUT" && acts+=("лишнее поле:✔") || { all=0; acts+=("лишнее поле:✘"); }
rm -f "$SEC/bad.json" "$SEC/big.txt"
result SEC-11 "SC04/SC10" "SetSettlementDetails: без transient / >4 КБ / короткая соль / лишнее поле" "Org1MSP/initiator1@peer0.org1" "отказ" "$all" "${acts[*]}"

inv 1 initiator1 "1" "{\"function\":\"SetSettlementDetails\",\"Args\":[\"$A\"]}" "$(tr_of settlement "$SEC/$A.json")"
result SEC-12 SC03 "SetSettlementDetails после SUBMITTED/SETTLED (INV-9)" "Org1MSP/initiator1@peer0.org1" "отказ" \
  "$(expect_err ERR_INVALID_TRANSITION "$TX_OUT" && echo 1 || echo 0)" "$(excerpt "$TX_OUT")"

step "Сверка реквизитов банком-получателем без раскрытия (хэш + соль)"
qry 2 processor2 2 "{\"Args\":[\"VerifySettlementDetails\",\"$A\"]}" "$(tr_of candidate "$SEC/$A.json")"
m1="$(jq -r .match <<<"$Q_OUT" 2>/dev/null || echo err)"
details "$SEC/cand.json" '.beneficiaryIBAN="KZ60999TESTBENEF0004"'
qry 2 processor2 2 "{\"Args\":[\"VerifySettlementDetails\",\"$A\"]}" "$(tr_of candidate "$SEC/cand.json")"
m2="$(jq -r .match <<<"$Q_OUT" 2>/dev/null || echo err)"; rm -f "$SEC/cand.json"
result SEC-13 SC01 "processor2 Verify: верный кандидат → true, неверный → false" "Org2MSP/processor2@peer0.org2" "true / false" \
  "$([[ "$m1" == true && "$m2" == false ]] && echo 1 || echo 0)" "верный: match=$m1; неверный: match=$m2"

step "DoS и утечки"
qry 2 processor2 2 '{"Args":["GetAllPaymentOrders","10000",""]}'
result SEC-14 SC10 "GetAllPaymentOrders pageSize=10000" "Org2MSP/processor2" "отказ (лимит 50)" \
  "$(grep -q 'ERR_VALIDATION' <<<"$Q_OUT" && echo 1 || echo 0)" "$(excerpt "$Q_OUT")"

use_org 1 initiator1
W="$(mktemp -d)"; H="$(peer channel getinfo -c "$CHANNEL" 2>/dev/null | sed 's/^Blockchain info: //' | jq -r .height)"
hits=0
for ((b = 0; b < H; b++)); do
  peer chaincode query -C "$CHANNEL" -n qscc -c "{\"Args\":[\"GetBlockByNumber\",\"$CHANNEL\",\"$b\"]}" --hex 2>/dev/null | tr -d '\n' | xxd -r -p >"$W/b.pb"
  for m in KZ09999TESTPAYER0001 KZ17999TESTBENEF0002 999999000001 "TOO SYNTHETIC"; do
    n="$(grep -c -a -- "$m" "$W/b.pb" || true)"; hits=$((hits + n))
  done
done
COUCH_USER="$(grep -m1 'COUCHDB_USER=' "$TEST_NETWORK/compose/compose-couch.yaml" | sed 's/.*COUCHDB_USER=//' | tr -d ' "')"
COUCH_PASS="$(grep -m1 'COUCHDB_PASSWORD=' "$TEST_NETWORK/compose/compose-couch.yaml" | sed 's/.*COUCHDB_PASSWORD=//' | tr -d ' "')"
c2=0
for db in $(curl -s -u "$COUCH_USER:$COUCH_PASS" http://localhost:7984/_all_dbs | jq -r '.[] | @uri'); do
  n="$(curl -s -u "$COUCH_USER:$COUCH_PASS" "http://localhost:7984/$db/_all_docs?include_docs=true" | grep -c -E 'KZ09999TESTPAYER0001|999999000001|TOO SYNTHETIC' || true)"; c2=$((c2 + n))
done
unset COUCH_USER COUCH_PASS
lg=0
for c in $(docker ps --format '{{.Names}}' | grep -E 'peer0|orderer|paymentsecure'); do
  n="$(docker logs "$c" 2>&1 | grep -c -E 'KZ09999TESTPAYER0001|999999000001|TOO SYNTHETIC' || true)"; lg=$((lg + n))
done
rm -rf "$W"
result SEC-15 "SC01 (Info. Disclosure)" "маркеры реквизитов: все $H блоков канала, все базы CouchDB Org2, логи контейнеров" "—" "0 совпадений" \
  "$(( hits + c2 + lg == 0 ? 1 : 0 ))" "блоки=$hits couchdb1=$c2 логи=$lg"

inv 1 approver1 "1 2" "{\"function\":\"SubmitPaymentOrder\",\"Args\":[\"$C\"]}"
result SEC-16 SC03 "Submit поручения без реквизитов (INV-9)" "Org1MSP/approver1" "отказ" \
  "$(expect_err "settlement details must be set" "$TX_OUT" && echo 1 || echo 0)" "$(excerpt "$TX_OUT")"

inv 1 initiator1 "2" "{\"function\":\"SetSettlementDetails\",\"Args\":[\"$C\"]}" "$(tr_of settlement "$SEC/$B.json")"
result SEC-17 "SC01 (Info. Disclosure)" "SetSettlementDetails отправлен на peer0.org2 (не член коллекции)" "Org1MSP/initiator1@peer0.org2" "отказ" \
  "$(expect_err ERR_UNAUTHORIZED "$TX_OUT" && echo 1 || echo 0)" "$(excerpt "$TX_OUT")"

{
  echo "# Security-тесты paymentsecure (прогон $RUN, $(date '+%Y-%m-%d %H:%M:%S'))"
  echo
  echo "Скрипт: \`tests/security/run_security_tests.sh\`. Объекты прогона: \`$A\` (полный цикл), \`$B\` (CREATED + реквизиты), \`$C\` (CREATED без реквизитов). Значения реквизитов маскированы."
  echo
  echo "| ID | OWASP SC | Сценарий | Идентичность / peer | Ожидание | Фактический результат | TxID | Итог |"
  echo "|---|---|---|---|---|---|---|---|"
  printf '%s\n' "${ROWS[@]}"
  echo
  echo "**Итого: $NPASS PASS, $NFAIL FAIL из $((NPASS + NFAIL)).**"
} >"$MD"
step "Итог security-тестов: $NPASS PASS / $NFAIL FAIL → evidence/task2/security_tests.md"
summary
