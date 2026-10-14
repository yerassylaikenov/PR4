# Claude Code · Задание 1 — Корпоративная сеть Hyperledger Fabric и chaincode `payment` (ПР №4, Вариант 1)

## 0. Роль и цель

Ты — senior-инженер по Hyperledger Fabric и безопасности смарт-контрактов. Полностью выполни **Задание 1** практической работы №4 «Разработка, обеспечение безопасности и обновление корпоративной блокчейн-сети Hyperledger Fabric». Каждое требование должно подтверждаться реально выполненными командами, их выводом и артефактами в репозитории. Параллельно ты закладываешь основу для Заданий 2 и 3, которые будут выполняться в следующих сессиях по этому же репозиторию.

Работай итеративно: план → реализация шага → проверка вывода → следующий шаг. Перед началом покажи план и дождись подтверждения.

## 1. Контекст варианта

| Параметр | Значение |
|---|---|
| Студент | Айкенов Е.Ә., группа SSE-2502, Astana IT University, School of Cybersecurity |
| Вариант | 1 — Банковские операции |
| Org1 | Банк-отправитель (Sender Bank), MSP ID `Org1MSP` |
| Org2 | Банк-получатель (Receiver Bank), MSP ID `Org2MSP` |
| Бизнес-объект | `PaymentOrder` (платёжное поручение) |
| Конфиденциальные данные | Расчётные реквизиты: IBAN плательщика и получателя, BIC, БИН/ИИН, наименование получателя (используются в Задании 2, в v1.0 их **нет**) |
| Channel | `paymentchannel` |
| Основной chaincode | `payment`, Go, version `1.0`, sequence `1` |
| Endorsement Policy | `AND('Org1MSP.peer','Org2MSP.peer')` |
| Среда | Linux или WSL2 (Ubuntu), Docker + Compose v2, Go, Hyperledger Fabric **3.1.x**, Fabric CA 1.5.x |

## 2. Неприкосновенные правила

Первым делом создай `CLAUDE.md` в корне репозитория и запиши туда эти правила (они должны действовать и в сессиях Заданий 2–4):

1. **Никаких выдуманных результатов.** TxID, Package ID, высоты блоков, хэши и выводы команд берутся только из реально выполненных команд. Если что-то не работает — диагностируй и исправляй, не имитируй. В отчёте запрещён «пример вывода».
2. **Секреты.** Никогда не выводи в терминал, логи, отчёт или git: закрытые ключи (`*_sk`, `priv_sk`, каталоги `keystore/`), PEM-блоки `PRIVATE KEY`, пароли CA и enrollment secrets, пароли CouchDB, содержимое `organizations/`. Публичные сертификаты целиком в отчёт не вставлять — только subject, issuer, MSP ID. Каждый лог перед сохранением проходит через `scripts/redact.sh`. `.gitignore` — первый коммит.
3. **Скрипты вместо ручных команд.** Каждый шаг — bash-скрипт в `scripts/` (`#!/usr/bin/env bash`, `set -euo pipefail`, идемпотентность). Вывод сохраняется в `evidence/taskN/<шаг>.log` через `tee` и redaction. Шапка каждого лога: команда, дата и время, MSP ID и имя пользователя (без путей к ключам).
4. **Версии.** Последний patch Fabric 3.1.x и Fabric CA 1.5.x определяй через GitHub Releases API, не угадывай. Версии Go-зависимостей chaincode бери из `fabric-samples/asset-transfer-basic/chaincode-go/go.mod` (`fabric-contract-api-go/v2`, `fabric-chaincode-go/v2`). Ссылка в задании ведёт на документацию release-2.5 — сверяйся с веткой `latest` (3.x) и отмечай различия.
5. **Не уничтожать доказательства.** Не выполнять `./network.sh down`, `docker volume prune`, `docker system prune` без явного подтверждения пользователя. Сеть Задания 1 должна жить до пункта 3.6 включительно.
6. **OWASP Smart Contract Top 10 (2025)** — обязательный стандарт безопасного кода chaincode (раздел 7). Каждое защитное решение в коде помечается комментарием вида `// OWASP SC04:2025 — input validation`.
7. **Детерминизм chaincode** (раздел 7, SC09) — нарушение приводит к расхождению RW-set между endorsers.
8. **Язык.** Код, идентификаторы и комментарии — на английском; отчёт и документация — на русском.
9. **Sudo.** Команды, требующие `sudo`, не выполняй сам — попроси пользователя.

