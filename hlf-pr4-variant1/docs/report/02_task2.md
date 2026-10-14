## 4. Анализ безопасности

### 4.1. Модель угроз (задание 2.1)

Полная модель — `docs/security/threat-model.md`. Кратко:

- **Активы:** A1 состояние PaymentOrder; A2 расчётные реквизиты; A3 закрытые ключи MSP/TLS; A4 корневые ключи и БД Fabric CA; A5 определение chaincode и Endorsement Policy; A6 конфигурация канала; A7 ключи consenter-ов; A8 целостность Blockchain; A9 доступность сервиса платежей.
- **Участники:** initiator1, approver1 (Org1), processor2 (Org2), администраторы Org1/Org2/Orderer и CA, внешний атакующий, **злонамеренный инсайдер Org2**, скомпрометированные peer и orderer.
- **Доверительные границы** TB1–TB6 — на схеме (рисунок 2): TB1 организация, TB2 Client ↔ Peer/Gateway, TB3 организации ↔ Ordering Service, TB4 Peer ↔ chaincode, TB5 Fabric CA ↔ участники, TB6 внешние клиенты банков ↔ Client Application. DFD с границами — в `threat-model.md` (Mermaid).

STRIDE: 15 угроз, покрыты все 7 компонентов задания и все 6 категорий; риск — DREAD (среднее пяти факторов 0–10).

| ID | Компонент | STRIDE | Сценарий | OWASP | DREAD | Меры | Тест |
|---|---|---|---|---|---|---|---|
| T-01 | Chaincode | E | инсайдер Org2 авторизует списание чужого поручения и проводит платёж до SETTLED | SC01, SC03 | **8.8** | MSP + роль + 4 глаза (Р) | SEC-04 |
| T-02 | Chaincode | T | недопустимый переход, повторное исполнение | SC03 | 7.4 | таблица переходов (Р) | SEC-07, 08 |
| T-03 | Chaincode | T | невалидные сумма/валюта/IBAN, огромный transient | SC04, SC08, SC10 | 8.2 | строгая валидация (Р) | SEC-10, 11 |
| T-04 | Chaincode/Peer | I | реквизиты в transient уходят на peer Org2 при endorsement | SC01 | 7.2 | отдельная private-only транзакция, collection EP (Р) | SEC-17 |
| T-05 | Ledger | I | перебор хэша низкоэнтропийных реквизитов | SC09 (аналог) | 6.0 | соль от клиента (Р) | SEC-13 |
| T-06 | Peer/Ledger | I | чтение privateDetails пользователем Org2 | SC01 | 6.8 | memberOnlyRead, MSP клиента = MSP peer (Р) | SEC-02, 03, 15 |
| T-07 | Client | S | кража ключа initiator1 | — | 5.6 | HSM (П), 4 глаза ограничивают ущерб (Р) | SEC-05 |
| T-08 | Client | R | отрицание авторизации платежа | SC01 | 5.2 | подпись X.509, approvedByHash, история (Р) | разбор T4 |
| T-09 | Gateway | D | массовые запросы без лимита | SC10 | 7.4 | pageSize ≤ 50 (Р), rate limit (П) | SEC-14 |
| T-10 | Gateway | S | MITM / поддельный endpoint | — | 5.0 | TLS с проверкой имени (Р) | client |
| T-11 | Ordering Service | T/D | злонамеренный или единственный orderer | — | 5.6 | SmartBFT (Рек, Задание 3.7) | BFT |
| T-12 | MSP/CA | S/E | выпуск `role=approver` постороннему, утечка enrollment secret | — | 5.6 | случайные секреты, ротация (Р) | 20/20b |
| T-13 | Ledger | T | подмена блока на диске | — | 4.8 | хэш-цепочка (Р) | 13_ledger_info |
| T-14 | Peer/Chaincode | D/T | недетерминизм → расхождение endorsements | SC09 | 6.6 | check_determinism (Р) | static |
| T-15 | Ledger/Peer | T | двойная обработка параллельными транзакциями | SC03/SC05 | 6.6 | MVCC (Р) | M1/M2 |

**PASTA.** Анализ соответствует этапам 4–6 PASTA: анализ угроз по DFD, анализ уязвимостей (OWASP, статический анализ), моделирование атаки (практическое воспроизведение T-01).

### 4.2. OWASP Smart Contract Top 10 (2025) — маппинг на Fabric

