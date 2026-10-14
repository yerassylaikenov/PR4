#!/usr/bin/env bash
# Step 10 (optional, control question 1) — MVCC demo: SubmitPaymentOrder and CancelPaymentOrder on the
# same key PO-0005 sent in parallel. Both are endorsed against the same key version, both are ordered into
# one block, the validator accepts the first and marks the second MVCC_READ_CONFLICT.
# Idempotent: if the demo already ran, TxIDs and validation codes are recovered from the real blocks.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
use_org 1
start_log task1 10b_mvcc_demo
CSV="$EVIDENCE/task1/txids.csv"
KEY=PO-0005

step "MVCC: параллельные Submit и Cancel одного ключа $KEY"
status="$(cc_query payment "{\"Args\":[\"ReadPaymentOrder\",\"$KEY\"]}" 2>/dev/null | jq -r .status)"
echo "  состояние до демонстрации: $KEY = $status"
if [[ "$status" == "CREATED" ]]; then
  tmpd="$(mktemp -d)"
  ( cc_invoke payment "{\"function\":\"SubmitPaymentOrder\",\"Args\":[\"$KEY\"]}" || true; echo "$TX_OUT" >"$tmpd/m1" ) & p1=$!
  ( cc_invoke payment "{\"function\":\"CancelPaymentOrder\",\"Args\":[\"$KEY\"]}" || true; echo "$TX_OUT" >"$tmpd/m2" ) & p2=$!
  wait "$p1" "$p2"   # explicit PIDs: a bare `wait` would also wait for the logger's process substitution
  for m in m1 m2; do grep ClientWait "$tmpd/$m" | sed "s/^/  ${m^^}: /"; done
  rm -rf "$tmpd"
else
  info "демонстрация уже выполнялась — TxID и коды восстанавливаются из блоков"
fi

# Scan blocks after the creation of the key for Submit/Cancel transactions on it.
t8_block="$(csv_field "$CSV" T8 block)"
height="$(peer channel getinfo -c "$CHANNEL" 2>/dev/null | sed 's/^Blockchain info: //' | jq -r .height)"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
sed -i '/^M[12],/d' "$CSV"
for ((b = t8_block + 1; b < height; b++)); do
  # committed block from the peer ledger: carries TRANSACTIONS_FILTER (the orderer's copy does not)
  fetch_block_by_number "$b" "$W/b.json"
  mapfile -t codes < <(block_codes "$W/b.json")
  i=0
  while IFS=$'\t' read -r txid a0 a1 creator; do
    if [[ "$a1" == "$KEY" && ( "$a0" == SubmitPaymentOrder || "$a0" == CancelPaymentOrder ) ]]; then
      n=$([[ "$a0" == SubmitPaymentOrder ]] && echo M1 || echo M2)
      code="$(validation_code_name "${codes[$i]}")"
      echo "${n},${a0},$KEY,${creator}/Admin,${txid},${b},${code}" >>"$CSV"
      printf '  блок #%s  tx[%s]  %-20s %s  → %s\n' "$b" "$i" "$a0" "$txid" "$code"
    fi
    i=$((i + 1))
  done < <(jq -r '.data.data[].payload | [.header.channel_header.tx_id,
      (.data.actions[0].payload.chaincode_proposal_payload.input.chaincode_spec.input.args[0] | @base64d),
      (.data.actions[0].payload.chaincode_proposal_payload.input.chaincode_spec.input.args[1] // "" | @base64d),
      .header.signature_header.creator.mspid] | @tsv' "$W/b.json")
done

m1="$(grep '^M1,' "$CSV")"; m2="$(grep '^M2,' "$CSV")"
[[ -n "$m1" && -n "$m2" ]] || die "транзакции демонстрации не найдены в блоках"
[[ "$(cut -d, -f6 <<<"$m1")" == "$(cut -d, -f6 <<<"$m2")" ]] && ok "обе транзакции упорядочены в один блок #$(cut -d, -f6 <<<"$m1")"
codes="$(cut -d, -f7 <<<"$m1") $(cut -d, -f7 <<<"$m2")"
if [[ "$codes" == *VALID* && "$codes" == *MVCC_READ_CONFLICT* ]]; then
  ok "одна транзакция VALID, вторая MVCC_READ_CONFLICT ($codes)"
else
  fail "ожидались VALID + MVCC_READ_CONFLICT, получено: $codes"
fi
final="$(cc_query payment "{\"Args\":[\"ReadPaymentOrder\",\"$KEY\"]}" 2>/dev/null)"
winner="$(grep ',VALID$' <<<"$m1"$'\n'"$m2" | cut -d, -f5)"
loser="$(grep ',MVCC_READ_CONFLICT$' <<<"$m1"$'\n'"$m2" | cut -d, -f5)"
echo "  итоговое состояние: $KEY status=$(jq -r .status <<<"$final") lastTxId=$(jq -r .lastTxId <<<"$final")"
[[ "$(jq -r .lastTxId <<<"$final")" == "$winner" ]] && ok "World State отражает только VALID-транзакцию $winner"
[[ "$(jq -r .lastTxId <<<"$final")" != "$loser" ]] && ok "write-set MVCC_READ_CONFLICT-транзакции $loser не применён (но она хранится в блоке)"

step "Итоговая таблица TxID задания 1.5 (evidence/task1/txids.csv)"
column -t -s, "$CSV"
valid=$(grep -c ',VALID$' "$CSV")
(( valid >= 4 )) && ok "VALID-транзакций: $valid (требуется ≥ 4), одна из них через Gateway (T5)"
summary
