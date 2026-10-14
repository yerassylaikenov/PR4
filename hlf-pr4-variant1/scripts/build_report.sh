#!/usr/bin/env bash
# Assemble docs/report/REPORT.md from the section files and build REPORT.docx with pandoc.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
start_log final build_report
R="$ROOT/docs/report"
step "Сборка REPORT.md"
{
  cat "$R/00_title.md"; echo; echo '\newpage'; echo
  for f in 01_task1.md 02_task2.md 03_task3.md 04_appendices.md; do cat "$R/$f"; echo; echo; done
} >"$R/REPORT.md"
ok "REPORT.md: $(wc -l <"$R/REPORT.md") строк, рисунков: $(grep -c '^!\[' "$R/REPORT.md")"
missing=0
while read -r img; do
  [[ -f "$R/$img" ]] || { fail "нет файла рисунка: $img"; missing=$((missing + 1)); }
done < <(grep -oE '^!\[[^]]*\]\(([^)]+)\)' "$R/REPORT.md" | sed -E 's/.*\(([^)]+)\)/\1/')
(( missing == 0 )) && ok "все файлы рисунков на месте"
n_fig="$(grep -oE '\*Рисунок [0-9]+' "$R/REPORT.md" | awk '{print $2}' | tr '\n' ' ')"
echo "  подписи рисунков: $n_fig"
step "pandoc → REPORT.docx"
if command -v pandoc >/dev/null; then
  (cd "$R" && pandoc REPORT.md -f markdown+pipe_tables+raw_html -o REPORT.docx --resource-path=".:../architecture" \
     --metadata title="Практическая работа №4 — Hyperledger Fabric, Вариант 1" 2>&1 | grep -v 'Could not fetch' | head -5) || true
  [[ -s "$R/REPORT.docx" ]] && ok "REPORT.docx: $(du -h "$R/REPORT.docx" | cut -f1)" || fail "REPORT.docx не создан"
else
  warn "pandoc не установлен — только Markdown"
fi
summary
