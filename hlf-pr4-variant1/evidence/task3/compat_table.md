# Проверка обратной совместимости payment 2.0 (C1–C9)

| Проверка | Действие через v2.0 | Ожидание | Факт | TxID | Итог |
|---|---|---|---|---|---|
| C1 | ReadPaymentOrder(PO-0001) через v2.0 | идентично снимку v1 | diff пуст, `schemaVersion` отсутствует | - | **PASS** |
| C2 | GetAllPaymentOrders → state_after.json | sha256 = state_v1 | `69f0ea3b7778c52a…` = `69f0ea3b7778c52a…` | - | **PASS** |
| C3 | Submit → Accept → Settle PO-0003 (объект v1.0) | VALID, затем schemaVersion 2 | VALID ×3, schemaVersion=2 | `7aeadc7424c1…` `25cd07a46b7d…` `bb508e5e995e…` | **PASS** |
| C4 | ReturnPaymentOrder(PO-0001) | VALID, RETURNED | VALID, RETURNED, returnReason=ACCOUNT_CLOSED | `eb1cf454ae93377e…` | **PASS** |
| C5 | повторный Return PO-0001 | отказ | ERR_INVALID_TRANSITION: transition RETURNED -> RETURNED is not allowed | - | **PASS** |
| C6 | GetPaymentOrdersByStatus(SETTLED) | находит PO-0003 | PO-0003 | - | **PASS** |
| C7 | PO-0006: Create, SetValueDate, Submit, Accept, Settle | VALID | VALID ×5, SETTLED | `72a38c3f85f95efd…` | **PASS** |
| C8 | GetPaymentOrderHistory(PO-0001) | TxID v1.0 и v2.0 | T1–T4 (v1.0) + C4 Return (v2.0) | - | **PASS** |
| C9 | Return PO-0006 от Org1MSP | отказ (SC01) | ERR_UNAUTHORIZED: caller organisation is not allowed to move PO-0006 to RETURN | - | **PASS** |
