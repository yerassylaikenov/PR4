#!/usr/bin/env bash
# CLI environment for Org2 (Receiver Bank). Usage: source scripts/env_org2.sh
# ORG_USER selects the identity: Admin (default), User1, processor2.
# Mirrors fabric-samples/test-network/scripts/envVar.sh (setGlobals 2).

_ENV_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_TN="$_ENV_ROOT/fabric-samples/test-network"
_ORGS="$_TN/organizations"

export PATH="$_ENV_ROOT/fabric-samples/bin:/usr/local/go/bin:$HOME/go/bin:$PATH"
export FABRIC_CFG_PATH="$_ENV_ROOT/fabric-samples/config"
export ORG_USER="${ORG_USER:-Admin}"
# keep CLI output readable: gRPC transport chatter only on errors
export FABRIC_LOGGING_SPEC="${FABRIC_LOGGING_SPEC:-grpc=error:info}"

export CORE_PEER_TLS_ENABLED=true
export CORE_PEER_LOCALMSPID=Org2MSP
export CORE_PEER_TLS_ROOTCERT_FILE="$_ORGS/peerOrganizations/org2.example.com/tlsca/tlsca.org2.example.com-cert.pem"
export CORE_PEER_MSPCONFIGPATH="$_ORGS/peerOrganizations/org2.example.com/users/${ORG_USER}@org2.example.com/msp"
export CORE_PEER_ADDRESS=localhost:9051

export PEER0_ORG1_CA="$_ORGS/peerOrganizations/org1.example.com/tlsca/tlsca.org1.example.com-cert.pem"
export PEER0_ORG2_CA="$_ORGS/peerOrganizations/org2.example.com/tlsca/tlsca.org2.example.com-cert.pem"
export ORDERER_CA="$_ORGS/ordererOrganizations/example.com/tlsca/tlsca.example.com-cert.pem"
export ORDERER_ADMIN_TLS_SIGN_CERT="$_ORGS/ordererOrganizations/example.com/orderers/orderer.example.com/tls/server.crt"
export ORDERER_ADMIN_TLS_PRIVATE_KEY="$_ORGS/ordererOrganizations/example.com/orderers/orderer.example.com/tls/server.key"

unset _ENV_ROOT _TN _ORGS
