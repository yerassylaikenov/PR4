#!/usr/bin/env bash
# Screenshots of the SmartBFT stand (task 3.7). The stand must be running.
set -uo pipefail
cd "$(dirname "$0")/../.."
PY="$HOME/.venvs/shots/bin/python"; T="scripts/shots/term2png.py"; S3=docs/report/screenshots/task3
shot() { "$PY" "$T" "$@" | tail -1; }
shot $S3/11_bft_docker_ps.png "docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' | grep -E 'NAMES|orderer' | cut -c1-200; echo; docker ps --format 'table {{.Names}}\t{{.Status}}' | grep -vE 'orbit|orderer'" \
  --display "docker ps   # стенд SmartBFT: 4 orderer, 2 peer, 3 CA, 2 CouchDB"
shot $S3/12_bft_config.png "grep -vE '^# |^\\\$ peer channel fetch|INFO' evidence/task3/bft/39_bft_config.log" --display "./scripts/39_bft_config.sh"
shot $S3/13_bft_stop_orderer4_tx.png "sed -n '/Исходное состояние/,/E4. Восстановление/p' evidence/task3/bft/39_bft_experiment.log | grep -vE 'chaincodeCmd|^\s*$' | cut -c1-230" --display "./scripts/39_bft_experiment.sh   # E1–E3"
shot $S3/14_bft_restore_catchup.png "sed -n '/E4. Восстановление/,/E5. /p' evidence/task3/bft/39_bft_experiment.log | grep -vE 'chaincodeCmd|^\s*$' | cut -c1-230" --display "./scripts/39_bft_experiment.sh   # E4"
shot $S3/15_bft_view_change.png "sed -n '/E5. /,/E7. /p' evidence/task3/bft/39_bft_experiment.log | grep -vE 'chaincodeCmd|^\s*$' | cut -c1-230" --display "./scripts/39_bft_experiment.sh   # E5–E6"
shot $S3/16_bft_no_quorum.png "sed -n '/E7. /,/Таблица эксперимента/p' evidence/task3/bft/39_bft_experiment.log | grep -vE 'chaincodeCmd|^\s*$' | cut -c1-230" --display "./scripts/39_bft_experiment.sh   # E7–E8"
shot $S3/17_bft_experiment_table.png "cat evidence/task3/bft/experiment.md" --display "cat evidence/task3/bft/experiment.md" --width 1700
shot $S3/18_bft_heights_live.png "source scripts/env_org1.sh; for o in orderer:7053 orderer2:7055 orderer3:7057 orderer4:7059; do n=\${o%%:*}; p=\${o##*:}; echo -n \"\$n.example.com  \"; osnadmin channel list --channelID bftchannel -o localhost:\$p --ca-file \$ORDERER_CA --client-cert fabric-samples/test-network/organizations/ordererOrganizations/example.com/orderers/\$n.example.com/tls/server.crt --client-key fabric-samples/test-network/organizations/ordererOrganizations/example.com/orderers/\$n.example.com/tls/server.key | sed -n '/^{/,\$p' | jq -c '{name,status,consensusRelation,height}'; done; for o in 1 2; do source scripts/env_org\$o.sh; echo -n \"peer0.org\$o  \"; peer channel getinfo -c bftchannel 2>/dev/null; done" \
  --display 'for o in orderer..orderer4: osnadmin channel list --channelID bftchannel; peer channel getinfo -c bftchannel (оба peers)'
ls -la $S3 | grep bft
