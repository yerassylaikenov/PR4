#!/usr/bin/env bash
# Step 2 — install the latest Fabric 3.1.x and Fabric CA 1.5.x (versions resolved via GitHub Releases API).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
start_log task1 01_versions

step "Шаг 2. Определение последних версий через GitHub Releases API"
FABRIC_VERSION="$(curl -fsSL 'https://api.github.com/repos/hyperledger/fabric/releases?per_page=50' \
  | jq -r '.[] | select(.prerelease == false) | .tag_name' | grep -E '^v3\.1\.[0-9]+$' | sort -V | tail -1 | sed 's/^v//')"
CA_VERSION="$(curl -fsSL 'https://api.github.com/repos/hyperledger/fabric-ca/releases?per_page=50' \
  | jq -r '.[] | select(.prerelease == false) | .tag_name' | grep -E '^v1\.5\.[0-9]+$' | sort -V | tail -1 | sed 's/^v//')"
ok "Fabric 3.1.x latest: $FABRIC_VERSION"
ok "Fabric CA 1.5.x latest: $CA_VERSION"
echo "FABRIC_VERSION=$FABRIC_VERSION" >"$ROOT/.versions"
echo "CA_VERSION=$CA_VERSION" >>"$ROOT/.versions"

step "Установка: install-fabric.sh docker samples binary"
cd "$ROOT"
if [[ ! -x "$FABRIC_SAMPLES/bin/peer" ]] || ! "$FABRIC_SAMPLES/bin/peer" version | grep -q "Version: v\?$FABRIC_VERSION"; then
  curl -fsSLo install-fabric.sh https://raw.githubusercontent.com/hyperledger/fabric/main/scripts/install-fabric.sh
  chmod +x install-fabric.sh
  ./install-fabric.sh --fabric-version "$FABRIC_VERSION" --ca-version "$CA_VERSION" docker samples binary
  rm -f install-fabric.sh
else
  info "Fabric $FABRIC_VERSION уже установлен — пропуск (идемпотентность)"
fi

step "Проверка версий"
run peer version
run orderer version
run fabric-ca-client version
run configtxlator version
run osnadmin --help >/dev/null && ok "osnadmin доступен"
echo
run docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.Size}}' | grep -E 'REPOSITORY|hyperledger' || true
peer version | grep -q "Version: v\?$FABRIC_VERSION" && ok "peer $FABRIC_VERSION" || fail "peer version mismatch"
fabric-ca-client version | grep -q "Version: v\?$CA_VERSION" && ok "fabric-ca-client $CA_VERSION" || fail "CA version mismatch"
docker image inspect "hyperledger/fabric-peer:$FABRIC_VERSION" >/dev/null 2>&1 && ok "образ fabric-peer:$FABRIC_VERSION" || fail "нет образа fabric-peer"
docker image inspect "hyperledger/fabric-orderer:$FABRIC_VERSION" >/dev/null 2>&1 && ok "образ fabric-orderer:$FABRIC_VERSION" || fail "нет образа fabric-orderer"
docker image inspect "hyperledger/fabric-ca:$CA_VERSION" >/dev/null 2>&1 && ok "образ fabric-ca:$CA_VERSION" || fail "нет образа fabric-ca"
summary
