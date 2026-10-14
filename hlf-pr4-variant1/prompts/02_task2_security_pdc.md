# Claude Code · Задание 2 — Безопасность chaincode, OWASP SC Top 10 (2025) и конфиденциальность данных (ПР №4, Вариант 1)

## 0. Роль и цель

Ты — security engineer, специализирующийся на Hyperledger Fabric и аудите смарт-контрактов. Выполни **Задание 2** полностью: модель угроз STRIDE, контролируемо уязвимый chaincode, воспроизведение уязвимости от имени Org2, защищённая версия с проверкой MSP, идентичности, полномочий, переходов состояния и инвариантов, Private Data Collection с передачей данных через transient field и ≥ 6 security-тестов.

**Главный ориентир — OWASP Smart Contract Top 10 (2025).** Каждая угроза, уязвимость, мера защиты и тест связываются с конкретным пунктом SC01–SC10.

Перед началом прочитай `CLAUDE.md` (правила из Задания 1 действуют: никаких выдуманных выводов, никаких секретов в логах и отчёте, скрипты с `tee` + `redact.sh`, `network.sh down` запрещён). Покажи план и дождись подтверждения.

## 1. Исходное состояние (проверь, прежде чем что-то делать)

- Сеть Задания 1 запущена, канал `paymentchannel`.
- `payment` закоммичен: version 1.0, sequence 1, `AND('Org1MSP.peer','Org2MSP.peer')`. Зафиксируй `querycommitted` в `evidence/task2/00_precheck.log` — это доказательство, что Задание 2 не меняет sequence основного chaincode (повтори проверку в конце).
- Контекст: Org1 = Банк-отправитель, Org2 = Банк-получатель, объект `PaymentOrder`, конфиденциальные данные — **расчётные реквизиты**.

## 2. OWASP SC Top 10 (2025) — полный маппинг на Fabric

Сверь список на https://owasp.org/www-project-smart-contract-top-10/ и создай `docs/security/owasp-sc-top10-2025-fabric.md`. Список ориентирован на EVM/DeFi, поэтому для каждого пункта явно укажи: «прямо применим / применим через аналог / неприменим + обоснование». Не подгоняй — неприменимость с аргументом лучше натянутого соответствия.

| OWASP SC 2025 | Проявление в Fabric / Go chaincode для платёжных поручений | Контроль в `paymentsecure` | Тесты |
|---|---|---|---|
| SC01 Access Control | Org2 переводит чужое поручение в SUBMITTED; пользователь без роли создаёт платёж; чтение реквизитов чужой организацией | MSP + атрибут `role` (Fabric CA) + принцип четырёх глаз + `memberOnlyRead/Write` | SEC-02…06 |
| SC02 Price Oracle Manipulation | курс или сумма, которым «доверяют» из аргументов | внешних оракулов нет; сумма неизменяема после создания | SEC-10 (неизменяемость) |
| SC03 Logic Errors | пропуск ACCEPTED, повторное исполнение, изменение реквизитов после авторизации | таблица переходов, терминальные статусы, инварианты INV-1…INV-9 | SEC-07, 08, 12, 16 |
| SC04 Input Validation | сумма, валюта, КНП, IBAN, BIC, БИН, transient payload | строгая валидация, IBAN mod-97, лимиты размера | SEC-10, 11 |
| SC05 Reentrancy | аналог: повторный вход через `InvokeChaincode`; GetState не видит PutState той же транзакции | без cross-chaincode вызовов; проверки состояния до записи | SEC-08 |
| SC06 Unchecked External Calls | непроверенный статус `InvokeChaincode` | не используется (зафиксировано правилом и линтером) | статический анализ |
| SC07 Flash Loan Attacks | неприменимо напрямую (нет займов); аналог — несколько переходов в одной транзакции | одна функция = один переход | unit-тесты |
| SC08 Integer Overflow/Underflow | `int64` суммы, парсинг строк, float для денег | `ParseInt` с проверкой диапазона, `MaxAmount`, без float | SEC-10 |
| SC09 Insecure Randomness | недетерминизм → расхождение endorsements; соль генерируется **клиентом**, не chaincode | `GetTxTimestamp`, соль только из transient | `check_determinism.sh` |
| SC10 Denial of Service | неограниченные range-запросы, огромный transient | потолок `pageSize`, лимит размера transient и полей | SEC-14 |

