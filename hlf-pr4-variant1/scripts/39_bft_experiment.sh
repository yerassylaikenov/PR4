#!/usr/bin/env bash
# Task 3.7 — SmartBFT fault experiment on bftchannel (n = 4, f = 1, quorum 3):
#   E1 baseline -> E2 stop a non-leader (orderer4) -> E3 control tx with n-1 -> E4 restart + catch-up + tx
#   -> E5 stop the LEADER (view change) + tx -> E6 restore -> E7 stop two orderers (> f, no quorum) + tx
#   -> E8 restore both -> tx. Every height is read live (osnadmin on each orderer, getinfo on each peer).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
export CHANNEL=bftchannel
use_org 1
start_log task3/bft 39_bft_experiment
ORGS="$TEST_NETWORK/organizations/ordererOrganizations/example.com/orderers"
MD="$EVIDENCE/task3/bft/experiment.md"
CSV="$EVIDENCE/task3/bft/txids.csv"
rm -f "$CSV"
declare -A LISTEN=([orderer]=7050 [orderer2]=7052 [orderer3]=7056 [orderer4]=7058)
declare -A ADMIN=([orderer]=7053 [orderer2]=7055 [orderer3]=7057 [orderer4]=7059)
ALL=(orderer orderer2 orderer3 orderer4)
ROWS=()

alive() { docker ps --format '{{.Names}}' | grep -qx "$1.example.com"; }
osn_height() {
  local o="$1"
  alive "$o" || { echo "—"; return; }
  osnadmin channel list --channelID "$CHANNEL" -o "localhost:${ADMIN[$o]}" --ca-file "$ORDERER_CA" \
    --client-cert "$ORGS/$o.example.com/tls/server.crt" --client-key "$ORGS/$o.example.com/tls/server.key" 2>/dev/null \
    | sed -n '/^{/,$p' | jq -r '.height // "?"' 2>/dev/null || echo "?"
}
peer_height() { (use_org "$1"; peer channel getinfo -c "$CHANNEL" 2>/dev/null | sed 's/^Blockchain info: //' | jq -r .height); }
heights() {
  HROW=""
  for o in "${ALL[@]}"; do HROW+="$o=$(osn_height "$o") "; done
  HROW+="peer0.org1=$(peer_height 1) peer0.org2=$(peer_height 2)"
  echo "  высоты: $HROW"
}
live_list() { local l=(); for o in "${ALL[@]}"; do alive "$o" && l+=("$o"); done; echo "${l[*]}"; }
leader() { # most recent ChangeRole line among live orderers
  for o in $(live_list); do
    docker logs -t "$o.example.com" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep 'ChangeRole ->' | tail -1 \
      | sed -E "s/^([^ ]+) .*current view: ([0-9]+), current leader: ([0-9]+).*/\1 \2 \3/"
  done | sort | tail -1 | awk '{print "view=" $2 " leader=" $3}'
}
tx() { # tx <step> <via-orderer> [wait]
  local stepid="$1" via="$2" id="PO-BFT-$1-$(date +%H%M%S)"
  export ORDERER_ADDR="localhost:${LISTEN[$via]}" ORDERER_HOST="$via.example.com"
  local t0; t0="$(date +%s.%N)"
  TX_WAIT="${3:-60s}" cc_invoke payment "{\"function\":\"CreatePaymentOrder\",\"Args\":[\"$id\",\"Org2MSP\",\"100000\",\"KZT\",\"119\",\"BFT $stepid\"]}" || true
  TX_SECS="$(awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN{printf "%.1f", b-a}')"
  TX_ID="$id"
  record_tx "$CSV" "$stepid" "CreatePaymentOrder via $via" "[\"$id\"]"
  if [[ "$TX_STATUS" == VALID ]]; then ok "$stepid: транзакция через $via → VALID за ${TX_SECS} c, блок $TX_BLOCK, TxID=$TXID"
  else info "$stepid: транзакция через $via → ${TX_STATUS:-нет статуса} за ${TX_SECS} c"; grep -E 'Error|timed out|deadline' <<<"$TX_OUT" | head -2 | sed 's/^/      /'; fi
}
wait_height() { # wait until every live orderer and both peers reach height >= $1 (max 90 s)
  local want="$1" i
  for i in $(seq 1 45); do
    local okall=1
    for o in $(live_list); do h="$(osn_height "$o")"; [[ "$h" =~ ^[0-9]+$ ]] && (( h >= want )) || okall=0; done
    (( $(peer_height 1) >= want && $(peer_height 2) >= want )) || okall=0
    (( okall )) && return 0; sleep 2
  done
  return 1
}
row() { ROWS+=("| $1 | $2 | $3 | $4 | $5 | ${6:--} | $7 |"); }
utc_now() { date -u '+%Y-%m-%d %H:%M:%S'; }
logs_since() { # <orderer> <utc 'YYYY-mm-dd HH:MM:SS'> <regex> <n> — orderer log lines after a moment
  docker logs "$1.example.com" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -v CERTIFICATE \
    | awk -v t="$2" 'substr($0,1,19) >= t' | grep -E "$3" | cut -c1-200 | tail -"${4:-2}" | sed "s/^/    [$1] /"
}