Полная таблица — `docs/security/owasp-sc-top10-2025-fabric.md`. Прямо применимы: SC01, SC03, SC04, SC08, SC10; через аналог: SC02 (доверие к сумме из аргументов), SC05 (`InvokeChaincode`, read-your-writes), SC06 (статус `InvokeChaincode`), SC09 (недетерминизм, соль в chaincode); неприменим напрямую: SC07 (нет займов; аналог — несколько переходов в одной транзакции). Дополнительно разобраны Fabric-специфичные риски: утечка transient к endorsers не-членов коллекции, перебор хэша private data, данные в логах и текстах ошибок, phantom reads.

### 4.3. Идентичности с ролями (Fabric CA)

`scripts/20_register_users.sh` (`evidence/task2/20_register_users.log`, 18 ✔): регистрация и enrollment через `fabric-ca-client` с атрибутом в ecert — `initiator1` (`role=initiator`), `approver1` (`role=approver`), `norole1` (без роли), `processor2` (Org2, `role=processor`). Доказательство — расширение `1.2.3.4.5.6.7.8.1`, например `{"attrs":{"hf.Affiliation":"","hf.EnrollmentID":"approver1","hf.Type":"client","role":"approver"}}`. Регистратор — уже выпущенная test-network идентичность администратора CA, bootstrap-пароль не используется.

**Инцидент и реагирование.** `fabric-ca-client register` печатает назначенный secret в отдельной строке с меткой «Password»; первый прогон записал её в локальный лог (не в git). Строка добавлена в `scripts/redact.sh`, все `evidence/` прогнаны через redaction, enrollment secrets **ротированы** (`scripts/20b_rotate_secrets.sh`, `fabric-ca-client identity modify --secret`) — утёкшие значения недействительны. Секреты хранятся только в `.secrets/` (права 600, в `.gitignore`).

![Рисунок 17 — Пользователи с атрибутом role](screenshots/task2/01_users_roles.png)

*Рисунок 17 — Выпуск идентичностей с атрибутом role через Fabric CA*

### 4.4. Уязвимая версия `paymentvuln` и её эксплуатация (задания 2.2–2.3)

`chaincode/payment-vuln` — копия v1.0 с **одной** ошибкой: `SubmitPaymentOrder` не проверяет MSP вызывающего (OWASP **SC01** → **SC03**). Diff — 3 строки кода (`evidence/task2/22_vuln_diff.patch`). Развёрнут под отдельным именем: `paymentvuln` 1.0 / sequence 1, та же AND-политика, Package ID `paymentvuln_1.0:18c91489d77e96883040d94bc826f5bc090b162184d8890177d5aee594931268` — sequence основного `payment` не изменился (`evidence/task2/00_precheck.log`, `99_postcheck.log`: 1.0 / 1).

Эксплуатация от имени Org2 (`scripts/21_exploit_vuln.sh`, `evidence/task2/21_exploit.log`):

| # | Операция | От имени | TxID | Блок | Код |
|---|---|---|---|---|---|
| V1 | Create PO-V001 (Org1 **не** авторизует) | Org1MSP/initiator1 | `aec25bf324b0dcc150da24a002902ea9313ffc600b23ba0e7cd963df87aa5bb9` | 21 | VALID |
| **V2** | **Submit PO-V001 — несанкционированная авторизация списания** | **Org2MSP/processor2** | `e4545b3d0965b2b4dfc8c3174c3f58229c1d16c6dd33d6f21c4b110ac6824fe5` | 22 | **VALID** |
| V3 | Accept PO-V001 | Org2MSP/processor2 | `1849dc33a9b343de06e674641168241b30b5ac731e8faf4daecfe3e52eae6f0c` | 23 | VALID |
| V4 | Settle PO-V001 | Org2MSP/processor2 | `cc728cfaf332db86f8b71677b875176870ee089c8bd08a0da5d3bc359232a4dd` | 24 | VALID |

Декодирование блока 22: создатель транзакции Submit — **Org2MSP** (`OU = client, CN = processor2`), endorsements — **Org1MSP и Org2MSP**, код VALID. Итог: PO-V001 = SETTLED, Org1 после создания не выполнила ни одной операции.

**Нарушенные инварианты:** **INV-4** — авторизацию списания (переход в SUBMITTED) выполняет только банк-отправитель (`senderBankMSP` = Org1MSP, роль approver); **INV-SoD** — ни одна организация не может единолично провести платёж от создания до исполнения.

**Почему Endorsement Policy не остановила атаку.** Политика AND была **выполнена**: оба peers исполнили один и тот же ошибочный код, получили одинаковый RW-set и честно подписали результат. EP определяет, *чьи peers* должны подтвердить результат исполнения, но не проверяет, *кто вызвал* функцию. Авторизация вызывающего — ответственность chaincode.