Добавь раздел «Fabric-специфичные риски вне Top 10»: утечка transient к endorsers не-членов коллекции, перебор хэша низкоэнтропийных private data (нужна соль), private data в логах peer, раскрытие данных в текстах ошибок, phantom reads в range-запросах.

## 3. Модель угроз (задание 2.1, пункт 4 отчёта)

`docs/security/threat-model.md`:

1. **Активы:** состояние `PaymentOrder` (статус, сумма, стороны); расчётные реквизиты; закрытые ключи MSP и TLS; корневые ключи и БД Fabric CA; определение chaincode и Endorsement Policy; конфигурация канала; ключи consenter-ов orderer; целостность Blockchain; доступность сервиса платежей.
2. **Участники:** initiator и approver Org1, processor Org2, администраторы Org1/Org2/Orderer, администратор CA, внешний атакующий, злонамеренный инсайдер Org2, скомпрометированный peer, скомпрометированный orderer.
3. **Доверительные границы:** TB1–TB6 со схемы (TB6 — внешние клиенты банков ↔ Client Application; пользователи на листе 1 соответствуют участникам из п. 2) `docs/architecture/architecture_variant1.drawio` (лист 1). DFD в Mermaid с подписанными границами.
4. **STRIDE:** не менее 6 угроз по заданию — сделай ≥ 12 так, чтобы **каждый** из компонентов Client, Gateway, Peer, Chaincode, Ordering Service, MSP, Ledger имел хотя бы одну угрозу и были представлены все 6 категорий STRIDE. Колонки: ID, компонент, граница, категория STRIDE, сценарий в терминах банковских платежей, OWASP SC, вероятность, влияние, риск (DREAD 0–10 по пяти факторам со средним), меры защиты (реализовано / процедурно / рекомендовано), остаточный риск, ID теста.
5. Короткий абзац о PASTA: на каком этапе PASTA лежит данный анализ (необязательно, но полезно на защите).

## 4. Идентичности с ролями (Fabric CA)

`scripts/20_register_users.sh` — регистрация и enrollment через `fabric-ca-client` с атрибутами в ecert:

| Пользователь | Org | Атрибут | Назначение |
|---|---|---|---|
| `initiator1` | Org1 | `role=initiator:ecert` | создаёт поручение и вводит реквизиты |
| `approver1` | Org1 | `role=approver:ecert` | авторизует списание (Submit), принцип четырёх глаз |
| `norole1` | Org1 | — | негативный тест: член Org1 без роли |
| `processor2` | Org2 | `role=processor:ecert` | принимает, отклоняет и исполняет платёж |

Enrollment secrets генерируй случайно (`openssl rand -hex 16`) и храни в `.secrets/` (в `.gitignore`, права 600). CA bootstrap-пароль test-network не выводи и не логируй, `set -x` вокруг этих команд не используй. Скопируй `config.yaml` (NodeOUs) в MSP каждого пользователя. Докажи наличие атрибута: `openssl x509 -noout -text` → только строка расширения `1.2.3.4.5.6.7.8.1` с `attrs` (без ключа). Расширь `env_org*.sh`, чтобы переключать пользователя через `ORG_USER`.

## 5. Уязвимая версия `paymentvuln` (задания 2.2–2.3)

Каталог `chaincode/payment-vuln` — копия `payment-v1` с **ровно одной** ошибкой бизнес-логики:

> **`SubmitPaymentOrder` не проверяет MSP вызывающей стороны** (OWASP SC01:2025 Access Control, следствие — SC03 Logic Errors). Остальные проверки идентичны v1.0.