step "Исходное состояние: $(leader), живые: $(live_list)"
heights
LEADER_ID="$(leader | sed -E 's/.*leader=([0-9]+)/\1/')"
LEADER_NAME="${ALL[$((LEADER_ID - 1))]}"
VICTIM=orderer4; [[ "$LEADER_NAME" == orderer4 ]] && VICTIM=orderer3
info "лидер: id $LEADER_ID ($LEADER_NAME.example.com); для отказа выбран не-лидер: $VICTIM.example.com"

step "E1. Базовая линия — 4 из 4 orderer"
tx E1 orderer
wait_height "$(( TX_BLOCK + 1 ))" && heights
H="$(peer_height 1)"
row E1 "базовая транзакция" "4/4" "да (4 ≥ 3)" "$TX_STATUS" "\`${TXID:0:16}…\`" "$HROW"
ok "все 4 orderer и оба peer на высоте H = $H"

step "E2. Контролируемый отказ: docker stop $VICTIM.example.com (не лидер) — $(date '+%H:%M:%S')"
T_STOP="$(utc_now)"
run docker stop "$VICTIM.example.com"
heights
row E2 "docker stop $VICTIM (не лидер), $(date '+%H:%M:%S')" "3/4" "да (3 ≥ 3)" "—" - "$HROW"

step "E3. Контрольная транзакция при n − 1 (через живой orderer.example.com)"
tx E3 orderer
wait_height "$(( H + 1 ))" && heights
row E3 "контрольная транзакция при отказе 1 узла" "3/4" "да" "$TX_STATUS" "\`${TXID:0:16}…\`" "$HROW"
[[ "$TX_STATUS" == VALID && "$(peer_height 1)" == "$((H + 1))" ]] && ok "высота H+1 = $((H + 1)) на 3 живых orderer и обоих peers — консенсус продолжается"
echo "  логи живых orderer после остановки $VICTIM (фрагмент):"
for o in $(live_list); do logs_since "$o" "$T_STOP" "${VICTIM}|${LISTEN[$VICTIM]}" 1; done

step "E4. Восстановление: docker start $VICTIM.example.com → catch-up"
run docker start "$VICTIM.example.com"
t0="$(date +%s)"
for i in $(seq 1 15); do [[ "$(osn_height "$VICTIM")" == "$((H + 1))" ]] && break; sleep 2; done
vh="$(osn_height "$VICTIM")"
if [[ "$vh" == "$((H + 1))" ]]; then
  ok "$VICTIM догнал остальные узлы до H+1 = $vh за $(( $(date +%s) - t0 )) c"
else
  info "через $(( $(date +%s) - t0 )) c высота $VICTIM = $vh (H+1 = $((H + 1))): SmartBFT-узел синхронизируется при следующем раунде консенсуса (sync по detectTargetHeight)"
fi
heights
tx E4 orderer
wait_height "$(( H + 2 ))" && heights
row E4 "docker start $VICTIM, catch-up, транзакция" "4/4" "да" "$TX_STATUS" "\`${TXID:0:16}…\`" "$HROW"
[[ "$(osn_height "$VICTIM")" == "$((H + 2))" ]] && ok "catch-up завершён: все 4 orderer и оба peers на высоте H+2 = $((H + 2))"
logs_since "$VICTIM" "$(date -u -d "@$t0" '+%Y-%m-%d %H:%M:%S')" 'detectTargetHeight|Deliver -> Delivering|Synced' 2

step "E5. (доп.) Остановка ЛИДЕРА $LEADER_NAME.example.com → view change"
H5="$(peer_height 1)"
T_STOP="$(utc_now)"; t_stop="$(date +%s)"
run docker stop "$LEADER_NAME.example.com"
VIA=orderer2; [[ "$LEADER_NAME" == orderer2 ]] && VIA=orderer3
tx E5 "$VIA" 150s
echo "  время от остановки лидера до фиксации транзакции: $(( $(date +%s) - t_stop )) c"
echo "  view change в логах живых orderer:"
for o in $(live_list); do logs_since "$o" "$T_STOP" 'OnRequestTimeout|OnLeaderFwdRequestTimeout|ChangeRole|startView' 3; done
echo "  новый $(leader)"
wait_height "$(( H5 + 1 ))" && heights
row E5 "docker stop лидера ($LEADER_NAME) → view change, транзакция через $VIA" "3/4" "да" "$TX_STATUS ($TX_SECS c)" "\`${TXID:0:16}…\`" "$HROW"

step "E6. Восстановление бывшего лидера"
run docker start "$LEADER_NAME.example.com"
for i in $(seq 1 45); do [[ "$(osn_height "$LEADER_NAME")" == "$(peer_height 1)" ]] && break; sleep 2; done
heights
row E6 "docker start $LEADER_NAME, catch-up" "4/4" "да" "—" - "$HROW"
[[ "$(osn_height "$LEADER_NAME")" == "$(peer_height 1)" ]] && ok "$LEADER_NAME догнал канал; $(leader)"

