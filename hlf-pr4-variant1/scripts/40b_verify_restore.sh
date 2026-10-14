#!/usr/bin/env bash
# Re-check of the restored main network against the backup moment (height + currentBlockHash);
# appended to evidence/task3/40_restore_main.log.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
use_org 1
LOG_APPEND=1 start_log task3 40_restore_main
step "7b. Сверка с моментом бэкапа (повторная проверка)"
info_now="$(peer channel getinfo -c "$CHANNEL" 2>/dev/null | sed 's/^Blockchain info: //')"
line="$(grep -m1 'Состояние до бэкапа' "$EVIDENCE/task3/38_backup.log")"
hb="$(sed -E 's/.*высота ([0-9]+).*/\1/' <<<"$line")"; cb="$(sed -E 's/.*currentBlockHash ([^ ]+).*/\1/' <<<"$line")"
echo "  в момент бэкапа: height=$hb currentBlockHash=$cb"
echo "  сейчас         : height=$(jq .height <<<"$info_now") currentBlockHash=$(jq -r .currentBlockHash <<<"$info_now")"
[[ "$hb" == "$(jq .height <<<"$info_now")" && "$cb" == "$(jq -r .currentBlockHash <<<"$info_now")" ]] \
  && ok "высота и currentBlockHash совпадают с моментом бэкапа — ledger восстановлен без потерь" || fail "ledger отличается"
summary
