# `paymentvuln` vs `paymentsecure` — один и тот же сценарий атаки

Центральное доказательство для порога «70 баллов»: разграничение доступа и исправление уязвимой бизнес-логики подтверждены практически.

## Сценарий

Org1 (`initiator1`) создаёт черновик `PO-V001` и **не** авторизует его. Сотрудник банка-получателя `processor2` (Org2MSP) пытается в одиночку провести платёж: Submit → Accept → Settle.

| Шаг | `paymentvuln` (evidence/task2/21_exploit.log) | `paymentsecure` (evidence/task2/25_exploit_secure.log, SEC-04) |
|---|---|---|
| Create `PO-V001` (Org1/initiator1) | VALID, `aec25bf324b0dcc150da24a002902ea9313ffc600b23ba0e7cd963df87aa5bb9`, блок 21 | VALID, `098a42fbe0bca0207650eb92f455a9c3fa430524b6b564ca1ee85d7a89b12649` |
| **Submit (Org2/processor2)** | **VALID**, `e4545b3d0965b2b4dfc8c3174c3f58229c1d16c6dd33d6f21c4b110ac6824fe5`, блок 22 — создатель Org2MSP, endorsements Org1MSP + Org2MSP | **отказ при endorsement**: `ERR_UNAUTHORIZED: caller organisation is not allowed to perform this operation` |
| Accept (Org2) | VALID, `1849dc33a9b343de06e674641168241b30b5ac731e8faf4daecfe3e52eae6f0c`, блок 23 | отказ: `ERR_INVALID_TRANSITION: transition CREATED -> ACCEPTED is not allowed` |
| Settle (Org2) | VALID, `cc728cfaf332db86f8b71677b875176870ee089c8bd08a0da5d3bc359232a4dd`, блок 24 | отказ: `ERR_INVALID_TRANSITION: transition CREATED -> SETTLED is not allowed` |
| Итоговый статус | **SETTLED** — платёж исполнен без авторизации отправителя | **CREATED** — состояние не изменилось |

## Diff функции Submit

`paymentvuln` относительно `payment` v1.0 (`evidence/task2/22_vuln_diff.patch`, ровно одна логическая ошибка):

```diff
 func (s *SmartContract) SubmitPaymentOrder(ctx contractapi.TransactionContextInterface, id string) (*PaymentOrder, error) {
-	return s.transition(ctx, id, StatusSubmitted, partySender, "")
+	return s.transition(ctx, id, StatusSubmitted, partyAnyone, "")
 }
 ...
-	if callerMSP != required {
+	if who != partyAnyone && callerMSP != required {
```

`paymentsecure` (`chaincode/payment-secure/chaincode/contract.go`):

```go
func (s *SmartContract) SubmitPaymentOrder(ctx contractapi.TransactionContextInterface, id string) (*PaymentOrder, error) {
	...
	if err := requireMSP(ctx, po.SenderBankMSP); err != nil { // OWASP SC01:2025 — INV-4
		return nil, err
	}
	if err := requireRole(ctx, RoleApprover); err != nil {     // role attribute from Fabric CA
		return nil, err
	}
	if approver == po.CreatedByHash {                           // OWASP SC03:2025 — INV-5 four eyes
		return nil, newErr(ErrUnauthorized, "four-eyes principle: ...")
	}
	... canTransition(...)                                      // state machine
	h, _ := ctx.GetStub().GetPrivateDataHash(CollectionSettlement, id)
	if h == nil { ... "settlement details must be set before submit" } // INV-9
```

## Какие инварианты теперь соблюдаются

| Инвариант | `paymentvuln` | `paymentsecure` | Доказательство |
|---|---|---|---|
| INV-4: Submit только approver банка-отправителя | нарушен (V2) | соблюдён | SEC-04, SEC-05 |
| INV-SoD: ни одна организация не проводит платёж единолично | нарушен (V1–V4) | соблюдён (Submit требует Org1 approver, Accept/Settle — Org2 processor) | `25_exploit_secure.log` |
| INV-5: создатель ≠ авторизующий | не проверялся | соблюдён | SEC-05, `TestINV5_FourEyes` |
| INV-9: реквизиты до Submit и неизменны после | — | соблюдён | SEC-12, SEC-16 |

## Маппинг на OWASP

- **SC01:2025 Access Control Vulnerabilities** — первопричина: отсутствие проверки MSP вызывающего в `SubmitPaymentOrder`.
- **SC03:2025 Logic Errors** — следствие: нарушение бизнес-инвариантов INV-4 и INV-SoD при формально корректной state machine.

## Почему Endorsement Policy не помогла

Политика `AND('Org1MSP.peer','Org2MSP.peer')` была **выполнена**: блок 22 содержит endorsements Org1MSP и Org2MSP, код валидации VALID. Оба peers исполнили один и тот же ошибочный код, получили одинаковый RW-set и честно его подписали. EP отвечает на вопрос «чьи peers должны подтвердить результат», но не «кто имеет право вызвать функцию». Авторизация вызывающего — ответственность chaincode.
