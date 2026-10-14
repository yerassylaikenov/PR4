#!/usr/bin/env bash
# Step 7 — unit tests + coverage + go vet / staticcheck / gosec / govulncheck / determinism.
# Usage: scripts/07_static_analysis.sh <chaincode-dir> <task> <min-coverage> [log-name]
set -euo pipefail
source "$(dirname "$0")/lib.sh"
DIR="${1:-chaincode/payment-v1}"
TASK="${2:-task1}"
MINCOV="${3:-80}"
NAME="${4:-07_static_analysis}"
start_log "$TASK" "$NAME"
cd "$ROOT/$DIR"

step "Unit-тесты ($DIR) — counterfeiter-моки + in-memory ledger"
go test -count=1 -coverprofile=/tmp/cover.out ./chaincode/ -v 2>&1 \
  | grep -E '^(=== RUN|--- (PASS|FAIL)|    --- (PASS|FAIL)|PASS|FAIL|ok|coverage)' | grep -v '=== RUN' | sed 's/^/  /'
total="$(go test -count=1 -v ./chaincode/ 2>&1 | grep -cE -- '--- PASS')"
failed="$(go test -count=1 -v ./chaincode/ 2>&1 | grep -cE -- '--- FAIL' || true)"
cov="$(go tool cover -func=/tmp/cover.out | awk '/^total:/ {gsub("%","",$3); print $3}')"
(( failed == 0 )) && ok "unit-тесты: $total PASS, 0 FAIL" || fail "unit-тесты: $failed FAIL"
awk -v c="$cov" -v m="$MINCOV" 'BEGIN{exit !(c+0 >= m+0)}' && ok "покрытие пакета chaincode: ${cov}% (порог ≥ ${MINCOV}%)" || fail "покрытие ${cov}% < ${MINCOV}%"
rm -f /tmp/cover.out

step "go vet"
if go vet ./... 2>&1; then ok "go vet — 0 замечаний"; else fail "go vet"; fi

step "staticcheck"
# SC_JUSTIFY: regex of findings that are documented as accepted (style-only, test-only) — they are
# printed and justified instead of being silently ignored.
sc_out="$(staticcheck ./... 2>&1 || true)"
if [[ -z "$sc_out" ]]; then
  ok "staticcheck — 0 замечаний"
else
  echo "$sc_out"
  rest="$(grep -vE "${SC_JUSTIFY:-^$}" <<<"$sc_out" || true)"
  if [[ -z "$rest" && -n "${SC_JUSTIFY:-}" ]]; then
    warn "staticcheck: $(wc -l <<<"$sc_out") замечание(я) обоснованы: ${SC_REASON:-}"
    ok "staticcheck — открытых замечаний нет (остальные обоснованы)"
  else
    fail "staticcheck"
  fi
fi

step "gosec (исключены сгенерированные mocks и тесты)"
if gosec -quiet -exclude-generated -exclude-dir=mocks -tests=false ./... 2>&1; then
  ok "gosec — 0 находок"
else
  fail "gosec — есть находки"
fi

step "govulncheck (уязвимости в достижимом коде зависимостей)"
if govulncheck ./... 2>&1; then ok "govulncheck — уязвимостей в используемом коде нет"; else fail "govulncheck"; fi

step "Детерминизм (SC09)"
"$ROOT/scripts/check_determinism.sh" "$DIR" | grep -E '✔|✘|⚠|      ' | grep -v '══' || true
"$ROOT/scripts/check_determinism.sh" "$DIR" >/dev/null 2>&1 && ok "check_determinism.sh — чисто" || fail "check_determinism.sh"
summary
