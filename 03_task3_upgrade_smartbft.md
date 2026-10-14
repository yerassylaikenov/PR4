# Claude Code · Задание 3 — Обновление chaincode `payment` 1.0 → 2.0 и отказоустойчивость SmartBFT (ПР №4, Вариант 1)

## 0. Роль и цель

Ты — инженер эксплуатации и безопасности Hyperledger Fabric. Выполни **Задание 3**: контролируемое обновление основного chaincode `payment` с version 1.0 / sequence 1 до version 2.0 / sequence 2 с доказательством сохранности World State, план обновления инфраструктуры Fabric 2.5 → 3.1.x и эксперимент с SmartBFT Ordering Service при отказе одного orderer.

Прочитай `CLAUDE.md` — правила действуют (реальные выводы, никаких секретов, скрипты + `redact.sh`). Покажи план и дождись подтверждения. **Шаги 1–7 выполняются на основной сети; шаг 9 (SmartBFT) требует её остановки и выполняется только после явного «да» пользователя.**

## 1. Снимок исходного состояния (задание 3.1)

`scripts/30_pre_upgrade_snapshot.sh` → `evidence/task3/30_pre_upgrade/`:
- `peer lifecycle chaincode querycommitted --channelID paymentchannel --name payment --output json` → должно быть **Version 1.0, Sequence 1**, политика AND, approvals обеих org. Если нет — остановись и сообщи.
- `peer lifecycle chaincode queryinstalled` на обоих peers → Package ID `payment_1.0:...`.
- `ReadPaymentOrder` для PO-0001 (SETTLED), PO-0002 (CANCELLED), PO-0003 (CREATED); `GetAllPaymentOrders` (все страницы) → `state_v1.json` с ключами, отсортированными через `jq -S`, и его `sha256sum`.
- `GetPaymentOrderHistory(PO-0001)`, `peer channel getinfo` (высота до обновления).
- `docker ps --filter name=dev-peer` — контейнеры chaincode 1.0.
- Сохрани **реальный** JSON PO-0001 и PO-0003 как golden-фикстуры `chaincode/payment-v2/testdata/v1_*.json` для unit-тестов совместимости.

## 2. Chaincode 2.0 (задание 3.2)

Каталог `chaincode/payment-v2` — эволюция `payment-v1` (не `paymentsecure`: обновляется основной chaincode). Сначала `docs/upgrade/payment-v2-compat.md`, затем код.

**Правила совместимости с World State версии 1.0** (каждое — в документе с обоснованием):
1. Формат ключей не меняется (`PO-...`, без перехода на composite keys).
2. JSON-поля v1.0 не переименовываются, не удаляются и не меняют тип (`amount` остаётся `int64` в минимальных единицах).
3. Новые поля только с `omitempty` и безопасным значением по умолчанию.
4. Ленивая миграция: объект без `schemaVersion` читается как версия 1; при первой записи через v2.0 получает `schemaVersion: 2`. Массовой миграции в `Init` нет, `--init-required` не включается — определение chaincode в этой части не меняется.
5. Существующие статусы и переходы сохраняются; новые только добавляются.
6. Сигнатуры и семантика функций v1.0 не меняются — старые клиенты продолжают работать.

**Новая функциональность v2.0** (вариант по умолчанию, можно предложить лучший, сохранив требования):
- новые поля: `schemaVersion int`, `valueDate string` (дата валютирования, `omitempty`), `returnReason string` (`omitempty`), `returnedAt string`;
- новая функция `ReturnPaymentOrder(id, reasonCode)`: SETTLED → RETURNED, только банк-получатель (возврат платежа, например, при закрытом счёте получателя); RETURNED — терминальный статус; исполненный платёж возвращается не более одного раза;
- новая функция `GetPaymentOrdersByStatus(status, pageSize, bookmark)` — rich query по CouchDB с индексом `META-INF/statedb/couchdb/indexes/indexStatus.json`; `pageSize` 1..50 (OWASP SC10), статус из белого списка (SC04 — не допускать инъекцию в селектор);
- `CreatePaymentOrder` v2.0 по-прежнему принимает прежние 6 аргументов; `valueDate` задаётся отдельной функцией `SetValueDate(id, date)` (только отправитель, только CREATED) — чтобы не ломать сигнатуру.

