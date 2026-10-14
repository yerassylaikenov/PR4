#!/usr/bin/env bash
# Screenshots for tasks 1 – 3.6 (main network must be running). Live commands where the state still
# exists; otherwise the excerpt of the evidence log written at execution time (the command shows the file).
set -uo pipefail
cd "$(dirname "$0")/../.."
PY="$HOME/.venvs/shots/bin/python"
T="scripts/shots/term2png.py"
S1=docs/report/screenshots/task1; S2=docs/report/screenshots/task2; S3=docs/report/screenshots/task3
mkdir -p "$S1" "$S2" "$S3"
ENV1='source scripts/env_org1.sh'
shot() { "$PY" "$T" "$@" | tail -1; }

# ---------------- Task 1 ----------------
shot $S1/01_docker_ps.png "docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' | grep -v orbit"
shot $S1/02_peer_version_channel_list.png "$ENV1 && echo \"MSP=\$CORE_PEER_LOCALMSPID user=\$ORG_USER peer=\$CORE_PEER_ADDRESS\" && peer version && peer channel list && peer channel getinfo -c paymentchannel" \
  --display 'source scripts/env_org1.sh && peer version && peer channel list && peer channel getinfo -c paymentchannel'
shot $S1/03_cli_env_org1.png "./scripts/04_cli_env_org1.sh 2>&1 | grep -vE '^# |INFO' | sed -n '/Работа с Ordering/,\$p'" --display './scripts/04_cli_env_org1.sh'
shot $S1/04_querycommitted_payment_v1.png "sed -n '/8. querycommitted/,\$p' evidence/task1/08_lifecycle_payment_1.0.log" \
  --display "sed -n '/8. querycommitted/,\$p' evidence/task1/08_lifecycle_payment_1.0.log   # вывод при деплое payment 1.0"
shot $S1/05_lifecycle_readiness.png "grep -E '✔|Org[12]MSP: |Package ID:|approveformyorg|━━' evidence/task1/08_lifecycle_payment_1.0.log | cut -c1-230" \
  --display "grep -E '✔|Org[12]MSP: |Package ID:' evidence/task1/08_lifecycle_payment_1.0.log"
shot $S1/06_transactions_T1_T4.png "sed -n '/Задание 1.5/,/\\[T6\\]/p' evidence/task1/10_transactions.log | grep -vE 'Chaincode invoke successful|InitCmdFactory' | cut -c1-260" \
  --display "sed -n '/Задание 1.5/,/[T6]/p' evidence/task1/10_transactions.log   # T1–T5 committed with status (VALID)"
shot $S1/07_rejected_N1_N2.png "sed -n '/Негативные сценарии/,/Демонстрация MVCC/p' evidence/task1/10_transactions.log | grep -v InitCmdFactory" \
  --display "sed -n '/Негативные сценарии/,/MVCC/p' evidence/task1/10_transactions.log"
shot $S1/08_mvcc_demo.png "grep -vE '^# ' evidence/task1/10b_mvcc_demo.log" --display "cat evidence/task1/10b_mvcc_demo.log"
shot $S1/09_tx_anatomy_T4.png "grep -vE '^# ' evidence/task1/11_analyze_tx_6d535b17ed87.log" --display "./scripts/analyze_tx.sh 6d535b17…e489ea   # разбор T4 Settle"
shot $S1/10_state_read_history.png "grep -vE '^# |^\\\$ curl|_all_dbs|^  \\[' evidence/task1/12_state.log | sed -n '/ReadPaymentOrder/,/CouchDB peer0.org1/p' | grep -vE 'createdByHash|docType|purposeCode|reference|senderBank|receiverBank|createdAt|updatedAt' | head -90" \
  --display "./scripts/12_state.sh   # (фрагмент evidence/task1/12_state.log)"
shot $S1/11_ledger_getinfo_lastblock.png "grep -vE '^# |^\\\$ peer channel fetch' evidence/task1/13_ledger_info.log | grep -v INFO" --display "./scripts/13_ledger_info.sh"
shot $S1/12_static_analysis.png "grep -E '✔|✘|⚠|══|━━' evidence/task1/07_static_analysis.log" --display "./scripts/07_static_analysis.sh chaincode/payment-v1 task1 80"
shot $S1/13_gateway_client.png "$ENV1 && ROOT=\$PWD client/payment-client -org 2 -user Admin evaluate payment ReadPaymentOrder PO-0002 && grep -A9 'T5 через Fabric Gateway' evidence/task1/10_transactions.log | grep -E 'Gateway|Identity|Call|TxID|Status|Block|✔'" \
  --display 'client/payment-client -org 2 evaluate payment ReadPaymentOrder PO-0002 ; grep T5 evidence/task1/10_transactions.log'
"$PY" scripts/shots/fauxton.py $S1/14_couchdb_fauxton_PO-0001.png PO-0001 paymentchannel_payment

