@echo off
chcp 65001 >nul
echo === PR4: запуск Docker Desktop и сети Hyperledger Fabric ===
tasklist /FI "IMAGENAME eq Docker Desktop.exe" | find /I "Docker Desktop.exe" >nul || start "" "C:\Program Files\Docker\Docker\Docker Desktop.exe"
echo Ожидание Docker...
:wait
wsl.exe -d Ubuntu-24.04 --exec docker info >nul 2>&1 || (timeout /t 3 >nul & goto wait)
wsl.exe -d Ubuntu-24.04 --exec bash -lc "docker start ca_org1 ca_org2 ca_orderer couchdb0 couchdb1 orderer.example.com peer0.org1.example.com peer0.org2.example.com && sleep 8 && cd ~/hlf-pr4-variant1 && source scripts/env_org1.sh && peer channel getinfo -c paymentchannel"
echo.
echo Сеть запущена. Теперь запустите 2_ДЕМО.bat
pause