## 3. Структура репозитория

```
hlf-pr4-variant1/
├── CLAUDE.md                    # правила из раздела 2
├── README.md                    # как воспроизвести всё с нуля
├── .gitignore                   # fabric-samples/, organizations/, *_sk, keystore/, .secrets/, *.block, *.tar.gz, vendor/
├── prompts/                     # эти промпты
├── fabric-samples/              # клонируется install-fabric.sh (в .gitignore)
├── chaincode/
│   └── payment-v1/              # Go module, chaincode payment v1.0
├── client/                      # Go-приложение на fabric-gateway
├── scripts/                     # env, сеть, lifecycle, транзакции, анализ, redaction
├── evidence/task1/              # логи (после redaction), txids.csv, decoded-фрагменты блоков
└── docs/
    ├── architecture/            # architecture_variant1.drawio (уже есть) + PNG + README.md
    ├── security/                # owasp-sc-baseline-v1.md
    ├── chaincode/               # спецификация payment v1.0, диаграмма состояний
    └── report/                  # 01_task1.md, screenshots/task1/
```

## 4. Шаги

### Шаг 1. Проверка окружения

`scripts/00_check_env.sh`: ОС (и признак WSL), `docker version`, `docker compose version`, `go version`, `git`, `jq`, `curl`, свободное место, права на docker без sudo, наличие Docker Desktop WSL-интеграции. Если чего-то не хватает — выведи точные команды установки и попроси пользователя выполнить их.

### Шаг 2. Установка Fabric 3.1.x

`scripts/01_install_fabric.sh`: определи последние версии 3.1.x и CA 1.5.x через `api.github.com/repos/hyperledger/fabric/releases` и `.../fabric-ca/releases`, скачай официальный `install-fabric.sh`, выполни его с `--fabric-version` и `--ca-version` для компонентов `docker samples binary`. Проверь `peer version`, `orderer version`, `fabric-ca-client version`, `configtxlator version`, `docker images | grep hyperledger`. Сохрани в `evidence/task1/01_versions.log`.

### Шаг 3. Сеть (задание 1.1)

`scripts/02_network_up.sh` на базе `fabric-samples/test-network`:

```bash
./network.sh up createChannel -c paymentchannel -ca -s couchdb
```

- `-ca` — идентичности выпускает Fabric CA (требование задания), `-s couchdb` — World State в CouchDB (наглядно для 1.6 и 1.7, нужен для rich queries в Задании 3).
- Проверь и залогируй: `docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}'` (2 peer, orderer, 3 CA, 2 CouchDB), `peer channel list` от имени каждой организации, `peer channel getinfo -c paymentchannel`, `osnadmin channel list` (ordering service знает канал).
- Зафиксируй соответствие ролей: Org1 = Банк-отправитель, Org2 = Банк-получатель (домены test-network `org1.example.com` / `org2.example.com` не переименовывай — так надёжнее).

### Шаг 4. CLI-окружение и административная идентичность Org1 (задание 1.2)

Создай `scripts/env_org1.sh` и `scripts/env_org2.sh` (через `source`), повторяющие логику `test-network/scripts/envVar.sh`: `PATH`, `FABRIC_CFG_PATH`, `CORE_PEER_TLS_ENABLED=true`, `CORE_PEER_LOCALMSPID`, `CORE_PEER_TLS_ROOTCERT_FILE`, `CORE_PEER_MSPCONFIGPATH` (Admin@org1.example.com), `CORE_PEER_ADDRESS`, `ORDERER_CA`, а также переменные с TLS-корнями обоих peers для `--peerAddresses`. Параметр `ORG_USER` позволяет переключать пользователя (понадобится в Задании 2).

