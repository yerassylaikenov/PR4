#!/usr/bin/env bash
# Task 3.7 — separate Fabric 3.1.5 stand with SmartBFT ordering (4 orderers), channel "bftchannel".
# Requires the main network to be stopped (same container names / ports) — confirmed by the user;
# the main network is backed up (scripts/38_backup_volumes.sh) and restored by scripts/40_restore_main.sh.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
export CHANNEL=bftchannel
start_log task3/bft 39_bft_up
cd "$TEST_NETWORK"

step "Остановка основной сети (подтверждено пользователем; бэкап: backup/$(cat "$ROOT/backup/LATEST" 2>/dev/null))"
if docker ps --format '{{.Names}}' | grep -q '^orderer2.example.com$'; then
  info "стенд BFT уже запущен — пропуск"
else
  run ./network.sh down
  step "Подъём стенда: ./network.sh up createChannel -bft -c bftchannel -ca -s couchdb"
  # -bft is compatible with -ca (registerEnroll.sh enrols orderer..orderer4) and -s couchdb (compose-couch.yaml)
  run ./network.sh up createChannel -bft -c bftchannel -ca -s couchdb
fi

step "Контейнеры стенда"
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' | grep -E 'NAMES|orderer|peer0|ca_|couch'
for o in orderer orderer2 orderer3 orderer4; do
  docker ps --format '{{.Names}}' | grep -qx "$o.example.com" && ok "$o.example.com запущен" || fail "$o.example.com"
done
use_org 1
peer channel list 2>/dev/null | grep -qx bftchannel && ok "peer0.org1 присоединён к bftchannel"
use_org 2
peer channel list 2>/dev/null | grep -qx bftchannel && ok "peer0.org2 присоединён к bftchannel"
summary
