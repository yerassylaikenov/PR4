#!/usr/bin/env bash
# Restore the main network (paymentchannel) from the encrypted backup made by 38_backup_volumes.sh:
# same crypto material, same ledgers, same TxIDs. Used after the SmartBFT stand (task 3.7) — also a practical
# proof of the "Backup" stage of the Fabric upgrade plan (restorability).
# Usage: scripts/40_restore_main.sh [backup-timestamp]   (default: backup/LATEST)
set -euo pipefail
source "$(dirname "$0")/lib.sh"
TS="${1:-$(cat "$ROOT/backup/LATEST")}"
BK="$ROOT/backup/$TS"; KEY="$ROOT/.secrets/backup.key"
start_log task3 40_restore_main
cd "$TEST_NETWORK"
export DOCKER_SOCK=/var/run/docker.sock
COMPOSE=(docker compose -f compose/compose-test-net.yaml -f compose/docker/docker-compose-test-net.yaml -f compose/compose-couch.yaml)

step "1. Остановка стенда SmartBFT (если запущен)"
if docker ps -a --format '{{.Names}}' | grep -q '^orderer2.example.com$'; then
  run ./network.sh down
else
  info "стенд BFT не запущен"
fi
docker ps -a --format '{{.Names}}' | grep -qE '^peer0.org1.example.com$' && die "основная сеть уже существует — восстановление не требуется"

dec() { openssl enc -d -aes-256-cbc -pbkdf2 -pass "file:$KEY" -in "$BK/$1.tgz.enc"; }
step "2. Проверка целостности бэкапа $TS (sha256 зашифрованных файлов)"
(cd "$BK" && sha256sum -c SHA256SUMS.enc) | sed 's/^/  /'
ok "контрольные суммы бэкапа совпадают"

step "3. MSP / TLS / Fabric CA и channel-artifacts"
rm -rf organizations channel-artifacts
dec organizations | tar xzf - -C "$TEST_NETWORK"
dec channel-artifacts | tar xzf - -C "$TEST_NETWORK"
ok "organizations/ восстановлен ($(find organizations -name '*.pem' | wc -l) сертификатов; ключи не выводятся)"

step "4. Fabric CA"
docker compose -f compose/compose-ca.yaml up -d 2>&1 | tail -3
ok "ca_org1, ca_org2, ca_orderer запущены с восстановленными БД"

step "5. Создание контейнеров без запуска (docker compose create) и восстановление данных"
"${COMPOSE[@]}" create 2>&1 | tail -3
restore_vol() { # <archive> <docker mount args...> <extract-dir>
  local a="$1"; shift; local dir="${*: -1}"; set -- "${@:1:$#-1}"
  dec "$a" | docker run --rm -i "$@" alpine:3.20 sh -c "rm -rf ${dir:?}/* && tar xzf - -C $(dirname "$dir")"
  ok "$a → восстановлен"
}
restore_vol couchdb0 --volumes-from couchdb0 /opt/couchdb/data
restore_vol couchdb1 --volumes-from couchdb1 /opt/couchdb/data
restore_vol orderer.example.com -v compose_orderer.example.com:/var/hyperledger/production/orderer /var/hyperledger/production/orderer
restore_vol peer0.org1.example.com -v compose_peer0.org1.example.com:/var/hyperledger/production /var/hyperledger/production
restore_vol peer0.org2.example.com -v compose_peer0.org2.example.com:/var/hyperledger/production /var/hyperledger/production

step "6. Запуск: CouchDB → orderer → peers"
run docker start couchdb0 couchdb1
sleep 5
run docker start orderer.example.com
sleep 3
run docker start peer0.org1.example.com peer0.org2.example.com
use_org 1
for i in $(seq 1 40); do peer channel getinfo -c paymentchannel >/dev/null 2>&1 && break; sleep 3; done
CHANNEL=paymentchannel

step "7. Проверка восстановления"
run peer channel getinfo -c "$CHANNEL"
info_now="$(peer channel getinfo -c "$CHANNEL" 2>/dev/null | sed 's/^Blockchain info: //')"
verify_vs_backup() {
  local line hb cb
  line="$(grep -m1 'Состояние до бэкапа' "$EVIDENCE/task3/38_backup.log")"
  hb="$(sed -E 's/.*высота ([0-9]+).*/\1/' <<<"$line")"; cb="$(sed -E 's/.*currentBlockHash ([^ ]+).*/\1/' <<<"$line")"
  echo "  в момент бэкапа: height=$hb currentBlockHash=$cb"
  echo "  сейчас         : height=$(jq .height <<<"$info_now") currentBlockHash=$(jq -r .currentBlockHash <<<"$info_now")"
  [[ "$hb" == "$(jq .height <<<"$info_now")" && "$cb" == "$(jq -r .currentBlockHash <<<"$info_now")" ]] \
    && ok "высота и currentBlockHash совпадают с моментом бэкапа — ledger восстановлен без потерь" || fail "ledger отличается от бэкапа"
}
verify_vs_backup
[[ "${VERIFY_ONLY:-0}" == 1 ]] && { summary; exit 0; }
use_org 2
[[ "$(peer channel getinfo -c "$CHANNEL" 2>/dev/null | sed 's/^Blockchain info: //' | jq .height)" == "$(jq .height <<<"$info_now")" ]] && ok "peer0.org2 на той же высоте"
use_org 1
qc="$(peer lifecycle chaincode querycommitted -C "$CHANNEL" -n payment --output json 2>/dev/null)"
[[ "$(jq -r '"\(.version)/\(.sequence)"' <<<"$qc")" == "2.0/2" ]] && ok "payment: Version 2.0, Sequence 2 (определение восстановлено)"
st="$(cc_query payment '{"Args":["ReadPaymentOrder","PO-0001"]}' 2>/dev/null | jq -r .status)"
[[ "$st" == RETURNED ]] && ok "PO-0001 = RETURNED (состояние после Задания 3.6), контейнеры chaincode пересобраны"
use_org 1 initiator1
cc_query paymentsecure '{"Args":["ReadSettlementDetails","PO-S001"]}' --peer 1 2>/dev/null | jq -e '.payerIBAN' >/dev/null && ok "private data Org1 доступны (ReadSettlementDetails PO-S001; значения не выводятся)"
use_org 1
h="$(cc_query payment '{"Args":["GetPaymentOrderHistory","PO-0001"]}' 2>/dev/null | jq -r '.[].txId' | grep -c 6d535b17ed87353864ed5766a39ab25b8937223d857c2c80b5b81b7ba4e489ea || true)"
(( h == 1 )) && ok "история PO-0001 содержит исходный TxID T4 6d535b17… — это тот же ledger"
summary