Докажи, что окружение Org1 работает с Peer и с Ordering Service:
- `peer channel list`, `peer channel getinfo -c paymentchannel` — работа с Peer;
- `peer channel fetch config` через orderer — работа с Ordering Service;
- сведения об идентичности: subject и issuer сертификата администратора через `openssl x509 -noout -subject -issuer -dates` (не печатай ключ и сам PEM), наличие роли admin в NodeOUs (`config.yaml`).

Лог — `evidence/task1/04_cli_env_org1.log`.

### Шаг 5. Архитектурная схема (задание 1.3, пункт 2 отчёта)

Файл `docs/architecture/architecture_variant1.drawio` уже лежит в репозитории (3 листа: архитектура с доверительными границами TB1–TB6, поток транзакции + PDC, стенд SmartBFT). На этом шаге:
1. Сверь первый лист с реальной сетью: имена контейнеров, порты, имена CA (`ca-org1` / `ca-org2` / `ca-orderer`), версия Fabric, имя CouchDB. Если что-то расходится — исправь подписи прямо в XML (атрибут `value`), не меняя `id` ячеек и геометрию.
2. Убедись, что на схеме есть все компоненты, требуемые отчётом: Organizations, Peer, Ordering Service, Fabric CA, MSP, Gateway, Channel, Chaincode, Ledger, а также пользователи системы (initiator1, approver1, processor2, администраторы организаций и Ordering Service, внешние клиенты банков вне Fabric).
3. Экспорт в PNG: если установлен draw.io desktop — `drawio -x -f png -p 0 -o docs/architecture/01_architecture.png docs/architecture/architecture_variant1.drawio` (и `-p 1`, `-p 2` для остальных листов). Если нет — попроси пользователя сделать экспорт вручную (File → Export as → PNG). Не генерируй PNG иными средствами.
4. `docs/architecture/README.md`: таблица «компонент → контейнер → порт → MSP → роль в варианте 1» и короткое описание доверительных границ TB1–TB6 (они понадобятся для STRIDE в Задании 2).

### Шаг 6. Chaincode `payment` v1.0 (задание 1.3)

Go, `fabric-contract-api-go/v2`, каталог `chaincode/payment-v1`. Сначала напиши спецификацию в `docs/chaincode/payment-v1-spec.md` (модель, функции, матрица авторизации, диаграмма состояний в Mermaid, инварианты), затем код.

**Модель** — имена JSON-полей в Задании 3 менять запрещено (совместимость World State):

```go
type PaymentOrder struct {
    DocType         string `json:"docType"`         // всегда "PaymentOrder"
    ID              string `json:"id"`              // ^PO-[A-Z0-9-]{4,32}$
    SenderBankMSP   string `json:"senderBankMSP"`   // = MSP вызывающего при создании (Org1MSP)
    ReceiverBankMSP string `json:"receiverBankMSP"` // из белого списка, != sender
    Amount          int64  `json:"amount"`          // в минимальных единицах (тиын), 1..MaxAmount
    Currency        string `json:"currency"`        // ISO 4217, белый список: KZT, USD, EUR, RUB, CNY
    PurposeCode     string `json:"purposeCode"`     // КНП, ^[0-9]{3}$
    Reference       string `json:"reference"`       // назначение платежа, ≤ 140 рун, без управляющих символов
    Status          string `json:"status"`          // CREATED|SUBMITTED|ACCEPTED|REJECTED|SETTLED|CANCELLED
    RejectReason    string `json:"rejectReason,omitempty"`
    CreatedByHash   string `json:"createdByHash"`   // sha256(cid.GetID()) — без персональных данных в публичном state
    CreatedAt       string `json:"createdAt"`       // из stub.GetTxTimestamp(), RFC3339
    UpdatedAt       string `json:"updatedAt"`
    LastTxID        string `json:"lastTxId"`
}
```

