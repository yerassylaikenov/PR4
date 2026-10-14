# OWASP Smart Contract Top 10 (2025) — базовый маппинг для `payment` v1.0

Список сверен с официальной страницей https://owasp.org/www-project-smart-contract-top-10/ (проверено 2026-10-14): названия SC01–SC10 совпадают с приведёнными ниже, отдельной редакции 2026 года на странице нет.
Список ориентирован на EVM/DeFi, поэтому для Fabric/Go указано, применим ли пункт напрямую, через аналог или неприменим. Полный маппинг с тестами — `owasp-sc-top10-2025-fabric.md` (Задание 2).

| OWASP SC 2025 | Применимость к Fabric/Go | Что сделано в v1.0 (код → `chaincode/payment-v1/chaincode/`) | Что будет усилено в Задании 2 (`paymentsecure`) |
|---|---|---|---|
| SC01 Access Control Vulnerabilities | **прямо применим**: любой член канала может вызвать любую функцию; EP не проверяет вызывающего | проверка MSP вызывающего в каждой изменяющей функции (`CreatePaymentOrder`, `transition()`), `ERR_UNAUTHORIZED`; N2 в `txids.csv` — реальный отказ Org2 | атрибут `role` из Fabric CA, принцип четырёх глаз, `memberOnlyRead/Write`, MSP клиента = MSP peer для private data |
| SC02 Price Oracle Manipulation | **аналог**: доверие к внешним данным в аргументах (курс, сумма) | внешних оракулов нет; сумма — только валидированное целое, неизменяема после создания (I-3) | без изменений; неизменяемость суммы покрыта security-тестом |
| SC03 Logic Errors | **прямо применим** | явная state machine `allowedTransitions()`, терминальные статусы, инварианты I-1…I-5; 24 unit-теста на каждый недопустимый переход; N1 — реальный отказ `ERR_INVALID_TRANSITION` | инварианты INV-1…INV-9, четыре глаза, реквизиты обязательны до Submit |
| SC04 Lack of Input Validation | **прямо применим** | regex ID `^PO-[A-Z0-9-]{4,32}$`, строгий парсинг суммы, whitelist валют и MSP, КНП, длина/UTF-8/управляющие символы reference, reasonCode; 26 табличных тестов | IBAN mod-97, BIC, БИН, лимит размера transient, `DisallowUnknownFields` |
| SC05 Reentrancy Attacks | **аналог**: повторный вход через `InvokeChaincode`; `GetState` не видит `PutState` той же транзакции | cross-chaincode вызовов нет (проверяется `check_determinism.sh`); все проверки состояния выполняются до записи, чтение после записи не используется | правило сохраняется |
| SC06 Unchecked External Calls | **аналог**: непроверенный ответ `InvokeChaincode` | `InvokeChaincode` не используется (правило + автоматическая проверка) | правило сохраняется |
| SC07 Flash Loan Attacks | **неприменим напрямую** (нет займов и ликвидности); аналог — несколько переходов в одной транзакции | одна функция = ровно один переход состояния (`transition()`) | правило сохраняется |
| SC08 Integer Overflow and Underflow | **прямо применим**: `int64` суммы, парсинг строк, float для денег | `parseAmount`: regex без знака/экспоненты/ведущих нулей + `strconv.ParseInt(…,10,64)` + `MaxAmount = 10^14`; float не используется; тест `9223372036854775808` | без изменений |
| SC09 Insecure Randomness | **аналог**: недетерминизм → расхождение RW-set между endorsers | время только из `GetTxTimestamp`, ID задаёт клиент, нет `math/rand`/`crypto/rand`/горутин/сети/итерации по map; `scripts/check_determinism.sh` — 0 находок | соль для хэша реквизитов генерирует **клиент** (transient) |
| SC10 Denial of Service | **прямо применим**: неограниченные range-запросы, большие payload | `GetAllPaymentOrders`: пагинация `pageSize` 1..50, диапазон ключей `[PO-, PO.)`, лимит длины bookmark и reference | лимит размера transient (4 КБ), тест `pageSize=10000` |

Статический анализ v1.0 (`evidence/task1/07_static_analysis.log`): `go vet`, `staticcheck`, `gosec`, `govulncheck` — 0 находок; покрытие 97.0 %.
Найденная при первом деплое ошибка (схема `contractapi` требовала поле `rejectReason`) — это дефект доступности (SC10-аналог: все функции, возвращающие `PaymentOrder`, отказывали при endorsement); исправлена тегом `metadata:",optional"`, добавлен регрессионный тест через `ContractChaincode.Invoke` (`contractapi_test.go`). Лог неудачной попытки: `evidence/task1/attempt1/`.
