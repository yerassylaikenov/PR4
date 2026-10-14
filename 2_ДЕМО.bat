@echo off
chcp 65001 >nul
rem Opens an Ubuntu terminal with the live demo (Enter = next section). The shell stays open afterwards.
wt.exe -w new --title "PR4 Hyperledger Fabric - demo" wsl.exe -d Ubuntu-24.04 --cd /home/yeras/hlf-pr4-variant1 --exec bash -lc "./scripts/demo.sh; exec bash -l"