**Функции** (≥ 6 требуемых операций — с запасом):

| Функция | Тип | Кто вправе | Переход | Требование задания |
|---|---|---|---|---|
| `CreatePaymentOrder(id, receiverBankMSP, amount, currency, purposeCode, reference)` | submit | Org1MSP | ∅ → CREATED | создание объекта |
| `ReadPaymentOrder(id)` | evaluate | члены канала | — | чтение |
| `SubmitPaymentOrder(id)` | submit | MSP == senderBankMSP | CREATED → SUBMITTED | изменение состояния |
| `AcceptPaymentOrder(id)` | submit | MSP == receiverBankMSP | SUBMITTED → ACCEPTED | изменение состояния |
| `RejectPaymentOrder(id, reasonCode)` | submit | MSP == receiverBankMSP | SUBMITTED → REJECTED | изменение состояния |
| `SettlePaymentOrder(id)` | submit | MSP == receiverBankMSP | ACCEPTED → SETTLED | **основная бизнес-операция** (исполнение платежа) |
| `CancelPaymentOrder(id)` | submit | MSP == senderBankMSP | CREATED / SUBMITTED → CANCELLED | изменение состояния |
| `PaymentOrderExists(id)` | evaluate | члены канала | — | проверка существования |
| `GetAllPaymentOrders(pageSize, bookmark)` | evaluate | члены канала | — | список объектов (пагинация) |
| `GetPaymentOrderHistory(id)` | evaluate | члены канала | — | история ключа (`GetHistoryForKey`) |

Требования к реализации:
- Таблица допустимых переходов — единственный источник истины (map `from → []to`), любые другие переходы отклоняются ошибкой с понятным кодом (`ERR_INVALID_TRANSITION`, `ERR_UNAUTHORIZED`, `ERR_VALIDATION`, `ERR_NOT_FOUND`, `ERR_ALREADY_EXISTS`).
- SETTLED, REJECTED, CANCELLED — терминальные статусы.
- Неизменяемость: `amount`, `currency`, `receiverBankMSP`, `senderBankMSP` после создания не меняются никакой функцией.
- События (`SetEvent`) на создание и исполнение — без чувствительных данных в payload.
- Ошибки не раскрывают внутреннее состояние сверх необходимого.

### Шаг 7. Тесты и статический анализ

- Unit-тесты с моками (подход `counterfeiter` как в `fabric-samples/asset-transfer-basic/chaincode-go/chaincode/mocks`): happy path полного цикла; каждый недопустимый переход; каждая функция от «чужого» MSP; табличные тесты валидации (пустые строки, пробелы, `-1`, `0`, `1e3`, `+5`, `9223372036854775808`, неизвестная валюта, неверный КНП, длинная reference, управляющие символы); дубликат ID; пагинация с `pageSize` вне диапазона. Покрытие пакета chaincode ≥ 80% (`go test -cover`).
- `go vet`, `staticcheck`, `gosec`, `govulncheck` (установи через `go install`, логи в `evidence/task1/07_static_analysis.log`; каждую находку исправь или обоснуй).
- `scripts/check_determinism.sh`: поиск `time.Now`, `math/rand`, `crypto/rand`, `go func`, `os.Getenv`, `net/http`, глобальных изменяемых `var`, итерации по `map` с выводом в ответ/state. Ожидаемый результат — 0 находок либо обоснование.

### Шаг 8. Деплой `payment` 1.0 / seq 1 с AND-политикой (задание 1.4)

`scripts/lifecycle.sh` — **явный** жизненный цикл, без `network.sh deployCC` (он понадобится в Задании 3, параметры: имя, путь, version, sequence, label, опционально collections-config):

