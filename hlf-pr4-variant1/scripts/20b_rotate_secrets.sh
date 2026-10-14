#!/usr/bin/env bash
# Incident response: the first run of 20_register_users.sh printed enrollment secrets
# ("Password: ..." from fabric-ca-client register) into the local log. The log was redacted and the
# secrets are rotated here, so the leaked values are useless. Existing certificates stay valid.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
start_log task2 20b_rotate_secrets
ORGS="$TEST_NETWORK/organizations"
step "Ротация enrollment secrets (fabric-ca-client identity modify --secret)"
for spec in "1 initiator1" "1 approver1" "1 norole1" "2 processor2"; do
  set -- $spec
  export FABRIC_CA_CLIENT_HOME="$ORGS/peerOrganizations/org$1.example.com"
  new="$(openssl rand -hex 16)"
  if fabric-ca-client identity modify "$2" --secret "$new" --caname "ca-org$1" \
       --tls.certfiles "$ORGS/fabric-ca/org$1/ca-cert.pem" >/dev/null 2>&1; then
    printf '%s\n' "$new" >"$ROOT/.secrets/$2.secret"; chmod 600 "$ROOT/.secrets/$2.secret"
    ok "$2: секрет заменён (новое значение только в .secrets/$2.secret)"
  else
    fail "$2: ротация не удалась"
  fi
done
step "Проверка, что в evidence нет секретов"
leaks=0
for u in initiator1 approver1 norole1 processor2; do
  :
done
if grep -rnE 'Password: [0-9a-f]{8,}' "$EVIDENCE" >/dev/null; then leaks=1; fi
(( leaks == 0 )) && ok "evidence/: строк с открытыми паролями нет" || fail "в evidence остались секреты"
summary
