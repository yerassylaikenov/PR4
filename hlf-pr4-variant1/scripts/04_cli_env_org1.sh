#!/usr/bin/env bash
# Step 4 (task 1.2) — Fabric CLI environment and Org1 administrative identity.
# Proves that Admin@org1.example.com can work with the Peer and with the Ordering Service.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
use_org 1 Admin
start_log task1 04_cli_env_org1

step "Задание 1.2 — CLI-окружение Org1 (source scripts/env_org1.sh)"
echo "  CORE_PEER_TLS_ENABLED=$CORE_PEER_TLS_ENABLED"
echo "  CORE_PEER_LOCALMSPID=$CORE_PEER_LOCALMSPID"
echo "  CORE_PEER_ADDRESS=$CORE_PEER_ADDRESS"
echo "  CORE_PEER_MSPCONFIGPATH=.../peerOrganizations/org1.example.com/users/${ORG_USER}@org1.example.com/msp"
echo "  CORE_PEER_TLS_ROOTCERT_FILE=.../org1.example.com/tlsca/tlsca.org1.example.com-cert.pem"
echo "  ORDERER_CA=.../ordererOrganizations/example.com/tlsca/tlsca.example.com-cert.pem"
echo "  FABRIC_CFG_PATH=$FABRIC_CFG_PATH"
run peer version
peer version | grep -q 'Version: v3.1' && ok "peer CLI Fabric 3.1.x"

step "Работа с Peer (peer0.org1.example.com:7051)"
run peer channel list
peer channel list 2>/dev/null | grep -qx "$CHANNEL" && ok "Admin@org1 видит канал $CHANNEL на peer0.org1"
run peer channel getinfo -c "$CHANNEL"
peer channel getinfo -c "$CHANNEL" 2>/dev/null | grep -q height && ok "peer channel getinfo — доступ к ledger канала"

step "Работа с Ordering Service (orderer.example.com:7050)"
tmp="$(mktemp -d)"
run peer channel fetch config "$tmp/config_block.pb" -o "$ORDERER_ADDR" --ordererTLSHostnameOverride "$ORDERER_HOST" \
  -c "$CHANNEL" --tls --cafile "$ORDERER_CA"
configtxlator proto_decode --input "$tmp/config_block.pb" --type common.Block --output "$tmp/config_block.json"
cfg_num="$(jq -r .header.number "$tmp/config_block.json")"
ok "конфигурационный блок #$cfg_num получен от Ordering Service"
echo "  Организации канала (Application):  $(jq -r '.data.data[0].payload.data.config.channel_group.groups.Application.groups | keys | join(", ")' "$tmp/config_block.json")"
echo "  Организации Ordering Service:      $(jq -r '.data.data[0].payload.data.config.channel_group.groups.Orderer.groups | keys | join(", ")' "$tmp/config_block.json")"
echo "  ConsensusType:                     $(jq -r '.data.data[0].payload.data.config.channel_group.groups.Orderer.values.ConsensusType.value.type' "$tmp/config_block.json")"
echo "  Channel capabilities:              $(jq -r '.data.data[0].payload.data.config.channel_group.values.Capabilities.value.capabilities | keys | join(", ")' "$tmp/config_block.json")"
echo "  Application capabilities:          $(jq -r '.data.data[0].payload.data.config.channel_group.groups.Application.values.Capabilities.value.capabilities | keys | join(", ")' "$tmp/config_block.json")"
rm -rf "$tmp"

step "Административная идентичность Org1 (только subject / issuer / даты — без ключа и PEM)"
cert="$(ls "$CORE_PEER_MSPCONFIGPATH"/signcerts/*.pem | head -1)"
run openssl x509 -noout -subject -issuer -dates -in "$cert"
openssl x509 -noout -subject -in "$cert" | grep -q 'OU *= *admin' && ok "сертификат содержит OU=admin (NodeOU: роль администратора)" || fail "OU=admin не найден"
echo "  NodeOUs (msp/config.yaml):"
grep -E 'Enable|OrganizationalUnitIdentifier' "$CORE_PEER_MSPCONFIGPATH/config.yaml" | sed 's/^/    /'
grep -A2 'AdminOUIdentifier' "$CORE_PEER_MSPCONFIGPATH/config.yaml" | grep -q 'OrganizationalUnitIdentifier: admin' && ok "NodeOUs: AdminOUIdentifier = admin"
[[ -d "$CORE_PEER_MSPCONFIGPATH/keystore" ]] && ok "keystore/ присутствует (содержимое не выводится)"
summary
