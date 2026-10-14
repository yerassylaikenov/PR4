#!/usr/bin/env bash
# Task 2/3 — proof that the main chaincode definition is unchanged (payment 1.0 / sequence 1).
# Usage: scripts/20_precheck.sh <task> <log-name> [expected-version] [expected-sequence]
set -euo pipefail
source "$(dirname "$0")/lib.sh"
use_org 1
start_log "${1:-task2}" "${2:-00_precheck}"
EV="${3:-1.0}"; ES="${4:-1}"
step "querycommitted --name payment (ожидается version $EV, sequence $ES)"
run peer lifecycle chaincode querycommitted --channelID "$CHANNEL" --name payment --output json
qc="$(peer lifecycle chaincode querycommitted --channelID "$CHANNEL" --name payment --output json 2>/dev/null)"
[[ "$(jq -r .version <<<"$qc")" == "$EV" ]] && ok "payment Version: $EV" || fail "version = $(jq -r .version <<<"$qc")"
[[ "$(jq -r .sequence <<<"$qc")" == "$ES" ]] && ok "payment Sequence: $ES" || fail "sequence = $(jq -r .sequence <<<"$qc")"
[[ "$(jq -r '.approvals.Org1MSP and .approvals.Org2MSP' <<<"$qc")" == true ]] && ok "approvals Org1MSP и Org2MSP"
step "Все определения chaincode в канале"
run peer lifecycle chaincode querycommitted --channelID "$CHANNEL"
summary
