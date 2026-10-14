#!/usr/bin/env bash
# Live repeat of task 3.7 for the defence (≈ 10–15 min):
#   encrypted backup of the main network -> network.sh down -> SmartBFT stand (4 orderers) -> config check
#   -> payment 2.0 on bftchannel -> fault experiment -> stand down -> main network restored from the backup.
# Logs go to demo-evidence/ (the original evidence/ is not touched).
set -euo pipefail
export EVIDENCE_ROOT="${EVIDENCE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)/demo-evidence}"
source "$(dirname "$0")/lib.sh"
mkdir -p "$EVIDENCE/task3/bft"
echo "${C_Y}Основная сеть будет временно остановлена (после бэкапа) и восстановлена из бэкапа в конце.${C_0}"
if [[ "${YES:-0}" != 1 ]]; then read -r -p "Продолжить? [y/N] " a; [[ "$a" =~ ^[yYдД] ]] || exit 0; fi
S="$ROOT/scripts"
step "1/6 Бэкап основной сети";            "$S/38_backup_volumes.sh"      | grep -E '✔|✘|══'
step "2/6 Стенд SmartBFT";                 "$S/39_bft_up.sh"              | grep -E '✔|✘|══'
step "3/6 Конфигурация канала bftchannel"; "$S/39_bft_config.sh"          | grep -E '✔|✘|══|ConsensusType|consenter|  [1-4] '
step "4/6 payment 2.0 в bftchannel";       "$S/lifecycle.sh" -n payment -p chaincode/payment-v2 -v 2.0 -s 1 -C bftchannel -t task3/bft -g 39_bft_lifecycle_payment | grep -E '✔|✘|══'
step "5/6 Эксперимент с отказами";          "$S/39_bft_experiment.sh"
step "6/6 Восстановление основной сети";   "$S/40_restore_main.sh"         | grep -E '✔|✘|══|момент|сейчас'
ok "готово: основная сеть восстановлена, можно снова запускать ./scripts/demo.sh"
