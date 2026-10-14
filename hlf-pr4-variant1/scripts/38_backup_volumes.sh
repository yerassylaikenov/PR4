#!/usr/bin/env bash
# Task 3.6 (Backup stage, practical) — consistent backup of the main network before stopping it:
#   stop nodes -> CouchDB first, then ledgers -> sha256 -> AES-256 encryption (archives contain MSP keys and
#   private data) -> restart -> verify height unchanged -> restorability check (decrypt + checksum).
# Output: backup/<timestamp>/ (git-ignored, 0700), key in .secrets/backup.key (0600).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
use_org 1
start_log task3 38_backup
TS="$(date +%Y%m%d-%H%M%S)"
BK="$ROOT/backup/$TS"; mkdir -p "$BK"; chmod 700 "$ROOT/backup" "$BK"
KEY="$ROOT/.secrets/backup.key"
[[ -f "$KEY" ]] || { openssl rand -hex 32 >"$KEY"; chmod 600 "$KEY"; }

H0="$(peer channel getinfo -c "$CHANNEL" 2>/dev/null | sed 's/^Blockchain info: //')"
step "Состояние до бэкапа: высота $(jq .height <<<"$H0"), currentBlockHash $(jq -r .currentBlockHash <<<"$H0")"

step "1. Останов узлов (peer → orderer → CouchDB)"
NODES=(peer0.org1.example.com peer0.org2.example.com orderer.example.com couchdb0 couchdb1)
run docker stop "${NODES[@]}"
ok "узлы остановлены — файлы ledger и CouchDB консистентны"

archive() { # <name> <docker run mount args...> <dir-in-container>
  local name="$1"; shift; local dir="${*: -1}"; set -- "${@:1:$#-1}"
  docker run --rm "$@" -v "$BK:/backup" alpine:3.20 sh -c "tar czf /backup/$name.tgz -C $(dirname "$dir") $(basename "$dir")" >/dev/null
  openssl enc -aes-256-cbc -pbkdf2 -salt -pass "file:$KEY" -in "$BK/$name.tgz" -out "$BK/$name.tgz.enc"
  sha256sum "$BK/$name.tgz" | sed "s#$BK/##" >>"$BK/SHA256SUMS.plain"
  rm -f "$BK/$name.tgz"
  ok "$name: $(du -h "$BK/$name.tgz.enc" | cut -f1) (зашифровано AES-256-CBC/PBKDF2)"
}
step "2. CouchDB (бэкап CouchDB старше бэкапа peer — требование документации)"
archive couchdb0 --volumes-from couchdb0 /opt/couchdb/data
archive couchdb1 --volumes-from couchdb1 /opt/couchdb/data
step "3. Ledger orderer и peers (/var/hyperledger/production)"
archive orderer.example.com -v compose_orderer.example.com:/var/hyperledger/production/orderer /var/hyperledger/production/orderer
archive peer0.org1.example.com -v compose_peer0.org1.example.com:/var/hyperledger/production /var/hyperledger/production
archive peer0.org2.example.com -v compose_peer0.org2.example.com:/var/hyperledger/production /var/hyperledger/production
step "4. MSP / TLS / Fabric CA (organizations/), channel-artifacts"
archive organizations -v "$TEST_NETWORK:/tn:ro" /tn/organizations
archive channel-artifacts -v "$TEST_NETWORK:/tn:ro" /tn/channel-artifacts
(cd "$BK" && sha256sum ./*.tgz.enc >SHA256SUMS.enc)

step "5. Запуск узлов (CouchDB → orderer → peers)"
run docker start couchdb0 couchdb1 orderer.example.com peer0.org1.example.com peer0.org2.example.com
for i in $(seq 1 30); do peer channel getinfo -c "$CHANNEL" >/dev/null 2>&1 && break; sleep 2; done
H1="$(peer channel getinfo -c "$CHANNEL" 2>/dev/null | sed 's/^Blockchain info: //')"
[[ "$(jq -c . <<<"$H0")" == "$(jq -c . <<<"$H1")" ]] && ok "после рестарта высота и currentBlockHash не изменились ($(jq .height <<<"$H1"))" || fail "ledger изменился"
cc_query payment '{"Args":["ReadPaymentOrder","PO-0001"]}' 2>/dev/null | jq -e '.status' >/dev/null && ok "сеть обслуживает запросы (ReadPaymentOrder PO-0001)"

step "6. Проверка восстановимости: расшифровка + контрольная сумма"
T="$(mktemp -d)"
for f in "$BK"/*.tgz.enc; do
  n="$(basename "$f" .enc)"
  openssl enc -d -aes-256-cbc -pbkdf2 -pass "file:$KEY" -in "$f" -out "$T/$n"
  want="$(grep " \./$n\$\|  $n\$" "$BK/SHA256SUMS.plain" | cut -d' ' -f1)"
  got="$(sha256sum "$T/$n" | cut -d' ' -f1)"
  [[ "$want" == "$got" ]] && tar tzf "$T/$n" >/dev/null && ok "$n: расшифрован, sha256 совпадает, архив читается" || fail "$n"
done
rm -rf "$T"
step "Содержимое бэкапа (ключ — только в .secrets/backup.key)"
ls -l "$BK" | awk 'NR>1 {print "  " $5 "\t" $NF}'
echo "  SHA256 (зашифрованные файлы):"; sed 's/^/    /' "$BK/SHA256SUMS.enc"
echo "$TS" >"$ROOT/backup/LATEST"
summary