Почему именно эта ошибка: Submit — это авторизация списания банком-отправителем. Без проверки банк-получатель может в одиночку провести платёж от черновика до исполнения, что для банковского домена эквивалентно несанкционированному списанию.

Деплой под отдельным именем: `scripts/lifecycle.sh` с `name=paymentvuln`, `version=1.0`, `sequence=1`, та же AND-политика. В комментарии над функцией — `// INTENTIONALLY VULNERABLE (lab): missing caller authorization — OWASP SC01:2025`. Добавь `chaincode/payment-vuln/README.md` с предупреждением, что это учебный уязвимый код.

**Эксплуатация от имени Org2** — `scripts/21_exploit_vuln.sh`, лог `evidence/task2/21_exploit.log`:

1. Org1 (`Admin@org1` или `initiator1`) создаёт `PO-V001` — черновик в CREATED. Org1 **не** авторизует его.
2. `processor2` (Org2) вызывает `SubmitPaymentOrder(PO-V001)` → VALID ← **несанкционированная операция**.
3. `processor2` вызывает Accept → VALID, затем Settle → VALID.
4. `GetPaymentOrderHistory(PO-V001)`: у транзакции Submit создатель — Org2MSP. Декодируй блок этой транзакции и покажи MSP ID создателя и то, что endorsements от обеих организаций присутствуют.

Зафиксируй все TxID в `evidence/task2/txids.csv` и сформулируй нарушенные инварианты:
- **INV-4:** перевод в SUBMITTED (авторизацию списания) выполняет только банк-отправитель — идентичность из `senderBankMSP` с ролью approver;
- **INV-SoD:** ни одна организация не может единолично провести платёж от создания до исполнения.

Отдельно объясни (это контрольный вопрос 2): Endorsement Policy AND была **выполнена** — оба peers запустили один и тот же ошибочный код и честно подписали результат. EP определяет, кто должен подтвердить результат исполнения, но не проверяет, кто вызывает функцию. Авторизация вызывающего — ответственность chaincode.

## 6. Защищённая версия `paymentsecure` (задание 2.4)

Каталог `chaincode/payment-secure`. Сначала `docs/security/paymentsecure-design.md`: матрица авторизации, таблица переходов, инварианты, схема данных private-коллекции, дизайн-решения. Потом код.

### 6.1 Контроль идентичности и полномочий

- MSP: `ctx.GetClientIdentity().GetMSPID()`;
- роль: `AssertAttributeValue("role", ...)`;
- идентичность: `GetID()` → хранится только `sha256` (CreatedByHash, ApprovedByHash) — персональные данные сотрудника не попадают в публичный state;
- для чтения private data: MSP клиента должен совпадать с MSP peer (`shim.GetMSPID()`), иначе отказ — как в официальном private data tutorial.

| Функция | Тип | MSP | Роль | Доп. условия |
|---|---|---|---|---|
| `CreatePaymentOrder(id, receiverBankMSP, amount, currency, purposeCode, reference)` | submit | Org1MSP | initiator | только публичные поля |
| `SetSettlementDetails(id)` | submit | Org1MSP | initiator | статус CREATED; реквизиты только из transient `settlement`; пишет **только** в private-коллекцию |
| `ReadSettlementDetails(id)` | evaluate | Org1MSP | initiator / approver | MSP клиента == MSP peer |
| `VerifySettlementDetails(id)` | evaluate | Org1MSP, Org2MSP | любая | кандидат из transient `candidate`; сравнение `sha256` с `GetPrivateDataHash` → `{match: bool}` |
| `SubmitPaymentOrder(id)` | submit | == senderBankMSP | approver | ApprovedByHash ≠ CreatedByHash; хэш реквизитов существует |
| `AcceptPaymentOrder`, `RejectPaymentOrder`, `SettlePaymentOrder` | submit | == receiverBankMSP | processor | по таблице переходов |
| `CancelPaymentOrder(id)` | submit | == senderBankMSP | initiator / approver | CREATED или SUBMITTED |
| `ReadPaymentOrder`, `PaymentOrderExists`, `GetAllPaymentOrders`, `GetPaymentOrderHistory` | evaluate | члены канала | — | только публичные данные, `pageSize` 1..50 |

