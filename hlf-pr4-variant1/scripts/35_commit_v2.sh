#!/usr/bin/env bash
# Task 3.5 — commit payment 2.0 / sequence 2, verify the definition and show that the first invoke starts
# dev-peer*-payment_2.0-* containers.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
use_org 1
start_log task3 35_commit
step "docker ps (контейнеры chaincode) ДО commit"
docker ps --filter name=dev-peer --format 'table {{.Names}}\t{{.Status}}' | grep -E 'NAMES|payment_'
"$ROOT/scripts/lifecycle.sh" -n payment -p chaincode/payment-v2 -v 2.0 -s 2 -t task3 -g 35_lifecycle_commit_payment_2.0 --commit-only \
  | grep -E '✔|✘|➜|"sequence"|"version"|Decoded' || true
step "querycommitted после commit"
run peer lifecycle chaincode querycommitted --channelID "$CHANNEL" --name payment --output json
qc="$(peer lifecycle chaincode querycommitted --channelID "$CHANNEL" --name payment --output json 2>/dev/null)"
[[ "$(jq -r .version <<<"$qc")" == 2.0 ]] && ok "Version: 2.0" || fail "version"
[[ "$(jq -r .sequence <<<"$qc")" == 2 ]] && ok "Sequence: 2" || fail "sequence"
[[ "$(jq -r .validation_parameter <<<"$qc")" == "CiwSDBIKCAISAggAEgIIARoNEgsKB09yZzFNU1AQAxoNEgsKB09yZzJNU1AQAw==" ]] \
  && ok "Endorsement Policy без изменений: тот же validation_parameter, что у 1.0 (AND)"
[[ "$(jq -r '.approvals.Org1MSP and .approvals.Org2MSP' <<<"$qc")" == true ]] && ok "approvals обеих организаций"
step "Первый invoke через v2.0 (evaluate не запускает commit) — запуск контейнеров 2.0"
cc_query payment '{"Args":["PaymentOrderExists","PO-0001"]}' --peer 1 >/dev/null 2>&1 || true
cc_query payment '{"Args":["PaymentOrderExists","PO-0001"]}' --peer 2 >/dev/null 2>&1 || true
sleep 2
step "docker ps ПОСЛЕ первого обращения"
docker ps --filter name=dev-peer --format 'table {{.Names}}\t{{.Status}}' | grep -E 'NAMES|payment_'
n="$(docker ps --format '{{.Names}}' | grep -c 'payment_2.0' || true)"
(( n == 2 )) && ok "запущены dev-peer0.org1/org2-payment_2.0-* ($n контейнера)"
summary