1. `go mod tidy && go mod vendor` в каталоге chaincode;
2. `peer lifecycle chaincode package payment_1.0.tar.gz --path ... --lang golang --label payment_1.0`;
3. `peer lifecycle chaincode calculatepackageid` → Package ID;
4. `install` на peer0.org1 и peer0.org2, `queryinstalled` на обоих;
5. `approveformyorg` от Org1 и от Org2: `--version 1.0 --sequence 1 --signature-policy "AND('Org1MSP.peer','Org2MSP.peer')"`;
6. `checkcommitreadiness --output json` — после первого и после второго approve (показать переход `Org2MSP: false → true`);
7. `commit` с `--peerAddresses` обоих peers;
8. `querycommitted --channelID paymentchannel --name payment --output json` — подтвердить `version 1.0`, `sequence 1`, политику AND и approvals обеих организаций.

Важно: `--signature-policy` передавать идентично в approve, checkcommitreadiness и commit, иначе определение не совпадёт. Логи — `evidence/task1/08_lifecycle_*.log`.

### Шаг 9. Клиентское приложение на Fabric Gateway

`client/` — минимальное Go-приложение на `github.com/hyperledger/fabric-gateway/pkg/client` (шаблон — `fabric-samples/asset-transfer-basic/application-gateway-go`): подключение по gRPC+TLS к peer0.org1, `Submit` и `Evaluate`, вывод TxID и статуса commit. Ключ читается из keystore, но никогда не печатается и не логируется. Через это приложение выполни как минимум одну транзакцию шага 10 — это делает компонент Gateway на архитектурной схеме реальным, а не декоративным.

### Шаг 10. Транзакции с TxID (задание 1.5)

`scripts/10_transactions.sh` — каждая транзакция через `peer chaincode invoke ... --waitForEvent` (TxID и статус берутся из строки `txid [...] committed with status (VALID)`) или через Gateway-клиент. Результат дописывается в `evidence/task1/txids.csv`: `n, function, args, invoker (MSP/user), txid, block, validation_code`. Номер блока определяй через `qscc GetBlockByTxID` + `configtxlator proto_decode`, а не по догадке.

Минимальный сценарий:

| # | Операция | От имени | Ожидание |
|---|---|---|---|
| T1 | Create `PO-0001` (5 000 000 тиын, KZT, КНП 119) | Org1 | VALID |
| T2 | Submit `PO-0001` | Org1 | VALID |
| T3 | Accept `PO-0001` | Org2 | VALID |
| T4 | Settle `PO-0001` — основная бизнес-операция | Org2 | VALID |
| T5 | Create `PO-0002` | Org1 | VALID |
| T6 | Cancel `PO-0002` | Org1 | VALID |
| T7 | Create `PO-0003` (остаётся в CREATED — нужен в Задании 3) | Org1 | VALID |
| N1 | Settle `PO-0003` (недопустимый переход) | Org2 | отказ на этапе endorsement, в ledger не попадает |
| N2 | Create `PO-0004` | Org2 | отказ (`ERR_UNAUTHORIZED`) |

Опционально (сильный плюс к защите, контрольный вопрос 1): **демонстрация MVCC** — два параллельных `Submit`/`Cancel` одного ключа с `PO-0005` так, чтобы они попали в один блок; одна транзакция получит `MVCC_READ_CONFLICT`. Зафиксируй оба TxID и коды валидации.

### Шаг 11. Разбор одной транзакции по этапам

`scripts/analyze_tx.sh <txid>` → `evidence/task1/tx_anatomy_<txid>.md`. Разбирай T4 (Settle). Источники: блок из `qscc GetBlockByTxID` (вывод `peer chaincode query` с флагом `--hex` → `xxd -r -p` → `configtxlator proto_decode --type common.Block`), `peer channel getinfo`, логи `docker logs peer0.org1.example.com`.

