#!/usr/bin/env bash
# Stream filter: removes secrets from logs before they are written to disk.
# Usage: some_command | scripts/redact.sh            (stdin -> stdout)
#        scripts/redact.sh --in-place <file>...       (rewrite files)
set -euo pipefail

SED_EXPR=(
  # PEM private key blocks (single-line marker; the multi-line body is handled by awk below)
  -e 's/-----BEGIN [A-Z ]*PRIVATE KEY-----/[REDACTED PRIVATE KEY BEGIN]/g'
  -e 's/-----END [A-Z ]*PRIVATE KEY-----/[REDACTED PRIVATE KEY END]/g'
  # test-network bootstrap credentials and CouchDB credentials
  -e 's/adminpw/[REDACTED]/g'
  -e 's#//admin:[^@]*@#//[REDACTED]@#g'
  -e 's/\(COUCHDB_PASSWORD\|COUCHDB_USER\)=[^ ]*/\1=[REDACTED]/g'
  # private key file names (keep the fact, hide the name)
  -e 's#[0-9a-f]\{64\}_sk#[REDACTED]_sk#g'
  -e 's#/keystore/[^ "]*#/keystore/[REDACTED]#g'
  # enrollment secrets passed on the command line: -u https://user:secret@host
  -e 's#\(https\?://[A-Za-z0-9_.-]*\):[^@/ ]*@#\1:[REDACTED]@#g'
  -e 's/\(--id\.secret\|--secret\)[ =][^ ]*/\1 [REDACTED]/g'
  -e 's/\(ENROLL_SECRET\|SECRET\|PASSWORD\)=[^ ]*/\1=[REDACTED]/g'
  # fabric-ca-client register prints the generated/assigned enrollment secret as "Password: <secret>"
  -e 's/\([Pp]assword\): *[^ ]*/\1: [REDACTED]/g'
)

filter() {
  awk '
    /-----BEGIN [A-Z ]*PRIVATE KEY-----/ { print "[REDACTED PRIVATE KEY]"; skip=1; next }
    skip && /-----END [A-Z ]*PRIVATE KEY-----/ { skip=0; next }
    !skip { print; fflush() }
  ' | sed -u "${SED_EXPR[@]}"
}

if [[ "${1:-}" == "--in-place" ]]; then
  shift
  for f in "$@"; do
    tmp="$(mktemp)"
    filter <"$f" >"$tmp" && cat "$tmp" >"$f"
    rm -f "$tmp"
  done
else
  filter
fi
