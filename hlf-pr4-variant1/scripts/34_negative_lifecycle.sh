#!/usr/bin/env bash
# Task 3.4 (control question 4) — negative lifecycle demonstrations, run after both approvals of
# payment 2.0 / sequence 2 and BEFORE commit:
#   1) approve with --sequence 3 -> rejected (sequence must grow by exactly 1);
#   2) checkcommitreadiness with a different policy / without the policy -> approvals do not match.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
use_org 1
start_log task3 34_negative_lifecycle
PKG_ID="$(cat "$ROOT/build/payment_2.0.packageid")"
AND="AND('Org1MSP.peer','Org2MSP.peer')"
ORD=(-o "$ORDERER_ADDR" --ordererTLSHostnameOverride "$ORDERER_HOST" --tls --cafile "$ORDERER_CA")

step "Текущее определение и ожидание следующего sequence"
cur="$(peer lifecycle chaincode querycommitted -C "$CHANNEL" -n payment --output json 2>/dev/null | jq -r .sequence)"
echo "  зафиксирован sequence = $cur → следующий допустимый = $((cur + 1))"

step "1. approveformyorg с --sequence 3 (пропуск номера)"
printf '%s$ peer lifecycle chaincode approveformyorg ... --name payment --version 2.0 --sequence 3 --package-id %s --signature-policy "%s"%s\n' "$C_D" "$PKG_ID" "$AND" "$C_0"
out="$(peer lifecycle chaincode approveformyorg "${ORD[@]}" --channelID "$CHANNEL" --name payment --version 2.0 \
  --sequence 3 --package-id "$PKG_ID" --signature-policy "$AND" 2>&1 || true)"
grep -E 'Error|error' <<<"$out" | sed 's/^/  /'
grep -qiE 'sequence|must be' <<<"$out" && ok "approve с sequence 3 отклонён: sequence растёт ровно на 1 (ожидается $((cur + 1)))" || fail "approve seq 3 не был отклонён"

step "2. checkcommitreadiness с ДРУГОЙ политикой — OR('Org1MSP.peer','Org2MSP.peer')"
run peer lifecycle chaincode checkcommitreadiness --channelID "$CHANNEL" --name payment --version 2.0 --sequence 2 \
  --signature-policy "OR('Org1MSP.peer','Org2MSP.peer')" --output json
r="$(peer lifecycle chaincode checkcommitreadiness --channelID "$CHANNEL" --name payment --version 2.0 --sequence 2 \
  --signature-policy "OR('Org1MSP.peer','Org2MSP.peer')" --output json 2>/dev/null)"
[[ "$(jq -r '[.approvals[]] | any' <<<"$r")" == false ]] && ok "с политикой OR ни одна организация не утверждала такое определение (Org1MSP: false, Org2MSP: false)"

step "3. checkcommitreadiness БЕЗ --signature-policy (политика по умолчанию — /Channel/Application/Endorsement, MAJORITY)"
run peer lifecycle chaincode checkcommitreadiness --channelID "$CHANNEL" --name payment --version 2.0 --sequence 2 --output json
r="$(peer lifecycle chaincode checkcommitreadiness --channelID "$CHANNEL" --name payment --version 2.0 --sequence 2 --output json 2>/dev/null)"
[[ "$(jq -r '[.approvals[]] | any' <<<"$r")" == false ]] && ok "без явной политики определение другое → approvals false: пропуск флага молча сменил бы модель доверия"

step "4. Контроль: та же команда с исходной AND-политикой"
run peer lifecycle chaincode checkcommitreadiness --channelID "$CHANNEL" --name payment --version 2.0 --sequence 2 \
  --signature-policy "$AND" --output json
r="$(peer lifecycle chaincode checkcommitreadiness --channelID "$CHANNEL" --name payment --version 2.0 --sequence 2 --signature-policy "$AND" --output json 2>/dev/null)"
[[ "$(jq -r '[.approvals[]] | all' <<<"$r")" == true ]] && ok "с AND-политикой: Org1MSP: true, Org2MSP: true — готово к commit"
summary
