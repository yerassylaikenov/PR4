# OWASP Smart Contract Top 10 (2025) — полный маппинг на Hyperledger Fabric / Go chaincode

Источник: https://owasp.org/www-project-smart-contract-top-10/ (сверено 2026-10-14; названия SC01–SC10 совпадают с официальной редакцией 2025). Список создан для EVM/DeFi; для каждого пункта указана применимость к Fabric.

| OWASP SC 2025 | Применимость | Проявление в Fabric / Go chaincode для платёжных поручений | Контроль в `paymentsecure` | Тесты |
|---|---|---|---|---|
| **SC01 Access Control Vulnerabilities** | прямо применим | Org2 переводит чужое поручение в SUBMITTED (**доказано на `paymentvuln`**); пользователь без роли создаёт платёж; чтение реквизитов чужой организацией. Endorsement Policy не проверяет вызывающего | MSP + атрибут `role` (Fabric CA) + принцип четырёх глаз (`approvedByHash ≠ createdByHash`) + `memberOnlyRead/Write` + MSP клиента = MSP peer | SEC-02…06, SEC-13, SEC-17 |
| **SC02 Price Oracle Manipulation** | применим через аналог | оракулов нет; аналог — сумма/курс, которым «доверяют» из аргументов, или их подмена после авторизации | внешних источников цены нет; сумма валидируется и неизменяема после создания (INV-3) | SEC-10, `TestINV3_ImmutableFields` |
| **SC03 Logic Errors** | прямо применим | пропуск ACCEPTED, повторное исполнение, изменение реквизитов после авторизации, Submit без реквизитов | таблица переходов, терминальные статусы, инварианты INV-1…INV-9 | SEC-07, 08, 12, 16 |
| **SC04 Lack of Input Validation** | прямо применим | сумма, валюта, КНП, IBAN, BIC, БИН, transient payload | regex + ParseInt, белые списки, IBAN mod-97, BIC, БИН, лимит 4 КБ, `DisallowUnknownFields`, отказ при данных после JSON | SEC-10, SEC-11 |
| **SC05 Reentrancy Attacks** | применим через аналог | повторный вход через `InvokeChaincode`; `GetState` не видит `PutState` той же транзакции (чтение «своих» записей невозможно) | нет cross-chaincode вызовов; все проверки состояния выполняются до записи; конкурентный доступ разрешает MVCC | SEC-08, MVCC-демо M1/M2 |
| **SC06 Unchecked External Calls** | применим через аналог | непроверенный статус ответа `InvokeChaincode` | `InvokeChaincode` не используется — правило в `CLAUDE.md` и автоматическая проверка `check_determinism.sh` | статический анализ |
| **SC07 Flash Loan Attacks** | неприменим напрямую | займов и пулов ликвидности нет. Аналог — несколько переходов в одной атомарной транзакции (например, Submit+Accept+Settle разом) | одна функция = один переход; составных функций нет | unit-тесты переходов |
| **SC08 Integer Overflow and Underflow** | прямо применим | `int64` суммы, парсинг строк, `float` для денег | `strconv.ParseInt(…,10,64)` с проверкой ошибки, regex без знака/экспоненты, `MaxAmount = 10^14`, без float | SEC-10 (`9223372036854775808`) |
| **SC09 Insecure Randomness** | применим через аналог | недетерминизм → расхождение endorsements; генерация соли/ID в chaincode | `GetTxTimestamp`; соль генерирует **клиент** и передаёт в transient; `crypto/rand` в chaincode отсутствует | `check_determinism.sh` |
| **SC10 Denial of Service** | прямо применим | неограниченные range-запросы, огромный transient, длинные строки | `pageSize` 1..50, диапазон ключей `[PO-, PO.)`, лимит transient 4 КБ, лимиты длины полей | SEC-14, SEC-11 |

## Fabric-специфичные риски вне Top 10

| Риск | Описание | Мера в работе |
|---|---|---|
| Утечка transient к endorsers не-членов коллекции | proposal с transient отправляется всем endorsers, указанным клиентом/Gateway; при AND-политике — и на peer Org2 | отдельная private-only транзакция, collection-level EP `OR('Org1MSP.peer')`, endorse только peer0.org1, chaincode отказывает на peer не из Org1 (SEC-17) |
| Перебор хэша низкоэнтропийных private data | `$$h`-хэш значения виден всем участникам канала и orderer | соль ≥ 32 hex от клиента (SEC-13: неверная соль → `match=false`) |
| Private data в логах peer / chaincode | отладочный вывод реквизитов | chaincode ничего не логирует; проверка `docker logs` всех контейнеров — 0 совпадений (SEC-15) |
| Раскрытие данных в текстах ошибок | ошибки возвращаются клиенту и пишутся в логи peer | тексты содержат только имя поля, без значения (unit-тест `TestTransientValidation`) |
| Phantom reads в range-запросах | результат range-запроса, использованный для записи, проверяется при валидации (`PHANTOM_READ_CONFLICT`); rich queries CouchDB вообще не перепроверяются | range/rich-запросы используются только в evaluate-функциях, их результат не участвует в записи (Задание 3: `GetPaymentOrdersByStatus`) |
| Endorsement Policy ≠ авторизация | EP AND выполнена даже при атаке (V2) | авторизация в chaincode; [Рек] state-based endorsement для отдельных ключей |