| Этап | Что извлечь и показать |
|---|---|
| Proposal | `tx_id`, timestamp, тип `ENDORSER_TRANSACTION`, канал, chaincode, функция и аргументы (декодировать base64), MSP ID создателя; пояснить, что TxID = hash(nonce ‖ creator) |
| Endorsement | список endorsers (Org1MSP, Org2MSP), статус ответа 200, Read Set (ключ + версия `block_num/tx_num`) и Write Set (ключ, размер значения), событие chaincode; подписи — только факт наличия |
| Ordering | номер блока, позиция транзакции в блоке, `data_hash`, `previous_hash`, подпись orderer в metadata (MSP ID) |
| Validation | код из `TRANSACTIONS_FILTER` для индекса транзакции (0 = VALID), какие проверки прошли (EP, MVCC) |
| Commit | строка `Committed block [N]` в логе peer, высота после commit, `ReadPaymentOrder` показывает SETTLED, `GetPaymentOrderHistory` содержит этот TxID |

Сертификаты из блока в отчёт не копировать — только MSP ID и subject.

### Шаг 12. Текущее состояние объектов (задание 1.6)

`ReadPaymentOrder` для PO-0001…PO-0003, `GetAllPaymentOrders` с пагинацией, `GetPaymentOrderHistory(PO-0001)` (видны все 4 TxID T1–T4). Дополнительно: содержимое базы `paymentchannel_payment` в CouchDB через `curl` (учётные данные — из переменных окружения, в лог не попадают) — показать документ и поле `~version`. Сравнительная таблица «ожидаемый статус / фактический статус».

### Шаг 13. Исследование Ledger (задание 1.7)

`scripts/13_ledger_info.sh`:
- `peer channel getinfo -c paymentchannel` → высота, `currentBlockHash`, `previousBlockHash`;
- `peer channel fetch newest` → decode → номер, `data_hash`, `previous_hash`, количество транзакций, их TxID и коды валидации;
- **проверка связности:** `previous_hash` последнего блока совпадает с `previousBlockHash` из `getinfo`; дополнительно получить блок N-1 и показать связь с блоком N;
- блок 0 (genesis / config): кратко — что в нём (конфигурация канала, MSP организаций, политики, capabilities).

Объяснение «Blockchain vs World State» (в отчёт) должно опираться на ваши данные: Blockchain — неизменяемый журнал всех транзакций, включая невалидные (если есть MVCC-демо, показать, что невалидная транзакция лежит в блоке, но не изменила state); World State — текущие значения ключей в CouchDB, производная от Blockchain, может быть пересобран из блоков; History DB — индекс изменений ключа.

### Шаг 14. Базовый маппинг OWASP SC Top 10 (2025) для v1.0

Сверь актуальный список на https://owasp.org/www-project-smart-contract-top-10/ (если названия отличаются от приведённых ниже — используй официальные и отметь это). `docs/security/owasp-sc-baseline-v1.md`: для каждого пункта — применимость к Fabric/Go, что сделано в v1.0, что будет усилено в Задании 2.

| OWASP SC 2025 | Аналог в Fabric / Go | Что требуется уже в v1.0 |
|---|---|---|
| SC01 Access Control Vulnerabilities | нет проверки MSP / роли вызывающего | проверка MSP в каждой изменяющей функции |
| SC02 Price Oracle Manipulation | доверие к внешним данным, пришедшим в аргументах | внешних оракулов нет; курсы и суммы — только валидированные входные данные |
| SC03 Logic Errors | недопустимые переходы, нарушение инвариантов | явная state machine, инварианты неизменяемости |
| SC04 Lack of Input Validation | любые аргументы транзакции | строгая валидация всех аргументов |
| SC05 Reentrancy Attacks | `InvokeChaincode`; отсутствие read-your-writes в одной транзакции | нет cross-chaincode вызовов; не полагаться на GetState после PutState в той же транзакции |
| SC06 Unchecked External Calls | непроверенный статус `InvokeChaincode` | не используется; правило зафиксировано |
| SC07 Flash Loan Attacks | атомарные многошаговые операции в одной транзакции | неприменимо напрямую; одна транзакция — один переход состояния |
| SC08 Integer Overflow and Underflow | `int64`, парсинг сумм, `float` для денег | `strconv.ParseInt` со строгой проверкой, диапазон, запрет float |
| SC09 Insecure Randomness | недетерминизм: `time.Now`, rand, порядок map | `GetTxTimestamp`, детерминированные ID, `check_determinism.sh` |
| SC10 Denial of Service | неограниченные range-запросы, большие payload | пагинация с потолком `pageSize`, лимиты длины полей |

