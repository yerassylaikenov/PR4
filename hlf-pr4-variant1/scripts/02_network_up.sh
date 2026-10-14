#!/usr/bin/env bash
# Step 3 (task 1.1) — bring up test-network: 2 orgs, Fabric CA, CouchDB, channel "paymentchannel".
# Org1 = Sender Bank (Org1MSP), Org2 = Receiver Bank (Org2MSP).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
start_log task1 02_network_up

step "Задание 1.1 — корпоративная сеть Hyperledger Fabric"
cd "$TEST_NETWORK"
if docker ps --format '{{.Names}}' | grep -q '^peer0.org1.example.com$' \
   && docker exec peer0.org1.example.com peer channel list 2>/dev/null | grep -q "^$CHANNEL$"; then
  info "Сеть уже запущена и канал $CHANNEL существует — пропуск network.sh up (идемпотентность)"
else
  run ./network.sh up createChannel -c "$CHANNEL" -ca -s couchdb
fi

step "Контейнеры сети"
run docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}' --filter label=service
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' | grep -E 'NAMES|peer0|orderer|ca_|couchdb'
for c in peer0.org1.example.com peer0.org2.example.com orderer.example.com ca_org1 ca_org2 ca_orderer couchdb0 couchdb1; do
  docker ps --format '{{.Names}}' | grep -qx "$c" && ok "контейнер $c запущен" || fail "контейнер $c не найден"
done

step "Канал $CHANNEL с точки зрения каждой организации"
for org in 1 2; do
  use_org "$org"
  log_identity
  run peer channel list
  peer channel list 2>/dev/null | grep -qx "$CHANNEL" && ok "Org${org}MSP: peer0.org${org} присоединён к $CHANNEL" || fail "Org${org}: канал не найден"
done
use_org 1
run peer channel getinfo -c "$CHANNEL"

step "Ordering Service знает канал (Channel Participation API, osnadmin)"
run osnadmin channel list -o localhost:7053 --ca-file "$ORDERER_CA" \
  --client-cert "$ORDERER_ADMIN_TLS_SIGN_CERT" --client-key "$ORDERER_ADMIN_TLS_PRIVATE_KEY"
osnadmin channel list -o localhost:7053 --ca-file "$ORDERER_CA" \
  --client-cert "$ORDERER_ADMIN_TLS_SIGN_CERT" --client-key "$ORDERER_ADMIN_TLS_PRIVATE_KEY" 2>/dev/null \
  | grep -q "\"$CHANNEL\"" && ok "orderer.example.com обслуживает канал $CHANNEL" || fail "orderer не знает канал"

step "Соответствие ролей варианта 1"
printf '  %-10s %-12s %-28s %s\n' "Org" "MSP ID" "Домен test-network" "Роль"
printf '  %-10s %-12s %-28s %s\n' "Org1" "Org1MSP" "org1.example.com" "Банк-отправитель (Sender Bank)"
printf '  %-10s %-12s %-28s %s\n' "Org2" "Org2MSP" "org2.example.com" "Банк-получатель (Receiver Bank)"
printf '  %-10s %-12s %-28s %s\n' "Orderer" "OrdererMSP" "example.com" "Ordering Service (Raft)"
summary
