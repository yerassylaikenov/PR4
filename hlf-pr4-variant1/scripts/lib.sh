#!/usr/bin/env bash
# Shared helpers for all PR4 scripts. Source it: source "$(dirname "$0")/lib.sh"
# Provides: paths, coloured ✔/✘ output, start_log (tee + redaction), org switching,
# chaincode invoke/query wrappers that capture TxID / status / block number.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT
# EVIDENCE_ROOT=demo-evidence lets demo runs write their logs elsewhere and never overwrite the evidence.
export EVIDENCE="${EVIDENCE_ROOT:-$ROOT/evidence}"
export FABRIC_SAMPLES="$ROOT/fabric-samples"
export TEST_NETWORK="$FABRIC_SAMPLES/test-network"
export PATH="$FABRIC_SAMPLES/bin:/usr/local/go/bin:$HOME/go/bin:$PATH"
export FABRIC_CFG_PATH="$FABRIC_SAMPLES/config"
export CHANNEL="${CHANNEL:-paymentchannel}"
export ORDERER_ADDR="${ORDERER_ADDR:-localhost:7050}"
export ORDERER_HOST="${ORDERER_HOST:-orderer.example.com}"
export FABRIC_LOGGING_SPEC="${FABRIC_LOGGING_SPEC:-grpc=error:info}"

if [[ -t 1 || "${FORCE_COLOR:-1}" == "1" ]]; then
  C_G=$'\e[1;32m'; C_R=$'\e[1;31m'; C_Y=$'\e[1;33m'; C_B=$'\e[1;36m'; C_M=$'\e[1;35m'; C_D=$'\e[2m'; C_0=$'\e[0m'
else
  C_G=; C_R=; C_Y=; C_B=; C_M=; C_D=; C_0=
fi

PASS_COUNT=0
FAIL_COUNT=0

ok()    { printf '%s  ✔ %s%s\n' "$C_G" "$*" "$C_0"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail()  { printf '%s  ✘ %s%s\n' "$C_R" "$*" "$C_0"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
info()  { printf '%s  ➜ %s%s\n' "$C_B" "$*" "$C_0"; }
warn()  { printf '%s  ⚠ %s%s\n' "$C_Y" "$*" "$C_0"; }
note()  { printf '%s    %s%s\n' "$C_D" "$*" "$C_0"; }
step()  { printf '\n%s━━━━ %s ━━━━%s\n' "$C_M" "$*" "$C_0"; }
die()   { fail "$*"; exit 1; }

# Prints a command (as the user would type it) and runs it.
run() { printf '%s$ %s%s\n' "$C_D" "$*" "$C_0"; "$@"; }

# check "<description>" <command...> — ✔ when the command succeeds, ✘ otherwise.
check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; return 0; else fail "$desc"; return 1; fi
}

# summary — final banner with pass/fail counters; non-zero exit if anything failed.
summary() {
  echo
  if (( FAIL_COUNT == 0 )); then
    printf '%s  ══════ ИТОГ: %d проверок пройдено, ошибок нет ✔ ══════%s\n' "$C_G" "$PASS_COUNT" "$C_0"
  else
    printf '%s  ══════ ИТОГ: %d ✔ / %d ✘ ══════%s\n' "$C_R" "$PASS_COUNT" "$FAIL_COUNT" "$C_0"
  fi
  sleep 0.5
  (( FAIL_COUNT == 0 ))
}

# start_log <task> <name> — duplicate stdout/stderr into evidence/<task>/<name>.log.
# The stream passes scripts/redact.sh first, so secrets never reach the terminal or the file;
# ANSI colours are stripped in the file copy.
start_log() {
  local task="$1" name="$2"
  LOG="$EVIDENCE/$task/$name.log"
  mkdir -p "$(dirname "$LOG")"
  # LOG_APPEND=1 continues an existing evidence log (resumed run) instead of truncating it.
  if [[ "${LOG_APPEND:-0}" == 1 && -s "$LOG" ]]; then echo "# --- продолжение (resumed run) ---" >>"$LOG"; else : >"$LOG"; fi
  exec > >("$ROOT/scripts/redact.sh" | tee >(sed -u 's/\x1b\[[0-9;]*m//g' >>"$LOG")) 2>&1
  echo "# command : ${SCRIPT_CMD:-$0 ${*:3}}"
  echo "# date    : $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "# host    : $(uname -sr) ($(grep -qi microsoft /proc/version && echo WSL2 || echo native))"
  echo "# identity: MSP=${CORE_PEER_LOCALMSPID:-n/a} user=${ORG_USER:-n/a}"
  echo "# log     : ${LOG#"$ROOT"/}"
}

# log_identity — re-print the active identity (after switching organisations).
log_identity() { echo "# identity: MSP=$CORE_PEER_LOCALMSPID user=$ORG_USER peer=$CORE_PEER_ADDRESS"; }

# use_org <1|2> [user] — switch the CLI environment (peer + MSP identity).
use_org() {
  local org="$1"
  export ORG_USER="${2:-Admin}"
  # shellcheck source=/dev/null
  source "$ROOT/scripts/env_org${org}.sh"
}

# peer_flags <org...> — --peerAddresses/--tlsRootCertFiles for the given orgs.
peer_flags() {
  local o
  for o in "$@"; do
    case "$o" in
      1) printf -- '--peerAddresses localhost:7051 --tlsRootCertFiles %s ' "$PEER0_ORG1_CA" ;;
      2) printf -- '--peerAddresses localhost:9051 --tlsRootCertFiles %s ' "$PEER0_ORG2_CA" ;;
    esac
  done
}