step "E7. (доп.) Остановка ДВУХ orderer (> f = 1) → нет кворума 3 из 4"
CUR_LEADER="$(leader | sed -E 's/.*leader=([0-9]+)/\1/')"
DOWN=()
for o in orderer4 orderer3 orderer; do
  [[ "${ALL[$((CUR_LEADER - 1))]}" == "$o" ]] && continue
  DOWN+=("$o"); (( ${#DOWN[@]} == 2 )) && break
done
H7="$(peer_height 1)"
run docker stop "${DOWN[0]}.example.com" "${DOWN[1]}.example.com"
VIA="${ALL[$((CUR_LEADER - 1))]}"
tx E7 "$VIA" 40s
E7_TX="$TXID"; E7_ID="$TX_ID"
heights
[[ "$TX_STATUS" != VALID && "$(peer_height 1)" == "$H7" ]] && ok "без кворума транзакция не зафиксирована (${TX_STATUS:-нет статуса}), высота не изменилась ($H7)"
row E7 "docker stop ${DOWN[0]} + ${DOWN[1]} (2 > f), транзакция через $VIA" "2/4" "**нет** (2 < 3)" "${TX_STATUS:-нет блока} (ожидание ${TX_SECS} c)" "\`${E7_TX:0:16}…\`" "$HROW"

step "E8. Восстановление обоих узлов → кворум восстановлен"
run docker start "${DOWN[0]}.example.com" "${DOWN[1]}.example.com"
T_UP="$(utc_now)"
tx E8 orderer2 150s
wait_height "$(peer_height 1)" && heights
row E8 "docker start ${DOWN[0]} + ${DOWN[1]}, транзакция" "4/4" "да" "$TX_STATUS ($TX_SECS c)" "\`${TXID:0:16}…\`" "$HROW"
[[ "$TX_STATUS" == VALID ]] && ok "после восстановления кворума сеть снова обрабатывает транзакции"
for o in $(live_list); do logs_since "$o" "$T_UP" 'ChangeRole|Delivering proposal' 2; done
use_org 1
pend="$(cc_query payment "{\"Args\":[\"PaymentOrderExists\",\"$E7_ID\"]}" 2>/dev/null || echo false)"
E7_LATE=""
if [[ "$pend" == true ]]; then
  E7_LATE="$(cc_query payment "{\"Args\":[\"GetPaymentOrderHistory\",\"$E7_ID\"]}" 2>/dev/null | jq -r '.[0].txId')"
  read -r e7b _ e7c < <(tx_block_info "$E7_LATE")
  ok "транзакция E7 не потеряна: она оставалась в request pool и после восстановления кворума упорядочена в блок $e7b ($e7c), TxID=$E7_LATE"
else
  info "транзакция E7 ($E7_ID) так и не была упорядочена"
fi

step "Подписи блока SmartBFT (metadata[SIGNATURES]) — блок подписывает кворум"
W="$(mktemp -d)"; last=$(( $(peer_height 1) - 1 ))
fetch_block_by_number "$last" "$W/b.json"
jq -r '.metadata.metadata[0]' "$W/b.json" | base64 -d >"$W/m.pb"
configtxlator proto_decode --type common.Metadata --input "$W/m.pb" --output "$W/m.json"
nsig="$(jq '.signatures | length' "$W/m.json")"
echo "  блок #$last: подписей orderer в metadata = $nsig (в Raft-канале paymentchannel — 1)"
(( nsig >= 3 )) && ok "блок подписан $nsig consenter-ами ≥ кворума 3"
rm -rf "$W"

[[ -n "$E7_LATE" ]] && ROWS=("${ROWS[@]/| \`…\` |/| \`${E7_LATE:0:16}…\` (упорядочена после восстановления кворума, блок $e7b) |}")
{
  echo "# Эксперимент SmartBFT — bftchannel (n = 4, f = 1, кворум 3)"
  echo
  echo "Скрипт \`scripts/39_bft_experiment.sh\`, $(date '+%Y-%m-%d %H:%M:%S'). Высоты: \`osnadmin channel list\` на admin-порту каждого orderer и \`peer channel getinfo\` на каждом peer; «—» — узел остановлен."
  echo
  echo "| Шаг | Действие | Живые orderer | Кворум | Результат | TxID | Высоты |"
  echo "|---|---|---|---|---|---|---|"
  printf '%s\n' "${ROWS[@]}"
  echo
  echo "Транзакция E7 после восстановления кворума: \`PaymentOrderExists($E7_ID) = $pend\`${E7_LATE:+, упорядочена в блок $e7b ($e7c), TxID \`$E7_LATE\`}."
  echo "Блок #$last подписан $nsig orderer-ами (metadata SIGNATURES)."
} >"$MD"
step "Таблица эксперимента → evidence/task3/bft/experiment.md"
cat "$MD"
summary
