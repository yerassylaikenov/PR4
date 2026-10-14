#!/usr/bin/env bash
# Final check 1 — secrets: gitleaks (docker image) over the repository and its git history + targeted grep
# over docs/ and evidence/. Screenshots must still be checked by eye (gitleaks does not read images).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
start_log final scan_secrets
cd "$ROOT"

step "gitleaks — история git"
if docker run --rm -v "$ROOT:/repo:ro" zricethezav/gitleaks:v8.21.2 git /repo --gitleaks-ignore-path /repo/.gitleaksignore --no-banner --redact -v 2>&1 | tail -5; then
  info "исключения (проверенные ложные срабатывания): $(grep -vc "^#" .gitleaksignore) fingerprint(s) в .gitleaksignore — публичный хэш ключа private data"
  ok "gitleaks git: утечек в истории коммитов нет"
else
  fail "gitleaks git: найдены секреты"
fi
step "gitleaks — рабочие файлы docs/, evidence/, scripts/, chaincode/ (без vendor), client/"
leaks=0
for d in docs evidence scripts chaincode client tests collections; do
  out="$(docker run --rm -v "$ROOT:/repo:ro" zricethezav/gitleaks:v8.21.2 dir "/repo/$d" --gitleaks-ignore-path /repo/.gitleaksignore --no-banner --redact 2>&1 || true)"
  if grep -q 'no leaks found' <<<"$out"; then ok "gitleaks dir $d: no leaks found"; else
    n="$(grep -oE '[0-9]+ leaks? found|leaks found: [0-9]+' <<<"$out" | head -1)"; fail "gitleaks dir $d: ${n:-см. вывод}"; leaks=1
    docker run --rm -v "$ROOT:/repo:ro" zricethezav/gitleaks:v8.21.2 dir "/repo/$d" --gitleaks-ignore-path /repo/.gitleaksignore --no-banner --redact -v 2>&1 | grep -E 'File:|RuleID|Secret' | head -12 | sed 's/^/    /'
  fi
done

step "grep по docs/ и evidence/: PRIVATE KEY | _sk | priv_sk | adminpw | enrollment secret | password"
hits="$(grep -RniE 'BEGIN [A-Z ]*PRIVATE KEY|[0-9a-f]{64}_sk\b|priv_sk|adminpw|enrollment.?secret[:=]|password[=:] *[^ \[]' docs evidence 2>/dev/null \
  | grep -vE 'REDACTED|\.png:|Binary|grep -|PRIVATE KEY\|' || true)"
if [[ -z "$hits" ]]; then ok "совпадений нет"; else echo "$hits" | head -20; fail "найдены совпадения (проверить вручную)"; fi

step "git: в репозитории нет organizations/, ключей, fabric-samples/, backup/, .secrets/"
tracked="$(git ls-files | grep -E '(^|/)organizations/|_sk$|/keystore/|^fabric-samples/|^backup/|^\.secrets/|\.pem$|\.key$' || true)"
[[ -z "$tracked" ]] && ok "запрещённые пути не отслеживаются git" || { echo "$tracked"; fail "в git есть запрещённые файлы"; }
git check-ignore -q .secrets/x && git check-ignore -q backup/x && git check-ignore -q fabric-samples/x && ok ".secrets/, backup/, fabric-samples/ в .gitignore"
warn "скриншоты gitleaks не проверяет — их нужно просмотреть глазами (пароли и ключи в кадр не попадали: Fauxton после входа, значения реквизитов маскированы)"
summary
