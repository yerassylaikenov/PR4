#!/usr/bin/env bash
# OWASP SC09:2025 — determinism check for Go chaincode (non-test sources only).
# Usage: scripts/check_determinism.sh <chaincode-dir>
# Non-deterministic code makes endorsers produce different RW-sets -> endorsement mismatch.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
DIR="${1:?usage: check_determinism.sh <chaincode-dir>}"
cd "$ROOT/$DIR"

mapfile -t FILES < <(find . -name '*.go' ! -name '*_test.go' ! -path './vendor/*' ! -path '*/mocks/*' | sort)
step "Проверка детерминизма chaincode: $DIR (${#FILES[@]} файлов)"

found=0
probe() {
  local label="$1" pattern="$2" hits
  # ignore full-line comments (documentation that *mentions* a forbidden API)
  hits="$(grep -nE "$pattern" "${FILES[@]}" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)"
  if [[ -n "$hits" ]]; then
    fail "$label"; echo "$hits" | sed 's/^/      /'; found=$((found + 1))
  else
    ok "$label — 0 находок"
  fi
}
probe "time.Now (локальное время узла)"            'time\.Now\('
probe "math/rand"                                   '"math/rand'
probe "crypto/rand (соль/nonce должен давать клиент)" '"crypto/rand"'
probe "горутины (go func / go call)"                '(^|[[:space:]])go [a-zA-Z_]+\(|go func'
probe "os.Getenv / переменные окружения"            'os\.Getenv|os\.LookupEnv'
probe "сетевые вызовы (net/http, net.Dial)"         '"net/http"|net\.Dial'
probe "файловая система (os.ReadFile/os.Open)"      'os\.(ReadFile|Open|Create)\('
probe "InvokeChaincode (cross-chaincode, SC05/SC06)" 'InvokeChaincode'

# Package-level var declarations: only immutable compiled regexps are acceptable.
vars="$(grep -nE '^var |^\s+re[A-Z][A-Za-z]+ += regexp\.MustCompile' "${FILES[@]}" || true)"
mutable="$(grep -nE '^var [a-zA-Z_]+ ' "${FILES[@]}" | grep -v 'regexp.MustCompile' || true)"
if [[ -n "$mutable" ]]; then
  fail "глобальные изменяемые var"; echo "$mutable" | sed 's/^/      /'; found=$((found + 1))
else
  ok "глобальные изменяемые var — 0 (допустимы только regexp.MustCompile: неизменяемы после init)"
fi

# Iterating over a map and writing/returning the result in iteration order.
maprange="$(grep -nE 'for [a-z_]+(, [a-z_]+)? := range [a-zA-Z_.]*(map|Map|attrs|fields)\b' "${FILES[@]}" || true)"
if [[ -n "$maprange" ]]; then
  warn "итерация по map — проверить вручную:"; echo "$maprange" | sed 's/^/      /'
else
  ok "итерация по map с выводом в state/ответ — 0 находок"
fi

if (( found == 0 )); then
  ok "ИТОГ: недетерминированных конструкций не найдено"
else
  fail "ИТОГ: найдено $found категорий недетерминизма"
fi
summary
