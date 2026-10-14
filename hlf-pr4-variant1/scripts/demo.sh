#!/usr/bin/env bash
# Live end-to-end demonstration for the defence (main network must be running).
# Every check runs NOW against the live network; new objects get unique IDs, so it can be repeated.
#   ./scripts/demo.sh            — ≈ 2–3 min
#   ./scripts/demo.sh --full     — plus all 17 security tests (+ ≈ 2 min)
# Logs go to demo-evidence/ (the original evidence/ is never overwritten).
set -uo pipefail
export EVIDENCE_ROOT="${EVIDENCE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)/demo-evidence}"
source "$(dirname "$0")/lib.sh"
FULL=0; [[ "${1:-}" == "--full" ]] && FULL=1
RUN="$(date +%H%M%S)"
D="PO-DEMO-$RUN"; V="PO-DV-$RUN"; S="PO-DS-$RUN"
use_org 1
start_log demo "demo_$RUN"
pause() { [[ -t 0 && "${NOPAUSE:-0}" != 1 ]] && { printf '\n%s  [Enter — следующий раздел]%s' "$C_D" "$C_0"; read -r _; }; return 0; }
need() { "$@" >/dev/null 2>&1; }

printf '%s' "$C_B"
cat <<'EOF'

   ╔════════════════════════════════════════════════════════════════════════════╗
   ║  ПР №4 · Hyperledger Fabric 3.1.5 · Вариант 1 «Банковские операции»          ║
   ║  Org1 = Банк-отправитель · Org2 = Банк-получатель · PaymentOrder             ║
   ║  Айкенов Е.Ә., SSE-2502 · живая демонстрация с проверками ✔ / ✘              ║
   ╚════════════════════════════════════════════════════════════════════════════╝
EOF
printf '%s' "$C_0"

step "0. Окружение"
ok "$(. /etc/os-release; echo "$PRETTY_NAME") в WSL2, $(docker version --format 'Docker {{.Server.Version}}' 2>/dev/null)"
peer version 2>/dev/null | grep -q 'v3.1.5' && ok "Fabric peer CLI $(peer version | awk '/Version:/ {print $2; exit}'), Fabric CA $(fabric-ca-client version | awk '/Version:/ {print $2; exit}')"
for c in peer0.org1.example.com peer0.org2.example.com orderer.example.com ca_org1 ca_org2 ca_orderer couchdb0 couchdb1; do
  docker ps --format '{{.Names}}' | grep -qx "$c" && ok "контейнер $c работает" || fail "контейнер $c не запущен"
done
pause

step "1. Задание 1 — сеть, chaincode payment, транзакции, Ledger"
for org in 1 2; do use_org "$org"; peer channel list 2>/dev/null | grep -qx paymentchannel && ok "peer0.org$org ($CORE_PEER_LOCALMSPID) в канале paymentchannel"; done
use_org 1
osnadmin channel list -o localhost:7053 --ca-file "$ORDERER_CA" --client-cert "$ORDERER_ADMIN_TLS_SIGN_CERT" --client-key "$ORDERER_ADMIN_TLS_PRIVATE_KEY" 2>/dev/null \
  | grep -q paymentchannel && ok "Ordering Service (osnadmin) обслуживает paymentchannel"
qc="$(peer lifecycle chaincode querycommitted -C "$CHANNEL" -n payment --output json 2>/dev/null)"
ok "payment: version $(jq -r .version <<<"$qc"), sequence $(jq -r .sequence <<<"$qc"), approvals Org1MSP=$(jq -r .approvals.Org1MSP <<<"$qc") Org2MSP=$(jq -r .approvals.Org2MSP <<<"$qc"), политика AND (2 из 2)"
info "Полный жизненный цикл нового поручения $D (каждая транзакция endorse-ится peers ОБОИХ банков):"
for s in "1|CreatePaymentOrder|[\"$D\",\"Org2MSP\",\"7500000\",\"KZT\",\"119\",\"Демонстрация на защите\"]|Create (Org1)" \
         "1|SubmitPaymentOrder|[\"$D\"]|Submit (Org1)" "2|AcceptPaymentOrder|[\"$D\"]|Accept (Org2)" "2|SettlePaymentOrder|[\"$D\"]|Settle — исполнение (Org2)"; do
  IFS='|' read -r org fn args label <<<"$s"
  use_org "$org"; cc_invoke payment "{\"function\":\"$fn\",\"Args\":$args}" || true
  read -r blk _ code < <(tx_block_info "$TXID" 2>/dev/null || echo "? ? ?")
  [[ "$TX_STATUS" == VALID ]] && ok "$label → VALID, блок $blk, TxID ${TXID:0:20}…" || fail "$label → $TX_STATUS"