### 6.2 Инварианты (каждый — отдельный unit-тест и, где возможно, security-тест)

INV-1 уникальность ID · INV-2 `senderBankMSP` = MSP создателя = Org1MSP · INV-3 сумма, валюта и стороны неизменяемы · INV-4 Submit только approver банка-отправителя · INV-5 принцип четырёх глаз (создатель ≠ авторизующий) · INV-6 Accept/Reject/Settle только processor банка-получателя · INV-7 исполнение ровно один раз и только из ACCEPTED · INV-8 терминальные статусы окончательны · INV-9 реквизиты обязательны до Submit и неизменяемы после него.

### 6.3 Конфиденциальные данные через transient

- `GetTransient()` → ключ `settlement` → JSON:
  `{payerIBAN, payerBIN, beneficiaryIBAN, beneficiaryBIC, beneficiaryName, salt}`.
- Валидация (SC04): IBAN — формат и контрольная сумма mod-97 (для KZ ровно 20 символов); BIC — 8 или 11 символов `^[A-Z]{4}[A-Z]{2}[A-Z0-9]{2}([A-Z0-9]{3})?$`; БИН/ИИН — 12 цифр; имя ≤ 140 рун без управляющих символов; `salt` — ≥ 32 hex-символа; весь transient ≤ 4 КБ; неизвестные поля отклоняются (`DisallowUnknownFields`).
- `PutPrivateData("collectionSettlementDetails", id, canonicalJSON)` и `GetPrivateData(...)` при чтении.
- **Соль генерирует клиент**, не chaincode (`crypto/rand` в chaincode нарушит детерминизм — SC09). Её назначение — защитить хэш, который видят все участники, от перебора низкоэнтропийных значений.
- Тексты ошибок не содержат значений реквизитов; в логи chaincode реквизиты не пишутся.

### 6.4 Ключевое дизайн-решение — не допустить утечки к Org2 на этапе Execute

Если реквизиты передаются в той же транзакции, что и публичная запись с AND-политикой, transient уйдёт на peer Org2 при endorsement — то есть Org2 увидит реквизиты, хотя не является членом коллекции. Поэтому:

- `CreatePaymentOrder` — публичная транзакция, AND-политика, endorse обоими peers;
- `SetSettlementDetails` — транзакция, которая пишет **только** private-ключи. Для коллекции задаётся collection-level endorsement policy `OR('Org1MSP.peer')`, транзакция endorse-ится **только** peer0.org1 (CLI: один `--peerAddresses`; Gateway-клиент: `client.WithTransient` + `client.WithEndorsingOrganizations("Org1MSP")`).

Проверь эмпирически, что такая транзакция получает VALID. Если поведение отличается от ожидаемого — исследуй по официальной документации (endorsement policies для private data, поведение Gateway с transient data), задокументируй фактический результат и скорректируй дизайн; не подгоняй выводы. Отвергнутый однотранзакционный вариант опиши в design-документе как найденную и устранённую угрозу (Information Disclosure, SC01).

## 7. Private Data Collection и деплой `paymentsecure` (задание 2.5)

`collections/collections_config.json`:

```json
[
  {
    "name": "collectionSettlementDetails",
    "policy": "OR('Org1MSP.member')",
    "requiredPeerCount": 0,
    "maxPeerCount": 1,
    "blockToLive": 0,
    "memberOnlyRead": true,
    "memberOnlyWrite": true,
    "endorsementPolicy": { "signaturePolicy": "OR('Org1MSP.peer')" }
  }
]
```