**OWASP SC Top 10 (2025) для обновления** — `docs/upgrade/owasp-upgrade-review.md`: для каждой новой или изменённой функции проверь SC01 (авторизация на Return / SetValueDate), SC03 (новые переходы не открывают путь в обход SETTLED; RETURNED нельзя повторить), SC04 (reasonCode, дата, статус в селекторе), SC08, SC09 (детерминизм rich query: результат не используется для записи — phantom reads), SC10 (пагинация).

Тесты: все unit-тесты v1.0 проходят без изменений на v2.0 (регрессия); тесты чтения golden-фикстур v1; тесты ленивой миграции; тесты новых функций, включая негативные. `go vet` / `staticcheck` / `gosec` / `govulncheck` / `check_determinism.sh`.

Package: `go mod vendor`, `peer lifecycle chaincode package payment_2.0.tar.gz --label payment_2.0`, `calculatepackageid` → **Package ID 2.0** в лог.

## 3. Установка на оба peers (задание 3.3)

`install` на peer0.org1 и peer0.org2, `queryinstalled` на обоих — видны оба пакета (1.0 и 2.0). Отметь в отчёте: установка пакета сама по себе ничего не меняет в канале — код начнёт исполняться только после commit нового определения.

## 4. Утверждение определения (задание 3.4)

`approveformyorg` от Org1, затем от Org2: `--name payment --version 2.0 --sequence 2 --package-id <2.0> --signature-policy "AND('Org1MSP.peer','Org2MSP.peer')"`.

- Политика передаётся **явно и идентично**: если её опустить, определение получит политику по умолчанию, и это молча изменит модель доверия.
- Collections-config у `payment` нет — не добавляй.
- `checkcommitreadiness --output json` после approve Org1 (`Org1MSP: true, Org2MSP: false`) и после approve Org2 (оба `true`).
- Дополнительные негативные демонстрации (короткие, в отдельный лог, для контрольного вопроса 4):
  - approve с `--sequence 3` → ошибка (sequence должен расти ровно на 1);
  - `checkcommitreadiness` с другой политикой → в readiness видно несовпадение.

## 5. Commit и проверка (задание 3.5)

`commit` с `--peerAddresses` обоих peers → `querycommitted` → **Version 2.0, Sequence 2**, политика AND без изменений, approvals обеих организаций. Первый invoke запускает контейнеры `dev-peer*-payment_2.0-*` — покажи `docker ps` до и после. Логи — `evidence/task3/35_commit.log`.

## 6. Проверка обратной совместимости (задание 3.6, часть 1)

`scripts/36_compat_check.sh` → `evidence/task3/36_compat.log` и `evidence/task3/compat_table.md`:

| Проверка | Действие через v2.0 | Ожидание |
|---|---|---|
| C1 | `ReadPaymentOrder(PO-0001)` (создан и исполнен v1.0) | данные идентичны снимку v1, `schemaVersion` отсутствует или трактуется как 1 |
| C2 | `GetAllPaymentOrders` → `state_after.json`, сравнение с `state_v1.json` | идентичны до первой записи через v2.0 (сравнение `sha256` и `diff`) |
| C3 | Старая операция: Submit → Accept → Settle для `PO-0003` (создан v1.0) | VALID, TxID; после записи `schemaVersion: 2` |
| C4 | Новая операция: `ReturnPaymentOrder(PO-0001)` | VALID, статус RETURNED, TxID |
| C5 | Повторный Return `PO-0001` | отказ |
| C6 | `GetPaymentOrdersByStatus("SETTLED")` | находит PO-0003 |
| C7 | Создание нового `PO-0006` через v2.0 и полный цикл | VALID |
| C8 | `GetPaymentOrderHistory(PO-0001)` | в одной истории TxID, сделанные v1.0 (T1–T4), и TxID Return, сделанный v2.0 |
| C9 | Return от Org1 (не получатель) | отказ (SC01) |

Вывод для отчёта: World State принадлежит namespace chaincode (имени `payment`), а не пакету; при смене пакета данные остаются на месте, и новая реализация должна уметь их читать.

## 7. План обновления инфраструктуры Fabric 2.5 → 3.1.x (задание 3.6, часть 2)

`docs/upgrade/fabric-2.5-to-3.1-plan.md`. Перед написанием изучи официальные страницы `upgrade`, `upgrade_to_newest_version`, `whatsnew` и release notes 3.0 / 3.1 (ветка latest) и опирайся на них, со ссылками. Структура строго по последовательности **Backup → Orderers → Peers → Verification → Channel Capabilities**:

0. **Предусловия (до любых действий):** удалённые в 3.x механизмы — system channel (переход на Channel Participation API), Solo и Kafka (миграция на Raft), legacy chaincode lifecycle (все chaincode в `_lifecycle`, application capability ≥ V2_0); проверка устаревших параметров `core.yaml` / `orderer.yaml`; совместимость Go-shim и chaincode-образов; версии CouchDB; совместимость клиентских SDK (переход на Fabric Gateway). Сверь этот список с документацией и дополни.
1. **Backup:** что копировать на каждом узле (ledger-каталог `/var/hyperledger/production`, MSP и TLS, конфиги, БД Fabric CA, CouchDB), порядок (останов контейнера → копия → контрольные суммы), шифрование бэкапов с ключами, проверка восстановимости.
2. **Orderers:** по одному, rolling; после каждого — проверка, что консенсус Raft восстановлен (лидер, высоты каналов через `osnadmin`), прежде чем переходить к следующему.
3. **Peers:** по одному на организацию; CouchDB; пересборка chaincode-контейнеров; нужны ли `peer node upgrade-dbs` / rebuild — по документации.
4. **Verification:** высоты блоков на всех узлах, тестовая транзакция, `querycommitted`, gateway-клиент, логи без ошибок.
5. **Channel Capabilities:** включение `V3_0` только после обновления **всех** orderer и peer канала; процедура config update (fetch config → decode → правка → `compute_update` → подписи администраторов по политике → submit); проверка. После `V3_0` откат бинарников на 2.5 невозможен — это точка невозврата.

Плюс: план отката для каждого этапа (до точки невозврата), матрица рисков (риск → вероятность → влияние → мера), окно обслуживания и критерии Go/No-Go.

Опциональная практика (только если основная работа уже полностью готова и пользователь согласен): в момент между шагами 8 и 9 показать реальный бэкап docker volumes основной сети (`docker run --rm -v <volume>:/data -v $PWD/backup:/backup alpine tar czf ...` + `sha256sum`) — это практическое подтверждение этапа Backup.

## 8. Контрольная точка перед остановкой основной сети

Прежде чем переходить к SmartBFT:
1. Убедись, что `docs/report/01_task1.md`, `02_task2.md` и раздел 3.1–3.6 текущего отчёта готовы, все логи в `evidence/` сохранены и прошли `redact.sh`.
2. Сделай бэкап volumes и архив `evidence/` (см. опциональную практику выше).
3. Выведи пользователю список скриншотов задач 1–3.6, которые нужно сделать **сейчас, пока сеть жива**.
4. **Спроси явное подтверждение** на `./network.sh down`. Без «да» не продолжай.

## 9. Стенд SmartBFT (задание 3.7)

`scripts/39_bft_*.sh`, логи в `evidence/task3/bft/`:

1. **Подъём:** `./network.sh up createChannel -bft -c bftchannel` (Fabric 3.1.x). Проверь совместимость флага `-bft` с `-ca` и `-s couchdb` по документации и скриптам test-network; если не совместимы — используй то, что поддерживается, и задокументируй.
2. **Подтверждение конфигурации:** decode config block канала → `ConsensusType` = `BFT`, список consenters (4 orderer, их MSP и ID), параметры SmartBFT (`request_batch_max_count`, `view_change_timeout` и т.п.), channel capability `V3_0`. Таблица orderer → порт → admin-порт из `compose-bft-test-net.yaml`.
3. **Chaincode:** разверни `payment` (v2.0, AND-политика) в `bftchannel` через `scripts/lifecycle.sh`.
4. **Определение лидера:** по логам orderer (`docker logs ... | grep -iE "leader|view"`) — какой узел ведёт текущий view.
5. **Базовая линия:** транзакция → VALID, TxID; высоты на всех 4 orderer (`osnadmin channel list --channelID bftchannel` против admin-порта каждого) и на обоих peers равны H.
6. **Контролируемый отказ:** `docker stop orderer4.example.com` (не лидер — если лидер он, выбери другой не-лидер). Зафиксируй время.
7. **Контрольная транзакция при n − 1:** отправляй через живой orderer (или Gateway-клиент, который сам выберет живые). VALID, TxID, высота H+1 на 3 живых orderer и обоих peers. Логи живых orderer: отсутствие узла замечено, консенсус продолжается.
8. **Восстановление:** `docker start orderer4.example.com` → через ~30 с высота orderer4 = H+1 (catch-up); ещё одна транзакция → VALID на всех 4.
9. **Дополнительно** (сильно для защиты):
   - остановка **лидера** → view change в логах (время до восстановления), транзакция → VALID; восстановить;
   - остановка **двух** orderer (> f) → транзакция не проходит (таймаут или ошибка — зафиксировать фактическое поведение), т.к. нет кворума 3 из 4; восстановить оба → сеть снова обрабатывает транзакции.
