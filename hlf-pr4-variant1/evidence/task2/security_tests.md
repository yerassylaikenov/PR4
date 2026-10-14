# Security-тесты paymentsecure (прогон 114822, 2026-10-14 11:48:48)

Скрипт: `tests/security/run_security_tests.sh`. Объекты прогона: `PO-114822-A` (полный цикл), `PO-114822-B` (CREATED + реквизиты), `PO-114822-C` (CREATED без реквизитов). Значения реквизитов маскированы.

| ID | OWASP SC | Сценарий | Идентичность / peer | Ожидание | Фактический результат | TxID | Итог |
|---|---|---|---|---|---|---|---|
| SEC-01 | SC01 | initiator1 читает реквизиты на peer0.org1 | Org1MSP/initiator1@peer0.org1 | данные получены | `payerIBAN=KZ**************0001` | - | **PASS** |
| SEC-02 | SC01 | processor2 (Org2) читает реквизиты на peer0.org2 | Org2MSP/processor2@peer0.org2 | отказ | `ERR_UNAUTHORIZED: caller organisation is not allowed to perform this operation` | - | **PASS** |
| SEC-03 | SC01 | processor2 (Org2) читает реквизиты на peer0.org1 | Org2MSP/processor2@peer0.org1 | отказ | `ERR_UNAUTHORIZED: caller organisation is not allowed to perform this operation` | - | **PASS** |
| SEC-04 | SC01/SC03 | повтор эксплойта: processor2 (Org2) Submit чужого поручения | Org2MSP/processor2 | отказ | `ERR_UNAUTHORIZED: caller organisation is not allowed to perform this operation` | - | **PASS** |
| SEC-05 | SC01/SC03 | initiator1 сам авторизует своё поручение (нет роли approver, 4 глаза) | Org1MSP/initiator1 | отказ | `ERR_UNAUTHORIZED: caller role is not permitted for this operation` | - | **PASS** |
| SEC-06 | SC01 | norole1 (Org1 без роли) создаёт поручение | Org1MSP/norole1 | отказ | `ERR_UNAUTHORIZED: caller role is not permitted for this operation` | - | **PASS** |
| SEC-07 | SC03 | Settle из SUBMITTED в обход ACCEPTED | Org2MSP/processor2 | отказ | `ERR_INVALID_TRANSITION: transition SUBMITTED -> SETTLED is not allowed` | - | **PASS** |
| SEC-08 | SC03 | повторный Settle уже исполненного поручения (replay) | Org2MSP/processor2 | отказ | `ERR_INVALID_TRANSITION: transition SETTLED -> SETTLED is not allowed` | `488594d3cc545635…` | **PASS** |
| SEC-09 | SC03 | Create с существующим ID | Org1MSP/initiator1 | отказ | `ERR_ALREADY_EXISTS: payment order PO-114822-A already exists` | - | **PASS** |
| SEC-10 | SC04/SC08 | невалидные: сумма -1, 0, 2^63, 1e3; валюта XXX; IBAN с ошибкой контрольной суммы | Org1MSP/initiator1 | отказ на каждый вариант | `amount=-1:✔ amount=0:✔ amount=9223372036854775808:✔ amount=1e3:✔ XXX:✔ IBAN mod-97:✔` | - | **PASS** |
| SEC-11 | SC04/SC10 | SetSettlementDetails: без transient / >4 КБ / короткая соль / лишнее поле | Org1MSP/initiator1@peer0.org1 | отказ | `без transient:✔ >4КБ:✔ короткая соль:✔ лишнее поле:✔` | - | **PASS** |
| SEC-12 | SC03 | SetSettlementDetails после SUBMITTED/SETTLED (INV-9) | Org1MSP/initiator1@peer0.org1 | отказ | `ERR_INVALID_TRANSITION: settlement details can only be set while status is CREATED` | - | **PASS** |
| SEC-13 | SC01 | processor2 Verify: верный кандидат → true, неверный → false | Org2MSP/processor2@peer0.org2 | true / false | `верный: match=true; неверный: match=false` | - | **PASS** |
| SEC-14 | SC10 | GetAllPaymentOrders pageSize=10000 | Org2MSP/processor2 | отказ (лимит 50) | `ERR_VALIDATION: pageSize must be in range 1..50` | - | **PASS** |
| SEC-15 | SC01 (Info. Disclosure) | маркеры реквизитов: все 50 блоков канала, все базы CouchDB Org2, логи контейнеров | — | 0 совпадений | `блоки=0 couchdb1=0 логи=0` | - | **PASS** |
| SEC-16 | SC03 | Submit поручения без реквизитов (INV-9) | Org1MSP/approver1 | отказ | `ERR_VALIDATION: settlement details must be set before submit` | - | **PASS** |
| SEC-17 | SC01 (Info. Disclosure) | SetSettlementDetails отправлен на peer0.org2 (не член коллекции) | Org1MSP/initiator1@peer0.org2 | отказ | `ERR_UNAUTHORIZED: client organisation does not match the peer organisation` | - | **PASS** |

**Итого: 17 PASS, 0 FAIL из 17.**