В документации объясни каждое поле. Для `blockToLive: 0` — обоснование для банковского домена (требования к хранению платёжных документов) и альтернативы: ненулевой TTL или `PurgePrivateData` (Fabric 2.5+), если нужно удаление по регуляторным причинам.

Деплой: `scripts/lifecycle.sh` с `name=paymentsecure`, `version=1.0`, `sequence=1`, AND-политика, `--collections-config` **одинаково** в approve, checkcommitreadiness и commit. `querycommitted` должен показать коллекцию.

## 8. Transient и отсутствие реквизитов в публичном Ledger (задание 2.6)

`scripts/23_private_data_flow.sh`, лог `evidence/task2/23_private_flow.log`:

1. `initiator1` создаёт `PO-S001`.
2. `initiator1` вызывает `SetSettlementDetails(PO-S001)` с `--transient "{\"settlement\":\"$(base64 -w0 <<< "$JSON")\"}"`. Используй **явно синтетические** тестовые реквизиты (валидные по контрольной сумме IBAN, но не реальные счета) и запомни их маркер для поиска.
3. Доказательства, что реквизиты не попали в публичную часть:
   - decode блока транзакции: аргументы содержат только `PO-S001`; в `ns_rwset` есть `collection_hashed_rwset` с хэшами ключа и значения, открытых значений нет;
   - `grep` по полному decoded JSON блока и по сырому файлу блока на IBAN, БИН и имя получателя → 0 совпадений (вывод `grep -c`);
   - CouchDB peer0.org1: есть базы `paymentchannel_paymentsecure$$p...` (открытые данные) и `$$h...`; CouchDB peer0.org2: только `$$h...`. Учётные данные CouchDB в лог не попадают;
   - `docker logs` peer0.org1, peer0.org2, обоих контейнеров chaincode и orderer → 0 совпадений по маркерам реквизитов.
4. `ReadSettlementDetails` от `initiator1` на peer0.org1 → реквизиты возвращаются. В отчёте показывай их **маскированными** (`KZ**************1234`).

## 9. Security-тесты (задание 2.7) — не менее 6, сделай 16

`tests/security/run_security_tests.sh` → `evidence/task2/security_tests.md`: таблица ID, OWASP SC, описание, идентичность и peer, ожидание, фактический результат (выдержка ответа или ошибки), TxID при наличии, PASS/FAIL. Тест PASS только если фактический результат совпал с ожидаемым.

| ID | Сценарий | Ожидание |
|---|---|---|
| SEC-01 | `initiator1` (Org1) `ReadSettlementDetails(PO-S001)` на peer0.org1 | данные получены |
| SEC-02 | `processor2` (Org2) `ReadSettlementDetails` на peer0.org2 | отказ |
| SEC-03 | `processor2` (Org2) `ReadSettlementDetails` на peer0.org1 | отказ (MSP клиента ≠ Org1 / ≠ MSP peer) |
| SEC-04 | Повтор эксплойта раздела 5: `processor2` вызывает Submit на `paymentsecure` | отказ — уязвимость исправлена |
| SEC-05 | `initiator1` создаёт и сам же пытается Submit (нет роли approver / нарушен принцип четырёх глаз) | отказ |
| SEC-06 | `norole1` (Org1 без роли) Create | отказ |
| SEC-07 | Settle из SUBMITTED в обход ACCEPTED | отказ |
| SEC-08 | Повторный Settle уже исполненного поручения (replay) | отказ |
| SEC-09 | Create с существующим ID | отказ |
| SEC-10 | Невалидные данные: сумма `-1`, `0`, `9223372036854775808`, `1e3`; валюта `XXX`; IBAN с ошибкой контрольной суммы | отказ на каждый вариант |
| SEC-11 | `SetSettlementDetails` без transient / с > 4 КБ / с короткой солью / с лишним полем | отказ |
| SEC-12 | `SetSettlementDetails` после SUBMITTED | отказ (INV-9) |
| SEC-13 | `processor2` `VerifySettlementDetails` с верным кандидатом → `true`, с неверным → `false` | сверка без раскрытия |
| SEC-14 | `GetAllPaymentOrders` с `pageSize=10000` | отказ или ограничение до 50 |
| SEC-15 | Реквизиты отсутствуют в блоке, в CouchDB Org2 и в логах контейнеров | 0 совпадений |
| SEC-16 | Submit поручения без реквизитов | отказ (INV-9) |

