# CLAUDE.md — правила репозитория ПР №4 (Вариант 1 «Банковские операции»)

Действуют во всех сессиях (Задания 1–4).

1. **Никаких выдуманных результатов.** TxID, Package ID, высоты блоков, хэши и выводы команд берутся только из реально выполненных команд. Если что-то не работает — диагностировать и исправлять, не имитировать. В отчёте запрещён «пример вывода».
2. **Секреты.** Никогда не выводить в терминал, логи, отчёт или git: закрытые ключи (`*_sk`, `priv_sk`, каталоги `keystore/`), PEM-блоки `PRIVATE KEY`, пароли CA и enrollment secrets, пароли CouchDB, содержимое `organizations/`. Публичные сертификаты целиком в отчёт не вставлять — только subject, issuer, MSP ID. Каждый лог перед сохранением проходит через `scripts/redact.sh`. `.gitignore` — первый коммит.
3. **Скрипты вместо ручных команд.** Каждый шаг — bash-скрипт в `scripts/` (`#!/usr/bin/env bash`, `set -euo pipefail`, идемпотентность). Вывод сохраняется в `evidence/taskN/<шаг>.log` через `tee` и redaction (`scripts/lib.sh` → `start_log`). Шапка каждого лога: команда, дата и время, MSP ID и имя пользователя (без путей к ключам).
4. **Версии.** Последний patch Fabric 3.1.x и Fabric CA 1.5.x определяется через GitHub Releases API (`scripts/01_install_fabric.sh`). Версии Go-зависимостей chaincode — из `fabric-samples/asset-transfer-basic/chaincode-go/go.mod`. Документация задания (release-2.5) сверяется с веткой `latest` (3.x).
5. **Не уничтожать доказательства.** Не выполнять `./network.sh down`, `docker volume prune`, `docker system prune` без явного подтверждения пользователя. Сеть Задания 1 живёт до пункта 3.6 включительно.
6. **OWASP Smart Contract Top 10 (2025)** — обязательный стандарт безопасного кода chaincode. Каждое защитное решение в коде помечается комментарием вида `// OWASP SC04:2025 — input validation`.
7. **Детерминизм chaincode** (SC09): никаких `time.Now`, `math/rand`, `crypto/rand`, горутин, сетевых вызовов, итерации по map с выводом — проверяется `scripts/check_determinism.sh`.
8. **Язык.** Код, идентификаторы и комментарии — на английском; отчёт и документация — на русском.
9. **Sudo.** Команды, требующие `sudo`, выполняет пользователь.

## Карта репозитория

- `scripts/lib.sh` — общие пути, цветной вывод (✔/✘), `start_log` (tee + redaction), переключение организаций.
- `scripts/env_org1.sh`, `scripts/env_org2.sh` — CLI-окружение (`source`), пользователь через `ORG_USER`.
- `scripts/lifecycle.sh` — явный lifecycle chaincode (package → install → approve → readiness → commit).
- `chaincode/payment-v1`, `payment-vuln`, `payment-secure`, `payment-v2` — Go chaincode.
- `evidence/taskN/` — логи после redaction; `docs/report/` — отчёт.
- `scripts/demo.sh` — сквозная демонстрация с галочками для защиты.
