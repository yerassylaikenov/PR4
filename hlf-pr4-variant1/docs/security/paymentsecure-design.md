# Дизайн `paymentsecure` — защищённая версия chaincode (Задание 2.4–2.5)

`paymentsecure` — отдельное имя chaincode (1.0 / sequence 1, `AND('Org1MSP.peer','Org2MSP.peer')`, коллекция `collectionSettlementDetails`). Устраняет уязвимость `paymentvuln` (SC01/SC03) и добавляет конфиденциальные расчётные реквизиты в Private Data Collection.

## 1. Контроль идентичности и полномочий

| Механизм | Реализация | OWASP |
|---|---|---|
| MSP вызывающего | `ctx.GetClientIdentity().GetMSPID()` | SC01 |
| Роль | `ctx.GetClientIdentity().AssertAttributeValue("role", r)` — атрибут `role` выпущен Fabric CA в ecert (`20_register_users.sh`) | SC01 |
| Идентичность | `GetID()` → в публичный state пишется только `sha256` (`createdByHash`, `approvedByHash`) | SC01, конфиденциальность |
| Чтение private data | MSP клиента == `Org1MSP` **и** == MSP peer (`shim.GetMSPID()`), как в официальном private data tutorial; дополнительно `memberOnlyRead: true` на уровне peer | SC01 |

## 2. Матрица авторизации

| Функция | Тип | MSP | Роль | Доп. условия |
|---|---|---|---|---|
| `CreatePaymentOrder(id, receiverBankMSP, amount, currency, purposeCode, reference)` | submit | Org1MSP | initiator | только публичные поля |
| `SetSettlementDetails(id)` | submit | Org1MSP (и peer Org1MSP) | initiator | статус CREATED; реквизиты только из transient `settlement`; пишет **только** в коллекцию |
| `ReadSettlementDetails(id)` | evaluate | Org1MSP | initiator / approver | MSP клиента == MSP peer; соль не возвращается |
| `VerifySettlementDetails(id)` | evaluate | Org1MSP, Org2MSP | любая | кандидат из transient `candidate`; `sha256(canonical)` vs `GetPrivateDataHash` → `{match}` |
| `SubmitPaymentOrder(id)` | submit | == senderBankMSP | approver | `approvedByHash ≠ createdByHash` (четыре глаза); хэш реквизитов существует; фиксирует `settlementHash` |
| `AcceptPaymentOrder`, `RejectPaymentOrder`, `SettlePaymentOrder` | submit | == receiverBankMSP | processor | по таблице переходов |
| `CancelPaymentOrder(id)` | submit | == senderBankMSP | initiator / approver | CREATED или SUBMITTED |
| `ReadPaymentOrder`, `PaymentOrderExists`, `GetAllPaymentOrders`, `GetPaymentOrderHistory` | evaluate | члены канала | — | только публичные данные, `pageSize` 1..50 |

## 3. Таблица переходов

Как в v1.0: `CREATED → SUBMITTED | CANCELLED`, `SUBMITTED → ACCEPTED | REJECTED | CANCELLED`, `ACCEPTED → SETTLED`; SETTLED / REJECTED / CANCELLED терминальны. Единственный источник истины — `allowedTransitions()`.

## 4. Инварианты

| ID | Инвариант | Код | Unit-тест | Security-тест |
|---|---|---|---|---|
| INV-1 | уникальность ID | `CreatePaymentOrder` | `TestINV1_UniqueID` | SEC-09 |
| INV-2 | `senderBankMSP` = MSP создателя = Org1MSP | `CreatePaymentOrder` | `TestINV2_SenderIsCreatorOrg1` | SEC-06 |
| INV-3 | сумма, валюта и стороны неизменяемы | ни одна функция их не пишет | `TestINV3_ImmutableFields` | SEC-10 |
| INV-4 | Submit только approver банка-отправителя | `SubmitPaymentOrder` | `TestINV4_SubmitOnlySenderApprover` | SEC-04 |
| INV-5 | четыре глаза: создатель ≠ авторизующий | `SubmitPaymentOrder` | `TestINV5_FourEyes` | SEC-05 |
| INV-6 | Accept/Reject/Settle только processor банка-получателя | `transition()` | `TestINV6_ReceiverProcessorOnly` | SEC-07 |
| INV-7 | исполнение ровно один раз и только из ACCEPTED | таблица переходов | `TestINV7_SettleOnceFromAccepted` | SEC-07, SEC-08 |
| INV-8 | терминальные статусы окончательны | таблица переходов | `TestINV8_TerminalStatuses` | SEC-08 |
| INV-9 | реквизиты обязательны до Submit и неизменяемы после него | `SubmitPaymentOrder`, `SetSettlementDetails` (только CREATED) | `TestINV9_DetailsRequiredAndFrozen` | SEC-12, SEC-16 |

## 5. Схема данных private-коллекции