Дополнительно: unit-тесты `paymentsecure` на все инварианты и матрицу авторизации (моки `ClientIdentity` с разными MSP и атрибутами), покрытие ≥ 85%, `go vet` / `staticcheck` / `gosec` / `govulncheck` / `check_determinism.sh`.

## 10. Сравнение «до и после»

`docs/security/vuln-vs-secure.md`: один и тот же сценарий атаки на `paymentvuln` (успех, TxID) и на `paymentsecure` (отказ, текст ошибки); diff кода функции Submit; какие инварианты теперь соблюдаются; маппинг на OWASP SC01 и SC03. Это центральное доказательство для порога «70 баллов».

В конце снова `querycommitted --name payment` → по-прежнему version 1.0, sequence 1.

## 11. Раздел отчёта

`docs/report/02_task2.md` — покрывает пункты 4 и 5 итогового отчёта:
- модель угроз (активы, участники, доверительные границы со ссылкой на схему, STRIDE-таблица, DREAD);
- OWASP SC Top 10 (2025) маппинг;
- описание уязвимости, способ воспроизведения с TxID, нарушенные инварианты, почему EP её не остановила;
- реализованные меры защиты (матрица авторизации, инварианты, валидация);
- конфигурация PDC с пояснением полей, дизайн против утечки transient, доказательства отсутствия реквизитов в публичном Ledger;
- таблица security-тестов с результатами;
- выводы.

## 12. Скриншоты для пользователя

`docs/report/screenshots/task2/CHECKLIST.md`:
1. `querycommitted` для `paymentvuln` и `paymentsecure` (видна коллекция).
2. Успешная атака Org2 на `paymentvuln` (Submit → Settle, VALID).
3. История `PO-V001` с MSP создателя Submit = Org2MSP.
4. Тот же Submit от Org2 на `paymentsecure` → ошибка.
5. `SetSettlementDetails` с transient (без вывода самих реквизитов в кадре) и VALID.
6. `grep -c` по блоку = 0.
7. CouchDB: базы `$$p`/`$$h` на Org1 и только `$$h` на Org2.
8. SEC-01 (Org1 читает, значения маскированы) и SEC-02/03 (Org2 — отказ).
9. Итоговая таблица security-тестов.

## 13. Definition of Done

- [ ] OWASP SC Top 10 (2025) сверен с официальным сайтом, маппинг с обоснованием применимости.
- [ ] Модель угроз: активы, участники, TB1–TB6, DFD, ≥ 12 угроз STRIDE по всем 7 компонентам, DREAD, меры, тесты.
- [ ] Пользователи с атрибутами `role` выпущены Fabric CA; секреты только в `.secrets/`.
- [ ] `paymentvuln` содержит ровно одну ошибку, развёрнут отдельно, атака от Org2 воспроизведена с TxID.
- [ ] `paymentsecure`: MSP + identity + role + переходы + инварианты + `GetTransient` / `PutPrivateData` / `GetPrivateData`.
- [ ] PDC доступна только Org1, развёрнута с collections-config.
- [ ] Доказано отсутствие реквизитов в аргументах, блоке, CouchDB Org2 и логах.
- [ ] ≥ 6 (план — 16) security-тестов PASS; Org1 читает `privateDetails`, Org2 получает отказ.
- [ ] Эксплойт на `paymentsecure` даёт отказ (доказательство исправления).
- [ ] `payment` по-прежнему 1.0 / seq 1; сеть оставлена запущенной для Задания 3.
- [ ] `docs/report/02_task2.md` готов; evidence прошли redaction; поиск секретов пуст.
