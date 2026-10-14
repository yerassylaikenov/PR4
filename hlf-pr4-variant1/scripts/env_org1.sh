#!/usr/bin/env bash
# CLI environment for Org1 (Sender Bank). Usage: source scripts/env_org1.sh
# ORG_USER selects the identity: Admin (default), User1, initiator1, approver1, norole1.
# Mirrors fabric-samples/test-network/scripts/envVar.sh (setGlobals 1).

_ENV_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_TN="$_ENV_ROOT/fabric-samples/test-network"
_ORGS="$_TN/organizations"

export PATH="$_ENV_ROOT/fabric-samples/bin:/usr/local/go/bin:$HOME/go/bin:$PATH"
export FABRIC_CFG_PATH="$_ENV_ROOT/fabric-samples/config"
export ORG_USER="${ORG_USER:-Admin}"
# keep CLI output readable: gRPC transport chatter only on errors
export FABRIC_LOGGING_SPEC="${FABRIC_LOGGING_SPEC:-grpc=error:info}"

export CORE_PEER_TLS_ENABLED=true
export CORE_PEER_LOCALMSPID=Org1MSP
export CORE_PEER_TLS_ROOTCERT_FILE="$_ORGS/peerOrganizations/org1.example.com/tlsca/tlsca.org1.example.com-cert.pem"
export CORE_PEER_MSPCONFIGPATH="$_ORGS/peerOrganizations/org1.example.com/users/${ORG_USER}@org1.example.com/msp"
export CORE_PEER_ADDRESS=localhost:7051

# TLS roots of both peers (for --peerAddresses) and of the ordering service
export PEER0_ORG1_CA="$_ORGS/peerOrganizations/org1.example.com/tlsca/tlsca.org1.example.com-cert.pem"
export PEER0_ORG2_CA="$_ORGS/peerOrganizations/org2.example.com/tlsca/tlsca.org2.example.com-cert.pem"
export ORDERER_CA="$_ORGS/ordererOrganizations/example.com/tlsca/tlsca.example.com-cert.pem"
# Orderer admin TLS client pair for osnadmin (Channel Participation API, port 7053)
export ORDERER_ADMIN_TLS_SIGN_CERT="$_ORGS/ordererOrganizations/example.com/orderers/orderer.example.com/tls/server.crt"
export ORDERER_ADMIN_TLS_PRIVATE_KEY="$_ORGS/ordererOrganizations/example.com/orderers/orderer.example.com/tls/server.key"

unset _ENV_ROOT _TN _ORGS