Ключ — ID поручения, значение — канонический JSON (фиксированный порядок полей Go-структуры):

```json
{"payerIBAN":"KZ…","payerBIN":"…12 цифр…","beneficiaryIBAN":"KZ…","beneficiaryBIC":"…8/11…","beneficiaryName":"…","salt":"…≥32 hex…"}
```

| Поле | Валидация (SC04) |
|---|---|
| `payerIBAN`, `beneficiaryIBAN` | `^[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}$`, контрольная сумма ISO 13616 mod-97 = 1, для KZ ровно 20 символов |
| `beneficiaryBIC` | `^[A-Z]{4}[A-Z]{2}[A-Z0-9]{2}([A-Z0-9]{3})?$` |
| `payerBIN` | БИН/ИИН — ровно 12 цифр |
| `beneficiaryName` | 1..140 рун, валидный UTF-8, без управляющих символов |
| `salt` | 32..128 hex-символов; генерирует **клиент** (`openssl rand -hex 32`) |
| весь transient | ≤ 4096 байт, неизвестные поля отклоняются (`DisallowUnknownFields`), лишние данные после JSON — отказ |

Назначение соли: хэш значения private data виден всем участникам канала и orderer (в блоке и в `$$h`-базе Org2). Реквизиты низкоэнтропийны (IBAN проверяем, БИН — 12 цифр), без соли хэш можно перебрать. Соль генерирует клиент, потому что `crypto/rand` в chaincode дал бы разные RW-set на endorsers (SC09).

Тексты ошибок не содержат значений реквизитов, chaincode ничего не пишет в лог.

## 6. Collection config (`collections/collections_config.json`)

| Поле | Значение | Смысл |
|---|---|---|
| `name` | `collectionSettlementDetails` | имя коллекции в `PutPrivateData/GetPrivateData` |
| `policy` | `OR('Org1MSP.member')` | члены коллекции: только peers Org1 хранят открытые данные; остальные получают хэши |
| `requiredPeerCount` | 0 | endorsing peer не обязан распространить данные другим peers до ответа (у Org1 один peer) |
| `maxPeerCount` | 1 | максимум peers для распространения по gossip при endorsement |
| `blockToLive` | 0 | данные хранятся бессрочно |
| `memberOnlyRead` | true | peer отклоняет `GetPrivateData` от клиента не из Org1 (доп. к проверке в коде) |
| `memberOnlyWrite` | true | писать в коллекцию могут только клиенты Org1 |
| `endorsementPolicy` | `OR('Org1MSP.peer')` | collection-level EP: транзакции, пишущие только в коллекцию, достаточно endorse peer0.org1 |

**`blockToLive: 0` в банковском домене.** Платёжные документы и расчётные реквизиты подлежат хранению в течение установленного законом срока (для банков РК — не менее 5 лет), поэтому автоматическое удаление через N блоков неприемлемо: оно произошло бы по числу блоков, а не по календарю, и могло бы уничтожить данные раньше срока. Альтернативы при регуляторном требовании удаления: ненулевой `blockToLive` (при предсказуемой частоте блоков) или явное удаление `PurgePrivateData` (Fabric 2.5+), удаляющее и историю private data на всех peers, — вызывается отдельной авторизованной функцией по истечении срока хранения.

## 7. Ключевое дизайн-решение: реквизиты не уходят к Org2 на этапе Execute

**Отвергнутый вариант (найденная угроза).** Передавать реквизиты в `CreatePaymentOrder` или `SubmitPaymentOrder` вместе с публичной записью. Публичная запись требует AND-политики → proposal с transient отправляется и на peer0.org2 → банк-получатель видит реквизиты в открытом виде на этапе Execute, хотя не является членом коллекции. STRIDE: **Information Disclosure** (T-07 в `threat-model.md`), OWASP **SC01** (доступ к данным в обход членства коллекции).

**Принятое решение — две транзакции:**
1. `CreatePaymentOrder` — публичная транзакция, endorse обоими peers (AND), без реквизитов.
2. `SetSettlementDetails` — пишет **только** private-ключи. Для коллекции задан collection-level EP `OR('Org1MSP.peer')`, транзакция отправляется **только** на peer0.org1 (CLI: один `--peerAddresses`; Gateway: `WithTransient` + `WithEndorsingOrganizations("Org1MSP")`). Дополнительно chaincode отказывается обрабатывать `SetSettlementDetails` на peer чужой организации (`shim.GetMSPID() != Org1MSP`).
3. `SubmitPaymentOrder` (AND, оба peers) проверяет наличие хэша реквизитов через `GetPrivateDataHash` — он доступен и peer0.org2 — и фиксирует его в публичном поле `settlementHash`: Org2 получает неизменяемое обязательство на реквизиты без их раскрытия и может сверить кандидат через `VerifySettlementDetails`.

Эмпирическая проверка (VALID-статус транзакции, endorse только peer0.org1) — `evidence/task2/23_private_flow.log`.