![Рисунок 18 — Эксплуатация paymentvuln от Org2](screenshots/task2/03_exploit_paymentvuln.png)

*Рисунок 18 — processor2 (Org2MSP) выполняет Submit → Accept → Settle чужого поручения: все транзакции VALID*

![Рисунок 19 — История PO-V001 и создатель Submit](screenshots/task2/04_exploit_history_creator.png)

*Рисунок 19 — История PO-V001; в блоке 22 создатель Submit = Org2MSP, endorsements Org1MSP + Org2MSP*

### 4.5. Защищённая версия `paymentsecure` (задание 2.4)

Дизайн — `docs/security/paymentsecure-design.md`. Контроли:

| Механизм | Реализация |
|---|---|
| MSP вызывающего | `GetClientIdentity().GetMSPID()`; Submit/Cancel — только `senderBankMSP`, Accept/Reject/Settle — только `receiverBankMSP` |
| Полномочия пользователя | `AssertAttributeValue("role", …)`: Create/SetSettlementDetails — initiator; Submit — approver; Accept/Reject/Settle — processor |
| Идентичность | `GetID()` → `createdByHash`, `approvedByHash` (sha256); **четыре глаза**: approvedByHash ≠ createdByHash |
| Переходы состояния | таблица `allowedTransitions()`, терминальные статусы |
| Инварианты | INV-1…INV-9 (уникальность, sender = Org1, неизменяемость суммы и сторон, Submit только approver отправителя, четыре глаза, Accept/Reject/Settle только processor получателя, исполнение один раз из ACCEPTED, терминальные статусы, реквизиты обязательны до Submit и неизменны после) |
| Конфиденциальные данные | `GetTransient()` → `PutPrivateData()` / `GetPrivateData()` / `GetPrivateDataHash()` |

Unit-тесты: 37 тестов (каждый инвариант — отдельный тест; матрица авторизации на моках `ClientIdentity` с разными MSP и атрибутами; сквозной тест через `ContractChaincode.Invoke` с реальным разбором атрибута `role` из сертификата), покрытие **96.2 %**, `go vet`/`gosec`/`govulncheck`/`check_determinism` — чисто; 2 стилистических замечания staticcheck обоснованы (`evidence/task2/27_static_analysis_paymentsecure.log`).

**Тот же сценарий атаки на `paymentsecure`** (`evidence/task2/25_exploit_secure.log`): Submit от processor2 → `ERR_UNAUTHORIZED: caller organisation is not allowed to perform this operation`; Accept/Settle → `ERR_INVALID_TRANSITION`; PO-V001 в namespace `paymentsecure` остался CREATED (в `paymentvuln` — SETTLED). Сравнение «до / после» — `docs/security/vuln-vs-secure.md`.

![Рисунок 20 — Атака на paymentsecure отклонена](screenshots/task2/05_exploit_on_secure_denied.png)

*Рисунок 20 — Тот же Submit от Org2 на paymentsecure: отказ, уязвимость исправлена*

## 5. Private Data Collection и разграничение доступа

### 5.1. Конфигурация коллекции и деплой (задание 2.5)

```json
[{ "name": "collectionSettlementDetails", "policy": "OR('Org1MSP.member')",
   "requiredPeerCount": 0, "maxPeerCount": 1, "blockToLive": 0,
   "memberOnlyRead": true, "memberOnlyWrite": true,
   "endorsementPolicy": { "signaturePolicy": "OR('Org1MSP.peer')" } }]
```

| Поле | Смысл |
|---|---|
| `policy: OR('Org1MSP.member')` | открытые данные хранят только peers Org1; остальные — только хэши |
| `requiredPeerCount: 0`, `maxPeerCount: 1` | распространение по gossip при endorsement не обязательно / максимум 1 peer (у Org1 один peer) |
| `blockToLive: 0` | бессрочное хранение — платёжные документы подлежат хранению в течение установленного законом срока; удаление по числу блоков недопустимо. Альтернатива при регуляторном требовании удаления — ненулевой TTL или `PurgePrivateData` (Fabric 2.5+) |
| `memberOnlyRead / memberOnlyWrite: true` | peer сам отклоняет чтение/запись клиентами не из Org1 |
| `endorsementPolicy: OR('Org1MSP.peer')` | collection-level EP: транзакции, пишущие только в коллекцию, достаточно подписи peer0.org1 |

