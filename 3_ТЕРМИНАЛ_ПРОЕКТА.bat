@echo off
chcp 65001 >nul
rem Ubuntu terminal in the project folder with the Org1 CLI environment loaded.
wt.exe -w new --title "PR4 hlf-pr4-variant1" wsl.exe -d Ubuntu-24.04 --cd /home/yeras/hlf-pr4-variant1 --exec bash -lc "source scripts/env_org1.sh; echo 'Org1 Admin CLI готов: peer channel list, ./scripts/demo.sh, ./tests/security/run_security_tests.sh, ./scripts/demo_bft.sh'; exec bash -l"