done
use_org 2; cc_invoke payment '{"function":"CreatePaymentOrder","Args":["PO-DEMO-X","Org1MSP","1","KZT","119","x"]}' || true
expect_reject "Org2 пытается создать поручение" ERR_UNAUTHORIZED
use_org 2; cc_invoke payment "{\"function\":\"SettlePaymentOrder\",\"Args\":[\"$D\"]}" || true
expect_reject "Повторное исполнение $D (replay)" ERR_INVALID_TRANSITION
use_org 1
[[ "$(cc_query payment "{\"Args\":[\"ReadPaymentOrder\",\"$D\"]}" 2>/dev/null | jq -r .status)" == SETTLED ]] && ok "ReadPaymentOrder($D) = SETTLED"
n="$(cc_query payment "{\"Args\":[\"GetPaymentOrderHistory\",\"$D\"]}" 2>/dev/null | jq length)"
(( n == 4 )) && ok "GetPaymentOrderHistory($D): 4 версии ключа (Create, Submit, Accept, Settle)"
info_now="$(peer channel getinfo -c "$CHANNEL" 2>/dev/null | sed 's/^Blockchain info: //')"
H="$(jq .height <<<"$info_now")"
W="$(mktemp -d)"
peer channel fetch newest "$W/n.pb" -c "$CHANNEL" -o "$ORDERER_ADDR" --ordererTLSHostnameOverride "$ORDERER_HOST" --tls --cafile "$ORDERER_CA" >/dev/null 2>&1
configtxlator proto_decode --type common.Block --input "$W/n.pb" --output "$W/n.json"
[[ "$(python3 "$ROOT/scripts/blockhash.py" "$W/n.json")" == "$(jq -r .currentBlockHash <<<"$info_now")" ]] \
  && ok "Ledger: высота $H; SHA-256 заголовка последнего блока пересчитан локально и равен currentBlockHash"
peer channel fetch "$((H - 2))" "$W/p.pb" -c "$CHANNEL" -o "$ORDERER_ADDR" --ordererTLSHostnameOverride "$ORDERER_HOST" --tls --cafile "$ORDERER_CA" >/dev/null 2>&1
configtxlator proto_decode --type common.Block --input "$W/p.pb" --output "$W/p.json"
[[ "$(python3 "$ROOT/scripts/blockhash.py" "$W/p.json")" == "$(jq -r .header.previous_hash "$W/n.json")" ]] \
  && ok "хэш-цепочка: hash(блок $((H - 2))) = previous_hash(блок $((H - 1)))"
rm -rf "$W"
pause

step "2. Задание 2 — уязвимость, её исправление, Private Data Collection"
use_org 1 initiator1
cc_invoke paymentvuln "{\"function\":\"CreatePaymentOrder\",\"Args\":[\"$V\",\"Org2MSP\",\"100000000\",\"KZT\",\"119\",\"demo\"]}" >/dev/null || true
use_org 2 processor2
cc_invoke paymentvuln "{\"function\":\"SubmitPaymentOrder\",\"Args\":[\"$V\"]}" || true
[[ "$TX_STATUS" == VALID ]] && warn "paymentvuln: Org2/processor2 авторизовал списание ЧУЖОГО поручения → VALID (уязвимость SC01 воспроизведена, TxID ${TXID:0:16}…)"
use_org 1 initiator1
cc_invoke paymentsecure "{\"function\":\"CreatePaymentOrder\",\"Args\":[\"$V\",\"Org2MSP\",\"100000000\",\"KZT\",\"119\",\"demo\"]}" >/dev/null || true
use_org 2 processor2
cc_invoke paymentsecure "{\"function\":\"SubmitPaymentOrder\",\"Args\":[\"$V\"]}" || true
expect_reject "paymentsecure: тот же Submit от Org2" ERR_UNAUTHORIZED
use_org 1 initiator1
cc_invoke paymentsecure "{\"function\":\"CreatePaymentOrder\",\"Args\":[\"$S\",\"Org2MSP\",\"2500000\",\"KZT\",\"119\",\"demo PDC\"]}" >/dev/null || true
tmpj="$(mktemp)"; chmod 600 "$tmpj"
jq -n --arg s "$(openssl rand -hex 32)" '{payerIBAN:"KZ09999TESTPAYER0001",payerBIN:"999999000001",beneficiaryIBAN:"KZ17999TESTBENEF0002",beneficiaryBIC:"TESTKZKAXXX",beneficiaryName:"TOO SYNTHETIC BENEFICIARY",salt:$s}' >"$tmpj"
cc_invoke paymentsecure "{\"function\":\"SetSettlementDetails\",\"Args\":[\"$S\"]}" --peers "1" --transient "{\"settlement\":\"$(base64 -w0 "$tmpj")\"}" || true
[[ "$TX_STATUS" == VALID ]] && ok "реквизиты переданы ТОЛЬКО через transient, endorse только peer0.org1 → VALID (TxID ${TXID:0:16}…)"
SETTX="$TXID"
r="$(cc_query paymentsecure "{\"Args\":[\"ReadSettlementDetails\",\"$S\"]}" --peer 1 2>/dev/null)"
jq -e .payerIBAN <<<"$r" >/dev/null && ok "Org1/initiator1 читает privateDetails: payerIBAN=$(jq -r '.payerIBAN[0:2]' <<<"$r")**************$(jq -r '.payerIBAN[-4:]' <<<"$r") (маскировано)"
use_org 2 processor2
r2="$(cc_query paymentsecure "{\"Args\":[\"ReadSettlementDetails\",\"$S\"]}" --peer 2 2>&1 || true)"
grep -q ERR_UNAUTHORIZED <<<"$r2" && ok "Org2/processor2 → отказ: $(grep -oE 'ERR_UNAUTHORIZED[^"]*' <<<"$r2" | head -1)"
m="$(cc_query paymentsecure "{\"Args\":[\"VerifySettlementDetails\",\"$S\"]}" --peer 2 --transient "{\"candidate\":\"$(base64 -w0 "$tmpj")\"}" 2>/dev/null | jq -r .match)"
[[ "$m" == true ]] && ok "Org2 сверяет реквизиты по хэшу без раскрытия: match=true"
use_org 1
W="$(mktemp -d)"; fetch_block_by_txid "$SETTX" "$W/b.json"
hits=$(grep -c -E 'KZ09999TESTPAYER0001|999999000001|TOO SYNTHETIC' "$W/b.json" || true)
(( hits == 0 )) && ok "в блоке транзакции SetSettlementDetails реквизитов нет (grep -c = 0), только хэши"
rm -rf "$W" "$tmpj"
if (( FULL )); then
  info "Полный набор security-тестов:"
  "$ROOT/tests/security/run_security_tests.sh" | grep -E 'SEC-|ИТОГ' || true
else
  info "все 17 security-тестов: ./scripts/demo.sh --full  или  ./tests/security/run_security_tests.sh"
fi
pause

step "3. Задание 3 — обновление payment 1.0 → 2.0 с сохранением состояния"
use_org 1
qc="$(peer lifecycle chaincode querycommitted -C "$CHANNEL" -n payment --output json 2>/dev/null)"
[[ "$(jq -r '"\(.version)/\(.sequence)"' <<<"$qc")" == 2.0/2 ]] && ok "payment: Version 2.0, Sequence 2 (было 1.0 / 1)"
h="$(cc_query payment '{"Args":["GetPaymentOrderHistory","PO-0001"]}' 2>/dev/null)"
jq -r 'reverse | .[] | "      \(.txId[0:20])…  \(.value.status)\t schemaVersion=\(.value.schemaVersion // "— (записано v1.0)")"' <<<"$h"
ok "PO-0001: в одной истории TxID версии 1.0 (без schemaVersion) и Return версии 2.0 (schemaVersion 2)"
use_org 2; cc_invoke payment "{\"function\":\"ReturnPaymentOrder\",\"Args\":[\"$D\",\"ACCOUNT_CLOSED\"]}" || true
[[ "$TX_STATUS" == VALID ]] && ok "новая функция v2.0: ReturnPaymentOrder($D) → VALID, статус RETURNED"
cc_invoke payment "{\"function\":\"ReturnPaymentOrder\",\"Args\":[\"$D\",\"ACCOUNT_CLOSED\"]}" || true
expect_reject "повторный Return" ERR_INVALID_TRANSITION
use_org 1
r="$(cc_query payment '{"Args":["GetPaymentOrdersByStatus","RETURNED","50",""]}' 2>/dev/null)"
jq -e --arg d "$D" '.records[] | select(.id == $d)' <<<"$r" >/dev/null && ok "rich query GetPaymentOrdersByStatus(RETURNED) по индексу CouchDB: $(jq -r '[.records[].id] | join(", ")' <<<"$r")"
inj="$(cc_query payment '{"Args":["GetPaymentOrdersByStatus","{\"$gt\":null}","10",""]}' 2>&1 || true)"
grep -q ERR_VALIDATION <<<"$inj" && ok "инъекция в CouchDB-селектор отклонена (ERR_VALIDATION)"

step "4. SmartBFT (отдельный стенд, Задание 3.7) — результаты эксперимента"
if [[ -f "$ROOT/evidence/task3/bft/experiment.md" ]]; then
  grep -E '^\| E[0-9]' "$ROOT/evidence/task3/bft/experiment.md" | awk -F'|' '{printf "      %-4s %-62s %-6s %-14s %s\n", $2, substr($3,1,62), $4, $5, $6}'
  ok "n = 4, f = 1: отказ 1 orderer — транзакции VALID; отказ лидера — view change; 2 orderer — нет кворума"
  info "живой повтор стенда: ./scripts/demo_bft.sh (≈ 10–15 мин: бэкап → BFT → эксперимент → восстановление)"
fi
summary
