#!/usr/bin/env bash
# Explicit chaincode lifecycle (no network.sh deployCC):
#   vendor -> package -> calculatepackageid -> install (both peers) -> queryinstalled
#   -> approveformyorg Org1 -> checkcommitreadiness -> approveformyorg Org2 -> checkcommitreadiness
#   -> commit (both peers) -> querycommitted
#
# Usage: scripts/lifecycle.sh -n <name> -p <path> -v <version> -s <sequence>
#          [-l <label>] [-c <collections-config.json>] [-C <channel>] [-t <task>] [-g <log-name>]
#          [--stop-after-install]
set -euo pipefail
source "$(dirname "$0")/lib.sh"

NAME=; CC_PATH=; VERSION=; SEQUENCE=; LABEL=; COLLECTIONS=; TASK=task1; LOGNAME_=; STOP_AFTER_INSTALL=0
STOP_BEFORE_COMMIT=0; COMMIT_ONLY=0
POLICY="AND('Org1MSP.peer','Org2MSP.peer')"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) NAME="$2"; shift ;;
    -p) CC_PATH="$2"; shift ;;
    -v) VERSION="$2"; shift ;;
    -s) SEQUENCE="$2"; shift ;;
    -l) LABEL="$2"; shift ;;
    -c) COLLECTIONS="$2"; shift ;;
    -C) CHANNEL="$2"; export CHANNEL; shift ;;
    -t) TASK="$2"; shift ;;
    -g) LOGNAME_="$2"; shift ;;
    --stop-after-install) STOP_AFTER_INSTALL=1 ;;
    --stop-before-commit) STOP_BEFORE_COMMIT=1 ;;
    --commit-only) COMMIT_ONLY=1 ;;
    *) die "unknown flag $1" ;;
  esac
  shift
done
[[ -n "$NAME" && -n "$CC_PATH" && -n "$VERSION" && -n "$SEQUENCE" ]] || die "usage: lifecycle.sh -n name -p path -v version -s sequence"
LABEL="${LABEL:-${NAME}_${VERSION}}"
BUILD="$ROOT/build"; mkdir -p "$BUILD"
PKG="$BUILD/${LABEL}.tar.gz"

use_org 1
SCRIPT_CMD="scripts/lifecycle.sh -n $NAME -p $CC_PATH -v $VERSION -s $SEQUENCE -l $LABEL ${COLLECTIONS:+-c $COLLECTIONS} -C $CHANNEL"
start_log "$TASK" "${LOGNAME_:-08_lifecycle_${NAME}_${VERSION}}"

# Identical definition flags for approve / checkcommitreadiness / commit (otherwise definitions differ).
DEF_FLAGS=(--channelID "$CHANNEL" --name "$NAME" --version "$VERSION" --sequence "$SEQUENCE" --signature-policy "$POLICY")
[[ -n "$COLLECTIONS" ]] && DEF_FLAGS+=(--collections-config "$ROOT/$COLLECTIONS")
ORD_FLAGS=(-o "$ORDERER_ADDR" --ordererTLSHostnameOverride "$ORDERER_HOST" --tls --cafile "$ORDERER_CA")

step "Lifecycle: $NAME v$VERSION, sequence $SEQUENCE, канал $CHANNEL"
echo "  Endorsement Policy : $POLICY"
[[ -n "$COLLECTIONS" ]] && echo "  Collections config : $COLLECTIONS"

if (( COMMIT_ONLY )); then
  PACKAGE_ID="$(cat "$BUILD/${LABEL}.packageid")"
  info "режим --commit-only: пакет уже установлен и утверждён, Package ID $PACKAGE_ID"
else
step "1. go mod vendor ($CC_PATH)"
( cd "$ROOT/$CC_PATH" && GOFLAGS=-mod=mod go mod tidy && go mod vendor )
ok "зависимости завендорены ($(find "$ROOT/$CC_PATH/vendor" -name '*.go' | wc -l) файлов .go)"

step "2. Package"
run peer lifecycle chaincode package "$PKG" --path "$ROOT/$CC_PATH" --lang golang --label "$LABEL"
ok "пакет $(basename "$PKG") ($(du -h "$PKG" | cut -f1))"

step "3. Package ID"
PACKAGE_ID="$(peer lifecycle chaincode calculatepackageid "$PKG")"
echo "  Package ID: $PACKAGE_ID"
ok "Package ID вычислен: $PACKAGE_ID"
echo "$PACKAGE_ID" >"$BUILD/${LABEL}.packageid"

step "4. Install на peer0.org1 и peer0.org2"
for org in 1 2; do
  use_org "$org"; log_identity
  if peer lifecycle chaincode queryinstalled --output json 2>/dev/null | jq -e --arg id "$PACKAGE_ID" '.installed_chaincodes[]? | select(.package_id == $id)' >/dev/null; then
    info "уже установлен на peer0.org$org — пропуск"
  else
    run peer lifecycle chaincode install "$PKG"
  fi
  run peer lifecycle chaincode queryinstalled
  peer lifecycle chaincode queryinstalled 2>/dev/null | grep -q "$PACKAGE_ID" && ok "peer0.org$org: установлен $PACKAGE_ID" || fail "peer0.org$org: пакет не найден"