# cc_invoke <cc> <json> [--peers "1 2"] [extra peer args...]
# Sets TXID, TX_STATUS, TX_OUT; returns the peer CLI exit code.
cc_invoke() {
  local cc="$1" json="$2"; shift 2
  local peers="1 2"
  if [[ "${1:-}" == "--peers" ]]; then peers="$2"; shift 2; fi
  local rc=0
  # shellcheck disable=SC2046
  TX_OUT="$(peer chaincode invoke -o "$ORDERER_ADDR" --ordererTLSHostnameOverride "$ORDERER_HOST" \
    --tls --cafile "$ORDERER_CA" -C "$CHANNEL" -n "$cc" $(peer_flags $peers) \
    -c "$json" --waitForEvent --waitForEventTimeout "${TX_WAIT:-60s}" "$@" 2>&1)" || rc=$?
  TXID="$(grep -oP 'txid \[\K[0-9a-f]+' <<<"$TX_OUT" | head -1 || true)"
  TX_STATUS="$(grep -oP 'committed with status \(\K[A-Z_]+' <<<"$TX_OUT" | head -1 || true)"
  if [[ -z "$TX_STATUS" && $rc -ne 0 ]]; then
    # endorsed and broadcast, but no block arrived in time (e.g. ordering service without quorum)
    if grep -qE 'DeadlineExceeded|timed out waiting|deliver' <<<"$TX_OUT" && ! grep -q 'endorsement failure' <<<"$TX_OUT"; then
      TX_STATUS="TIMEOUT_NO_BLOCK"
    else
      TX_STATUS="REJECTED_AT_ENDORSEMENT"
    fi
  fi
  return $rc
}

# cc_query <cc> <json> [--peer N] — evaluate on one peer; prints the payload.
cc_query() {
  local cc="$1" json="$2"; shift 2
  local p=""
  if [[ "${1:-}" == "--peer" ]]; then p="$2"; shift 2; fi
  if [[ -n "$p" ]]; then
    # shellcheck disable=SC2046
    peer chaincode query -C "$CHANNEL" -n "$cc" -c "$json" $(peer_flags "$p") "$@"
  else
    peer chaincode query -C "$CHANNEL" -n "$cc" -c "$json" "$@"
  fi
}

# fetch_block_by_txid <txid> <out.json> — qscc GetBlockByTxID -> decoded common.Block JSON.
fetch_block_by_txid() {
  local txid="$1" out="$2" tmp
  tmp="$(mktemp)"
  peer chaincode query -C "$CHANNEL" -n qscc \
    -c "{\"Args\":[\"GetBlockByTxID\",\"$CHANNEL\",\"$txid\"]}" --hex 2>/dev/null | tr -d '\n' | xxd -r -p >"$tmp"
  configtxlator proto_decode --type common.Block --input "$tmp" --output "$out"
  rm -f "$tmp"
}

# fetch_block_by_number <n> <out.json> — committed block from the PEER ledger (qscc GetBlockByNumber).
# Unlike `peer channel fetch` (served by the orderer), it carries TRANSACTIONS_FILTER (validation codes).
fetch_block_by_number() {
  local n="$1" out="$2" tmp
  tmp="$(mktemp)"
  peer chaincode query -C "$CHANNEL" -n qscc \
    -c "{\"Args\":[\"GetBlockByNumber\",\"$CHANNEL\",\"$n\"]}" --hex 2>/dev/null | tr -d '\n' | xxd -r -p >"$tmp"
  configtxlator proto_decode --type common.Block --input "$tmp" --output "$out"
  rm -f "$tmp"
}