### Шаг 15. Раздел отчёта

`docs/report/01_task1.md` (русский), покрывает пункты 1–3 итогового отчёта:
1. Цель работы и описание предметной области варианта 1 (роли банков, жизненный цикл платёжного поручения, почему нужен permissioned-реестр и AND-политика).
2. Архитектура: PNG первого листа + таблица компонентов + описание потока ①–⑥.
3. Chaincode: таблица функций, матрица авторизации, диаграмма состояний, Endorsement Policy, вывод `querycommitted`, таблица транзакций с TxID, разбор T4 по этапам, состояние объектов, исследование Ledger, Blockchain vs World State, базовый OWASP-маппинг.

Места для скриншотов — `![...](screenshots/task1/NN_name.png)` с подписью «Рисунок N — …».

## 5. Скриншоты, которые пользователь делает вручную

Сохрани список в `docs/report/screenshots/task1/CHECKLIST.md`:
1. `docker ps` — все контейнеры сети.
2. `peer version` и `peer channel list` в окружении Org1.
3. `querycommitted` для `payment` (version 1.0, sequence 1, политика AND).
4. Терминал с транзакциями T1–T4 и строками `committed with status (VALID)`.
5. Отказ N1 и N2.
6. `ReadPaymentOrder PO-0001` и `GetPaymentOrderHistory`.
7. `peer channel getinfo` и decoded-фрагмент последнего блока.
8. CouchDB Fauxton (`http://localhost:5984/_utils`) с документом PO-0001 — **без** видимого пароля.
9. Архитектурная схема.

Перед скриншотами проверь, что в кадр не попадают ключи и пароли.

## 6. Definition of Done

- [ ] `CLAUDE.md`, `.gitignore`, `README.md` созданы; в git нет `organizations/`, ключей и `fabric-samples/`.
- [ ] Версии Fabric 3.1.x и CA 1.5.x зафиксированы в логе.
- [ ] Сеть: 2 организации, 2 peer, orderer, 3 Fabric CA, CouchDB, канал `paymentchannel`.
- [ ] Окружение Org1 Admin работает с Peer и с Ordering Service (лог).
- [ ] drawio сверен с реальной сетью, PNG экспортированы или запрошены у пользователя.
- [ ] Chaincode: ≥ 6 операций, валидация, state machine, unit-тесты ≥ 80%, статический анализ чистый или обоснован.
- [ ] `querycommitted`: version 1.0, sequence 1, `AND('Org1MSP.peer','Org2MSP.peer')`, approvals обеих org.
- [ ] ≥ 4 VALID-транзакции с реальными TxID в `txids.csv`, хотя бы одна через Gateway-клиент.
- [ ] Разбор T4 по 5 этапам с данными из реального блока.
- [ ] Состояние объектов и Ledger (высота, последний блок, проверка связности) задокументированы.
- [ ] `docs/report/01_task1.md` готов, все числа совпадают с evidence.
- [ ] `scripts/redact.sh` прогнан по `evidence/`; поиск по `PRIVATE KEY|_sk|adminpw|secret` пуст.
- [ ] Сеть **оставлена запущенной** для Задания 2.

В конце выведи краткую сводку: что сделано, где лежат доказательства, какие скриншоты нужны от пользователя, известные ограничения.
