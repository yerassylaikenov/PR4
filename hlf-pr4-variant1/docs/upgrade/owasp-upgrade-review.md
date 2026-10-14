# OWASP SC Top 10 (2025) — ревью изменений `payment` 1.0 → 2.0

| Функция | SC01 Access Control | SC03 Logic Errors | SC04 Input Validation | SC08 Integer | SC09 Determinism | SC10 DoS |
|---|---|---|---|---|---|---|
| `ReturnPaymentOrder` (новая) | только `receiverBankMSP` поручения; C9: Return от Org1 → `ERR_UNAUTHORIZED` | только SETTLED → RETURNED; RETURNED терминален → повтор невозможен (C5); не открывает путь в обход SETTLED: из CREATED/SUBMITTED/ACCEPTED/REJECTED/CANCELLED — `ERR_INVALID_TRANSITION` (`TestReturnPaymentOrder`) | `reasonCode` `^[A-Z0-9_]{2,32}$` | сумма не изменяется (возврат на ту же сумму, отдельной арифметики нет) | время — `GetTxTimestamp` | одна запись |
| `SetValueDate` (новая) | только `senderBankMSP` | только в CREATED: после авторизации списания условия заморожены | строгая календарная дата `time.Parse` + round-trip (отсекает `2026-02-30`), не раньше даты создания | — | сравнение со `createdAt` из транзакции, без `time.Now` | — |
| `GetPaymentOrdersByStatus` (новая) | чтение — члены канала (как остальные evaluate) | **phantom reads:** rich query CouchDB не перепроверяется при валидации, поэтому функция read-only и её результат не используется для записи | статус из белого списка; селектор строится `json.Marshal`, без конкатенации → инъекция (`{"$gt":null}`, `SETTLED","$gt":"`) невозможна (C6, `TestGetPaymentOrdersByStatus`) | — | результат зависит от состояния CouchDB конкретного peer, поэтому используется только в evaluate | `pageSize` 1..50, лимит bookmark 256, индекс `indexStatus` (без full scan) |
| `putOrder` (изменена: `schemaVersion = 2`) | — | поля v1.0 не меняются (`TestLazyMigrationOnFirstWrite`) | — | `amount` остаётся `int64` | константа | — |
| Функции v1.0 | без изменений (регрессионные тесты v1.0 проходят без правок) | таблица переходов только расширена | без изменений | без изменений | без изменений | без изменений |

SC02, SC05, SC06, SC07 — изменения их не затрагивают: внешних источников цены, cross-chaincode вызовов и составных операций в v2.0 не появилось (`check_determinism.sh`: `InvokeChaincode` — 0).