10. Таблица эксперимента `evidence/task3/bft/experiment.md`: шаг → действие → живые узлы → кворум есть/нет → результат → TxID → высоты.

**Анализ (пункт 7 отчёта):** n = 3f + 1 = 4 → f = 1, кворум ⌈(n + f + 1)/2⌉ = 3; чем crash fault отличается от византийского поведения (молчание против equivocation, конфликтующих подписанных предложений, цензуры, выборочной доставки); почему остановка контейнера доказывает только устойчивость к crash; что потребовалось бы для проверки BFT (модифицированный orderer с внедрением ошибок, сетевые разделения с `tc`/`iptables`, задержки, формальная верификация протокола); сравнение с Raft основной сети (там один orderer — его остановка означала бы полную остановку упорядочивания).

Лист 3 `docs/architecture/architecture_variant1.drawio` («Стенд SmartBFT») сверь с фактическими именами и портами orderer, при необходимости поправь подписи.

## 10. Раздел отчёта

`docs/report/03_task3.md` — пункты 6 и 7 итогового отчёта:
- таблица «до / после»: Version 1.0 → 2.0, Sequence 1 → 2, Package ID 1.0 → 2.0, политика без изменений;
- шаги lifecycle с выводами (`checkcommitreadiness` до и после, `querycommitted`);
- правила совместимости, ленивая миграция, таблица C1–C9 с TxID, сравнение снимков состояния;
- OWASP-ревью обновления;
- план обновления 2.5 → 3.1.x (краткая версия в отчёте, полная — в `docs/upgrade/`);
- эксперимент SmartBFT: таблица, лидер, view change, отсутствие кворума, анализ crash vs Byzantine, сравнение Raft и SmartBFT;
- итоговый вывод по работе.

## 11. Скриншоты для пользователя

`docs/report/screenshots/task3/CHECKLIST.md`. **До `network.sh down`:**
1. `querycommitted` до обновления (1.0 / 1).
2. `queryinstalled` с обоими Package ID.
3. `checkcommitreadiness` после одного и после двух approve.
4. `querycommitted` после commit (2.0 / 2).
5. Чтение PO-0001, созданного v1.0, через v2.0.
6. Return PO-0001 и история с TxID обеих версий.

**На стенде SmartBFT:**

7. `docker ps` с 4 orderer.
8. Конфиг канала с `BFT` и consenters.
9. `docker stop orderer4` + контрольная транзакция VALID.
10. Высоты всех узлов до отказа, во время и после восстановления.
11. (доп.) View change в логах и отказ при двух остановленных orderer.

## 12. Definition of Done

- [ ] Снимок до обновления: 1.0 / 1, Package ID, состояние объектов с `sha256`.
- [ ] Chaincode 2.0: новая функциональность, совместимость с World State v1.0, регрессионные и golden-тесты, OWASP-ревью.
- [ ] Пакет 2.0 установлен на обоих peers; Package ID в логе.
- [ ] Approve обеими org: version 2.0, sequence 2, та же AND-политика; readiness показан.
- [ ] Commit: `querycommitted` = 2.0 / 2.
- [ ] Совместимость: объект v1.0 прочитан, старая операция выполнена, новая функция работает (TxID).
- [ ] План 2.5 → 3.1.x по последовательности Backup → Orderers → Peers → Verification → Channel Capabilities, со ссылками на документацию.
- [ ] Пользователь подтвердил остановку основной сети; бэкап и evidence сохранены.
- [ ] SmartBFT: 4 orderer, отказ одного, контрольная транзакция VALID, восстановление и catch-up подтверждены высотами.
- [ ] Анализ crash vs Byzantine написан.
- [ ] `docs/report/03_task3.md` готов; evidence прошли redaction.