# ---------------- Task 2 ----------------
shot $S2/01_users_roles.png "grep -E '━━|subject|attrs|✔|══' evidence/task2/20_register_users.log" --display "./scripts/20_register_users.sh"
shot $S2/02_querycommitted_vuln_secure.png "$ENV1 && for n in paymentvuln paymentsecure; do echo \"--- \$n\"; peer lifecycle chaincode querycommitted -C paymentchannel -n \$n --output json | jq -c '{version, sequence, approvals, collections: [.collections.config[]?.Payload.StaticCollectionConfig | {name, member_only_read, member_only_write, maximum_peer_count, required_peer_count, block_to_live}]}'; done" \
  --display 'for n in paymentvuln paymentsecure; do peer lifecycle chaincode querycommitted -C paymentchannel -n $n --output json | jq ...; done'
shot $S2/03_exploit_paymentvuln.png "sed -n '/Задание 2.3/,/Результат:/p' evidence/task2/21_exploit.log | grep -v 'Chaincode invoke' | cut -c1-250" --display "./scripts/21_exploit_vuln.sh"
shot $S2/04_exploit_history_creator.png "sed -n '/Результат:/,\$p' evidence/task2/21_exploit.log" --display "./scripts/21_exploit_vuln.sh   # история PO-V001 и декодированный блок Submit"
shot $S2/05_exploit_on_secure_denied.png "grep -vE '^# ' evidence/task2/25_exploit_secure.log" --display "./scripts/25_exploit_secure.sh"
shot $S2/06_setsettlement_transient.png "sed -n '/2. SetSettlementDetails/,/4. Доказательство/p' evidence/task2/23_private_flow.log | grep -vE 'Chaincode invoke|^# '" --display "./scripts/23_private_data_flow.sh   # шаги 2–3"
shot $S2/07_block_grep_zero.png "sed -n '/4. Доказательство/,/6. CouchDB/p' evidence/task2/23_private_flow.log" --display "./scripts/23_private_data_flow.sh   # шаги 4–5"
shot $S2/08_couchdb_p_h.png "sed -n '/6. CouchDB/,\$p' evidence/task2/23_private_flow.log" --display "./scripts/23_private_data_flow.sh   # шаги 6–8"
shot $S2/09_sec_01_02_03.png "grep -E 'SEC-0[123]' evidence/task2/security_tests.log" --display "./tests/security/run_security_tests.sh | grep SEC-0[123]"
shot $S2/10_security_tests_all.png "grep -E '━━|✔|✘|══' evidence/task2/security_tests.log | cut -c1-240" --display "./tests/security/run_security_tests.sh"
shot $S2/11_static_analysis_secure.png "grep -E '✔|✘|⚠|══|━━' evidence/task2/27_static_analysis_paymentsecure.log | cut -c1-240" --display "./scripts/07_static_analysis.sh chaincode/payment-secure task2 85"
"$PY" scripts/shots/fauxton.py $S2/12_fauxton_org1_private.png "" "_all_dbs" 5984
"$PY" scripts/shots/fauxton.py $S2/13_fauxton_org2_hash_only.png "" "_all_dbs" 7984

# ---------------- Task 3 (до остановки основной сети) ----------------
shot $S3/01_querycommitted_before.png "grep -vE '^# ' evidence/task3/30_pre_upgrade_snapshot.log | sed -n '1,30p'" --display "./scripts/30_pre_upgrade_snapshot.sh"
shot $S3/02_queryinstalled_both.png "for o in 1 2; do source scripts/env_org\$o.sh; echo \"--- peer0.org\$o (\$CORE_PEER_LOCALMSPID)\"; peer lifecycle chaincode queryinstalled 2>&1 | grep -v INFO; done" \
  --display 'for o in 1 2; do source scripts/env_org$o.sh; peer lifecycle chaincode queryinstalled; done'
shot $S3/03_checkcommitreadiness.png "grep -E '━━|approveformyorg|Org[12]MSP|✔' evidence/task3/34_approve_payment_2.0.log | sed -n '/5.1/,\$p' | cut -c1-200" --display "./scripts/lifecycle.sh -n payment -v 2.0 -s 2 --stop-before-commit"
shot $S3/04_negative_seq3_policy.png "grep -vE '^# |^\\\$|^\{|^\}|^\s+\"|^\s+\}' evidence/task3/34_negative_lifecycle.log" --display "./scripts/34_negative_lifecycle.sh"
shot $S3/05_querycommitted_after.png "$ENV1 && peer lifecycle chaincode querycommitted --channelID paymentchannel --name payment --output json && docker ps --filter name=dev-peer --format 'table {{.Names}}\t{{.Status}}' | grep -E 'NAMES|payment_'" \
  --display 'peer lifecycle chaincode querycommitted --channelID paymentchannel --name payment --output json; docker ps --filter name=dev-peer'
shot $S3/06_compat_C1_C2.png "sed -n '/C1 —/,/C3 —/p' evidence/task3/36_compat.log" --display "./scripts/36_compat_check.sh   # C1–C2"
shot $S3/07_return_history.png "sed -n '/C4 —/,/C9 —/p' evidence/task3/36_compat.log | cut -c1-220" --display "./scripts/36_compat_check.sh   # C4–C8"
shot $S3/08_compat_table.png "cat evidence/task3/compat_table.md" --display "cat evidence/task3/compat_table.md"
shot $S3/09_static_analysis_v2.png "grep -E '✔|✘|⚠|══|━━' evidence/task3/32_static_analysis_payment_v2.log" --display "./scripts/07_static_analysis.sh chaincode/payment-v2 task3 80"
ls -la $S1 $S2 $S3