done
if (( STOP_AFTER_INSTALL )); then summary; exit 0; fi
fi

use_org 1
committed_seq="$(peer lifecycle chaincode querycommitted -C "$CHANNEL" -n "$NAME" --output json 2>/dev/null | jq -r '.sequence // 0' || echo 0)"
if [[ "$committed_seq" == "$SEQUENCE" ]]; then
  info "определение $NAME sequence $SEQUENCE уже зафиксировано — шаги approve/commit пропущены (идемпотентность)"
else
  for org in 1 2; do
    (( COMMIT_ONLY )) && break
    step "5.$org approveformyorg — Org${org}MSP"
    use_org "$org"; log_identity
    run peer lifecycle chaincode approveformyorg "${ORD_FLAGS[@]}" "${DEF_FLAGS[@]}" --package-id "$PACKAGE_ID"
    ok "Org${org}MSP утвердила $NAME v$VERSION seq $SEQUENCE"
    step "6.$org checkcommitreadiness после approve Org${org}"
    run peer lifecycle chaincode checkcommitreadiness "${DEF_FLAGS[@]}" --output json
    peer lifecycle chaincode checkcommitreadiness "${DEF_FLAGS[@]}" --output json 2>/dev/null \
      | jq -r '.approvals | to_entries[] | "  \(.key): \(.value)"'
  done
  if (( COMMIT_ONLY )); then
    step "6. checkcommitreadiness перед commit"
    use_org 1
    run peer lifecycle chaincode checkcommitreadiness "${DEF_FLAGS[@]}" --output json
  fi
  ready="$(peer lifecycle chaincode checkcommitreadiness "${DEF_FLAGS[@]}" --output json 2>/dev/null | jq -r '[.approvals[]] | all')"
  [[ "$ready" == "true" ]] && ok "обе организации утвердили определение (Org1MSP: true, Org2MSP: true)" || die "readiness: не все approvals"
  if (( STOP_BEFORE_COMMIT )); then summary; exit 0; fi

  step "7. Commit (endorse обоими peers)"
  use_org 1; log_identity
  # shellcheck disable=SC2046
  run peer lifecycle chaincode commit "${ORD_FLAGS[@]}" "${DEF_FLAGS[@]}" $(peer_flags 1 2)
fi

step "8. querycommitted — проверка зафиксированного определения"
use_org 1
run peer lifecycle chaincode querycommitted --channelID "$CHANNEL" --name "$NAME" --output json
qc="$(peer lifecycle chaincode querycommitted --channelID "$CHANNEL" --name "$NAME" --output json 2>/dev/null)"
[[ "$(jq -r .version <<<"$qc")" == "$VERSION" ]] && ok "Version: $VERSION" || fail "version mismatch"
[[ "$(jq -r .sequence <<<"$qc")" == "$SEQUENCE" ]] && ok "Sequence: $SEQUENCE" || fail "sequence mismatch"
[[ "$(jq -r '.approvals.Org1MSP and .approvals.Org2MSP' <<<"$qc")" == "true" ]] && ok "Approvals: Org1MSP=true, Org2MSP=true" || fail "approvals"
policy_b64="$(jq -r .validation_parameter <<<"$qc")"
# validation_parameter is a serialized ApplicationPolicy proto; decode the signature policy for humans.
echo "$policy_b64" | base64 -d >"$BUILD/vp.pb"
if configtxlator proto_decode --type protos.ApplicationPolicy --input "$BUILD/vp.pb" --output "$BUILD/vp.json" 2>/dev/null; then
  n_of="$(jq -r '.signature_policy.rule.n_out_of.n' "$BUILD/vp.json")"
  ids=; roles=
  for p in $(jq -r '.signature_policy.identities[].principal' "$BUILD/vp.json"); do
    # each principal is a serialized common.MSPRole
    r="$(base64 -d <<<"$p" | configtxlator proto_decode --type common.MSPRole --input /dev/stdin)"
    ids="${ids:+$ids,}$(jq -r .msp_identifier <<<"$r")"
    roles="$(jq -r .role <<<"$r")"
  done
  echo "  Decoded endorsement policy: ${n_of}-out-of-2 of [$ids] role=$roles"
  [[ "$n_of" == "2" && "$ids" == "Org1MSP,Org2MSP" ]] && ok "Endorsement Policy = AND('Org1MSP.peer','Org2MSP.peer') (2 из 2, роль PEER)" || fail "policy is not AND"
fi
rm -f "$BUILD/vp.pb" "$BUILD/vp.json"
if [[ -n "$COLLECTIONS" ]]; then
  jq -e '.collections.config[0].Payload.StaticCollectionConfig.name' <<<"$qc" >/dev/null \
    && ok "коллекции в определении: $(jq -r '[.collections.config[].Payload.StaticCollectionConfig.name] | join(",")' <<<"$qc")" \
    || fail "коллекция не найдена в querycommitted"
fi
summary