Деплой `paymentsecure` 1.0 / sequence 1, AND-политика, `--collections-config` одинаково в approve, checkcommitreadiness и commit; Package ID `paymentsecure_1.0:55f18aa731b18cfac745804b7ba3a8666f0c914d1f3e4d59d5a34b0ac446e985`; `querycommitted` показывает коллекцию (`evidence/task2/24_lifecycle_paymentsecure.log`). Совпадение исходников в репозитории с развёрнутым пакетом подтверждено повторным вычислением Package ID.

![Рисунок 21 — querycommitted paymentvuln и paymentsecure с коллекцией](screenshots/task2/02_querycommitted_vuln_secure.png)

*Рисунок 21 — Определения paymentvuln и paymentsecure (1.0 / 1), коллекция collectionSettlementDetails*

**Дизайн против утечки на этапе Execute.** Если передать реквизиты в той же транзакции, что и публичную запись с AND-политикой, proposal с transient уйдёт на peer Org2, и банк-получатель увидит реквизиты (Information Disclosure, SC01) — этот вариант отвергнут. Принятое решение: `CreatePaymentOrder` — публичная транзакция (AND); `SetSettlementDetails` пишет **только** private-ключи и endorse-ится **только** peer0.org1 (collection EP); chaincode дополнительно отказывается обрабатывать её на peer чужой организации (SEC-17); `SubmitPaymentOrder` проверяет наличие хэша через `GetPrivateDataHash` (доступен и Org2) и фиксирует его в публичном `settlementHash`. Эмпирически: транзакция с одной endorsement получила **VALID**.

### 5.2. Transient и отсутствие реквизитов в публичном Ledger (задание 2.6)

`scripts/23_private_data_flow.sh` (`evidence/task2/23_private_flow.log`, 12 ✔), синтетические, валидные по mod-97 реквизиты (код банка 999, «TEST»):

| # | Операция | TxID | Блок | Endorsers | Код |
|---|---|---|---|---|---|
| S1 | Create PO-S001 (initiator1) | `28a68a396bfa6fc656f2ff85be63588f15d667a95f4523048bc2bd10a623231f` | 25 | Org1 + Org2 | VALID |
| S2 | SetSettlementDetails PO-S001, transient `settlement` | `e3cc9aaad4cb4393e5d47beb15ce3146a3bb25d3adb45a9346b4ea104cf22551` | 26 | **только peer0.org1** | VALID |
| S4 | SetSettlementDetails PO-S002 через **Gateway** (`WithTransient` + `WithEndorsingOrganizations("Org1MSP")`) | `6ef28f98c5e9cd4c5b3b18d166c2182dc8c478f64ce070ab9a816b11a8a8611f` | 28 | только Org1 | VALID |

Доказательства:
1. **Аргументы транзакции** S2 в блоке 26: только `SetSettlementDetails PO-S001`; `TransientMap` в блоке отсутствует.
2. **RW-set:** публичных записей 0; `collection_hashed_rwset` коллекции `collectionSettlementDetails` содержит только `key_hash` и `value_hash`.
3. **`grep -c`** по пяти маркерам (IBAN плательщика и получателя, БИН, наименование, второй IBAN) в сыром блоке `.pb`, в decoded JSON и во всех base64-полях блока — **0**; положительный контроль метода: `grep -c PO-S001` в сыром блоке = 2.
4. **CouchDB:** peer0.org1 — базы `paymentchannel_paymentsecure`, `…$$pcollection$settlement$details` (открытые данные) и `…$$hcollection$settlement$details` (хэши); peer0.org2 — **только `$$h`**. Совпадений маркеров в CouchDB Org2 и в публичной базе Org1 — 0.
5. **Логи** peer0.org1, peer0.org2, orderer и обоих контейнеров chaincode `paymentsecure` — 0 совпадений.
6. `ReadSettlementDetails` от initiator1 на peer0.org1 возвращает реквизиты (в отчёте маскированы: `payerIBAN=KZ**************0001`), соль не возвращается.

![Рисунок 22 — SetSettlementDetails с transient](screenshots/task2/06_setsettlement_transient.png)

*Рисунок 22 — Реквизиты передаются только в transient (значения не выводятся), endorse только peer0.org1, VALID; вариант через Gateway*

![Рисунок 23 — Блок: аргументы, hashed rwset, grep -c = 0](screenshots/task2/07_block_grep_zero.png)

*Рисунок 23 — В блоке только PO-S001 и хэши; поиск реквизитов по блоку — 0 совпадений*

![Рисунок 24 — CouchDB $$p/$$h](screenshots/task2/08_couchdb_p_h.png)

*Рисунок 24 — $$p и $$h на Org1, только $$h на Org2; 0 совпадений в логах контейнеров*