# block_codes <block.json> — validation code numbers of all transactions, one per line.
block_codes() { jq -r '.metadata.metadata[2]' "$1" | base64 -d | od -An -tu1 -v | tr -s ' ' '\n' | sed '/^$/d'; }

# tx_block_info <txid> — prints "<block> <tx_index> <validation_code_name>" from the real block.
tx_block_info() {
  local txid="$1" js idx num code
  js="$(mktemp --suffix .json)"
  fetch_block_by_txid "$txid" "$js"
  num="$(jq -r '.header.number' "$js")"
  idx="$(jq -r --arg t "$txid" '[.data.data[].payload.header.channel_header.tx_id] | index($t)' "$js")"
  code="$(jq -r '.metadata.metadata[2]' "$js" | base64 -d | od -An -tu1 -v | tr -s ' ' '\n' | sed '/^$/d' | sed -n "$((idx + 1))p")"
  rm -f "$js"
  echo "$num $idx $(validation_code_name "$code")"
}

validation_code_name() {
  case "$1" in
    0) echo VALID ;; 1) echo NIL_ENVELOPE ;; 2) echo BAD_PAYLOAD ;; 3) echo BAD_COMMON_HEADER ;;
    4) echo BAD_CREATOR_SIGNATURE ;; 5) echo INVALID_ENDORSER_TRANSACTION ;; 6) echo INVALID_CONFIG_TRANSACTION ;;
    7) echo UNSUPPORTED_TX_PAYLOAD ;; 8) echo BAD_PROPOSAL_TXID ;; 9) echo DUPLICATE_TXID ;;
    10) echo ENDORSEMENT_POLICY_FAILURE ;; 11) echo MVCC_READ_CONFLICT ;; 12) echo PHANTOM_READ_CONFLICT ;;
    *) echo "CODE_$1" ;;
  esac
}

# record_tx <csv> <n> <function> <args> — append a row with the real block number / code.
record_tx() {
  local csv="$1" n="$2" fn="$3" args="$4" blk="-" code="${TX_STATUS:-}"
  if [[ -n "${TXID:-}" && "$TX_STATUS" != "REJECTED_AT_ENDORSEMENT" ]]; then
    read -r blk _ code < <(tx_block_info "$TXID")
  fi
  [[ -f "$csv" ]] || echo "n,function,args,invoker,txid,block,validation_code" >"$csv"
  sed -i "/^${n},/d" "$csv"
  # args: JSON array -> "a; b; c" (no commas, no quotes) so the CSV stays trivially parseable
  local a="${args//\"/}"; a="${a#[}"; a="${a%]}"; a="${a//,/; }"
  echo "${n},${fn},${a},${CORE_PEER_LOCALMSPID}/${ORG_USER},${TXID:--},${blk},${code}" >>"$csv"
  TX_BLOCK="$blk"
}

# csv_field <csv> <n> <txid|block|code> — read a txids.csv column counting from the end
# (the quoted args column may contain commas).
csv_field() {
  local csv="$1" n="$2" col="$3" off
  case "$col" in txid) off=2 ;; block) off=1 ;; code) off=0 ;; esac
  awk -F, -v n="$n" -v o="$off" '$1 == n {print $(NF - o)}' "$csv"
}

# show_tx — print a one-line verdict for the last invoke.
show_tx() {
  local label="$1"
  if [[ "$TX_STATUS" == "VALID" ]]; then
    ok "$label → committed with status (VALID)  TxID=${TXID}"
  else
    fail "$label → ${TX_STATUS:-UNKNOWN}"
    grep -E 'Error|error' <<<"$TX_OUT" | head -3 | sed 's/^/      /'
  fi
}

# expect_reject <label> <pattern> — the last invoke must have been rejected with <pattern>.
expect_reject() {
  local label="$1" pat="$2"
  if [[ "$TX_STATUS" != "VALID" ]] && grep -q -- "$pat" <<<"$TX_OUT"; then
    ok "$label → отклонено, как и ожидалось: $(grep -oE -- "${pat}[^\"]{0,90}" <<<"$TX_OUT" | head -1)"
  else
    fail "$label → ожидался отказ с '$pat', фактически: ${TX_STATUS:-?}"
    echo "$TX_OUT" | tail -3 | sed 's/^/      /'
  fi
}
