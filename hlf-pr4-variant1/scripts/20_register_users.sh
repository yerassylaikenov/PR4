#!/usr/bin/env bash
# Task 2, section 4 — identities with roles issued by Fabric CA (attribute "role" in the enrollment certificate).
#   initiator1 (Org1, role=initiator), approver1 (Org1, role=approver), norole1 (Org1, no role),
#   processor2 (Org2, role=processor).
# The registrar is the CA admin already enrolled by test-network (msp under the org dir), so the CA
# bootstrap password is never needed here. Enrollment secrets: random, stored in .secrets/ (0600, git-ignored).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
start_log task2 20_register_users
ORGS="$TEST_NETWORK/organizations"
SECRETS="$ROOT/.secrets"
mkdir -p "$SECRETS"; chmod 700 "$SECRETS"

reg_enroll() { # <org> <port> <user> <role|"">
  local org="$1" port="$2" user="$3" role="$4"
  local domain="org${org}.example.com" caname="ca-org${org}"
  local tlsca="$ORGS/fabric-ca/org${org}/ca-cert.pem"
  local msp="$ORGS/peerOrganizations/$domain/users/${user}@${domain}/msp"
  export FABRIC_CA_CLIENT_HOME="$ORGS/peerOrganizations/$domain"
  step "$user — Org${org}MSP ${role:+(role=$role)}"

  local sfile="$SECRETS/${user}.secret"
  if fabric-ca-client identity list --id "$user" --caname "$caname" --tls.certfiles "$tlsca" >/dev/null 2>&1; then
    info "$user уже зарегистрирован в $caname"
  else
    [[ -f "$sfile" ]] || { openssl rand -hex 16 >"$sfile"; chmod 600 "$sfile"; }
    local attrs=()
    [[ -n "$role" ]] && attrs=(--id.attrs "role=${role}:ecert")
    echo "\$ fabric-ca-client register --caname $caname --id.name $user --id.secret [REDACTED] --id.type client ${role:+--id.attrs role=${role}:ecert}"
    fabric-ca-client register --caname "$caname" --id.name "$user" --id.secret "$(cat "$sfile")" \
      --id.type client "${attrs[@]}" --tls.certfiles "$tlsca" 2>&1 | grep -viE 'secret|password' || true
    ok "зарегистрирован в $caname"
  fi

  if [[ -f "$msp/signcerts/cert.pem" ]]; then
    info "MSP $user уже выпущен — повторный enroll не требуется"
  else
    echo "\$ fabric-ca-client enroll -u https://$user:[REDACTED]@localhost:$port --caname $caname -M .../users/${user}@${domain}/msp"
    fabric-ca-client enroll -u "https://${user}:$(cat "$sfile")@localhost:${port}" --caname "$caname" \
      -M "$msp" --tls.certfiles "$tlsca" >/dev/null 2>&1
    cp "$ORGS/peerOrganizations/$domain/msp/config.yaml" "$msp/config.yaml"
    ok "enroll выполнен, NodeOUs config.yaml скопирован"
  fi

  openssl x509 -noout -subject -issuer -in "$msp/signcerts/cert.pem" | sed 's/^/  /'
  local ext
  ext="$(openssl x509 -noout -text -in "$msp/signcerts/cert.pem" | grep -A1 '1.2.3.4.5.6.7.8.1' | tail -1 | sed 's/^ *//; s/^[^{]*//')"
  echo "  расширение 1.2.3.4.5.6.7.8.1 (attrs): $ext"
  if [[ -n "$role" ]]; then
    [[ "$(jq -r '.attrs.role' <<<"$ext")" == "$role" ]] && ok "сертификат $user содержит attrs.role=$role" || fail "role не найден"
  else
    [[ "$(jq -r '.attrs.role // "none"' <<<"$ext")" == "none" ]] && ok "сертификат $user НЕ содержит атрибута role (негативный тест)" || fail "неожиданный role"
  fi
}

reg_enroll 1 7054 initiator1 initiator
reg_enroll 1 7054 approver1 approver
reg_enroll 1 7054 norole1 ""
reg_enroll 2 8054 processor2 processor

step "Хранение секретов"
ls -l "$SECRETS" | awk 'NR>1 {print "  " $1, $NF}'
[[ "$(stat -c %a "$SECRETS"/initiator1.secret)" == 600 ]] && ok ".secrets/*.secret имеют права 600"
grep -q '^.secrets/' "$ROOT/.gitignore" && ok ".secrets/ в .gitignore"
step "Переключение пользователя: ORG_USER=<user> source scripts/env_orgN.sh"
for u in "1 initiator1" "1 approver1" "1 norole1" "2 processor2"; do
  set -- $u; use_org "$1" "$2"
  [[ -d "$CORE_PEER_MSPCONFIGPATH" ]] && ok "ORG_USER=$2 → $CORE_PEER_LOCALMSPID, MSP найден"
done
summary