![Рисунок 25 — Fauxton Org1](screenshots/task2/12_fauxton_org1_private.png)

*Рисунок 25 — CouchDB peer0.org1: базы paymentsecure$$p… и $$h…*

![Рисунок 26 — Fauxton Org2](screenshots/task2/13_fauxton_org2_hash_only.png)

*Рисунок 26 — CouchDB peer0.org2: только paymentsecure$$h… (открытых реквизитов нет)*

### 5.3. Security-тесты (задание 2.7)

`tests/security/run_security_tests.sh` — 17 тестов против живой сети, перезапускаемый (каждый прогон создаёт свои поручения). Результат: **17 PASS, 0 FAIL** (`evidence/task2/security_tests.md`). Org1 имеет доступ к privateDetails (SEC-01), запросы Org2 завершаются отказом (SEC-02, SEC-03).

| ID | OWASP | Сценарий | Ожидание | Факт | Итог |
|---|---|---|---|---|---|
| SEC-01 | SC01 | initiator1 читает реквизиты на peer0.org1 | данные | `payerIBAN=KZ**************0001` | PASS |
| SEC-02 | SC01 | processor2 читает реквизиты на peer0.org2 | отказ | `ERR_UNAUTHORIZED` | PASS |
| SEC-03 | SC01 | processor2 читает реквизиты на peer0.org1 | отказ | `ERR_UNAUTHORIZED` | PASS |
| SEC-04 | SC01/SC03 | повтор эксплойта: Submit от Org2 | отказ | `ERR_UNAUTHORIZED` | PASS |
| SEC-05 | SC01/SC03 | initiator1 сам авторизует (нет роли approver, 4 глаза) | отказ | `ERR_UNAUTHORIZED: caller role is not permitted` | PASS |
| SEC-06 | SC01 | norole1 создаёт поручение | отказ | `ERR_UNAUTHORIZED` | PASS |
| SEC-07 | SC03 | Settle из SUBMITTED в обход ACCEPTED | отказ | `ERR_INVALID_TRANSITION` | PASS |
| SEC-08 | SC03 | повторный Settle (replay) | отказ | `ERR_INVALID_TRANSITION: SETTLED -> SETTLED` | PASS |
| SEC-09 | SC03 | Create с существующим ID | отказ | `ERR_ALREADY_EXISTS` | PASS |
| SEC-10 | SC04/SC08 | сумма −1, 0, 2⁶³, 1e3; валюта XXX; IBAN с ошибкой mod-97 | отказ каждого | 6 из 6 отклонены | PASS |
| SEC-11 | SC04/SC10 | без transient / > 4 КБ / короткая соль / лишнее поле | отказ | 4 из 4 отклонены | PASS |
| SEC-12 | SC03 | SetSettlementDetails после SUBMITTED (INV-9) | отказ | `ERR_INVALID_TRANSITION` | PASS |
| SEC-13 | SC01 | Verify от Org2: верный кандидат / неверный | true / false | `match=true` / `match=false` | PASS |
| SEC-14 | SC10 | GetAllPaymentOrders pageSize = 10000 | отказ | `ERR_VALIDATION: pageSize must be in range 1..50` | PASS |
| SEC-15 | SC01 | маркеры реквизитов во всех блоках, CouchDB Org2, логах | 0 | блоки=0, couchdb1=0, логи=0 | PASS |
| SEC-16 | SC03 | Submit без реквизитов (INV-9) | отказ | `ERR_VALIDATION: settlement details must be set` | PASS |
| SEC-17 | SC01 | SetSettlementDetails отправлен на peer0.org2 | отказ | `ERR_UNAUTHORIZED: client organisation does not match the peer organisation` | PASS |

![Рисунок 27 — SEC-01…03](screenshots/task2/09_sec_01_02_03.png)

*Рисунок 27 — Org1 читает privateDetails (маскировано), Org2 получает отказ на своём и на чужом peer*

![Рисунок 28 — Итог security-тестов](screenshots/task2/10_security_tests_all.png)

*Рисунок 28 — 17 security-тестов: 17 PASS*

**Выводы по заданию 2.** Уязвимость отсутствия авторизации воспроизведена практически и проходит Endorsement Policy; исправление (MSP + роль + четыре глаза + инварианты) подтверждено тем же сценарием атаки и 17 тестами. Конфиденциальные реквизиты не попадают ни в аргументы, ни в публичную часть ledger, ни к банку-получателю; Org2 может только сверить их хэш с солью. Основной chaincode `payment` всё это время оставался 1.0 / sequence 1.
