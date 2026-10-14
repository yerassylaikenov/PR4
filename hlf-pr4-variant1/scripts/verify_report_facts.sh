#!/usr/bin/env bash
# Final check 2 — every TxID, Package ID, hash (full or abbreviated "abcd1234…") quoted in REPORT.md must occur
# verbatim in evidence/. Prints "value -> file". Not found = error.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
start_log final verify_report_facts
REP="$ROOT/docs/report/REPORT.md"
cd "$ROOT"
TAB="$EVIDENCE/final/verify_report_facts.md"
{ echo "| Значение из отчёта | Тип | Найдено в |"; echo "|---|---|---|"; } >"$TAB"
found=0; missing=0
checkv() { # <value> <type>
  local v="$1" t="$2" f
  f="$(grep -rlF -- "$v" evidence 2>/dev/null | grep -v '^evidence/final/' | head -1 || true)"
  if [[ -n "$f" ]]; then found=$((found + 1)); echo "| \`$v\` | $t | \`$f\` |" >>"$TAB"
  else missing=$((missing + 1)); fail "НЕ НАЙДЕНО: $t $v"; echo "| \`$v\` | $t | **НЕ НАЙДЕНО** |" >>"$TAB"; fi
}
step "Package ID"
while read -r v; do checkv "$v" "Package ID"; done < <(grep -oE '[a-z]+_[0-9]\.[0-9]:[0-9a-f]{64}' "$REP" | sort -u)
step "Полные TxID / хэши (64 hex)"
while read -r v; do checkv "$v" "TxID/hash"; done < <(grep -oE '\b[0-9a-f]{64}\b' "$REP" | sort -u)
step "Сокращённые TxID (префикс ≥ 8 hex перед «…»)"
while read -r v; do checkv "$v" "TxID-префикс"; done < <(grep -oE '\b[0-9a-f]{8,}…' "$REP" | sed 's/…$//' | sort -u)
step "Хэши блоков (base64)"
while read -r v; do checkv "$v" "block hash"; done < <(grep -oE '[A-Za-z0-9+/]{43}=' "$REP" | sort -u)
step "Высоты и номера блоков из ключевых утверждений"
for kv in "высота = 15|task1/13_ledger_info.log|высота = 15" "number        = 14|task1/13_ledger_info.log|number        = 14" \
          "высота до обновления: 51|task3/30_pre_upgrade_snapshot.log|высота до обновления: 51" \
          "блок #22|task2/21_exploit.log|блок #22" "блок #26|task2/23_private_flow.log|блок #26" \
          "height=64|task3/40_restore_main.log|height=64" "Version 2.0|task3/35_commit.log|Version: 2.0" "Sequence: 2|task3/35_commit.log|Sequence: 2"; do
  IFS="|" read -r label file pat <<<"$kv"
  if grep -qF -- "$pat" "evidence/$file"; then found=$((found + 1)); echo "| \`$label\` | утверждение | \`evidence/$file\` |" >>"$TAB"
  else missing=$((missing + 1)); fail "НЕ НАЙДЕНО: $label в $file"; fi
done
echo; echo "  найдено: $found, не найдено: $missing → $TAB"
(( missing == 0 )) && ok "все $found значений из REPORT.md дословно присутствуют в evidence/"
summary
