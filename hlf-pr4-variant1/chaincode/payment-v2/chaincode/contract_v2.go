package chaincode

import (
	"encoding/json"
	"time"

	"github.com/hyperledger/fabric-contract-api-go/v2/contractapi"
)

// ---------------------------------------------------------------------------
// New functionality of chaincode "payment" v2.0. Signatures and semantics of every v1.0
// function are unchanged (compat rule 6); the functions below are additions only.
// ---------------------------------------------------------------------------

// ReturnPaymentOrder — the receiver bank returns a settled payment (e.g. beneficiary account closed):
// SETTLED -> RETURNED. RETURNED is terminal, so a payment can be returned at most once.
func (s *SmartContract) ReturnPaymentOrder(ctx contractapi.TransactionContextInterface, id, reasonCode string) (*PaymentOrder, error) {
	// OWASP SC04:2025 — reasonCode is a machine-readable identifier only.
	if err := validateReasonCode(reasonCode); err != nil {
		return nil, err
	}
	if err := validateID(id); err != nil {
		return nil, err
	}
	po, err := getOrder(ctx, id)
	if err != nil {
		return nil, err
	}
	// OWASP SC01:2025 — only the receiver bank of this order may return it.
	caller, err := ctx.GetClientIdentity().GetMSPID()
	if err != nil {
		return nil, newErr(ErrInternal, "cannot read caller MSP")
	}
	if caller != po.ReceiverBankMSP {
		return nil, newErr(ErrUnauthorized, "caller organisation is not allowed to move %s to %s", id, StatusReturned)
	}
	// OWASP SC03:2025 — only SETTLED -> RETURNED; RETURNED has no outgoing edges (no second return).
	if !canTransition(po.Status, StatusReturned) {
		return nil, newErr(ErrInvalidTransition, "transition %s -> %s is not allowed", po.Status, StatusReturned)
	}
	now, err := txTime(ctx)
	if err != nil {
		return nil, err
	}
	po.Status = StatusReturned
	po.ReturnReason = reasonCode
	po.ReturnedAt = now
	po.UpdatedAt = now
	po.LastTxID = ctx.GetStub().GetTxID()
	if err := putOrder(ctx, po); err != nil {
		return nil, err
	}
	if err := emit(ctx, "PaymentOrderReturned", po); err != nil {
		return nil, err
	}
	return po, nil
}

// SetValueDate — the sender bank sets the value date (YYYY-MM-DD) while the order is CREATED.
// A separate function keeps the v1.0 signature of CreatePaymentOrder unchanged.
func (s *SmartContract) SetValueDate(ctx contractapi.TransactionContextInterface, id, date string) (*PaymentOrder, error) {
	if err := validateID(id); err != nil {
		return nil, err
	}
	// OWASP SC04:2025 — strict calendar date.
	d, err := time.Parse("2006-01-02", date)
	if err != nil || d.Format("2006-01-02") != date {
		return nil, newErr(ErrValidation, "valueDate must be a calendar date YYYY-MM-DD")
	}
	po, err := getOrder(ctx, id)
	if err != nil {
		return nil, err
	}
	// OWASP SC01:2025 — only the sender bank.
	caller, err := ctx.GetClientIdentity().GetMSPID()
	if err != nil {
		return nil, newErr(ErrInternal, "cannot read caller MSP")
	}
	if caller != po.SenderBankMSP {
		return nil, newErr(ErrUnauthorized, "caller organisation may not set the value date")
	}
	// OWASP SC03:2025 — terms are fixed once the debit is authorised.
	if po.Status != StatusCreated {
		return nil, newErr(ErrInvalidTransition, "value date can only be set while status is CREATED")
	}
	// The value date cannot precede the creation date (createdAt is RFC 3339 from GetTxTimestamp).
	if len(po.CreatedAt) >= 10 && date < po.CreatedAt[:10] {
		return nil, newErr(ErrValidation, "valueDate cannot be earlier than the creation date")
	}
	now, err := txTime(ctx)
	if err != nil {
		return nil, err
	}
	po.ValueDate = date
	po.UpdatedAt = now
	po.LastTxID = ctx.GetStub().GetTxID()
	if err := putOrder(ctx, po); err != nil {
		return nil, err
	}
	return po, nil
}

// GetPaymentOrdersByStatus — CouchDB rich query over the indexStatus index, paginated (evaluate only).
// The result is never used for a write in the same transaction (rich queries are not re-validated: no phantom
// read protection), so it is read-only by design.
func (s *SmartContract) GetPaymentOrdersByStatus(ctx contractapi.TransactionContextInterface,
	status string, pageSize int32, bookmark string) (*PaginatedResult, error) {

	// OWASP SC04:2025 — whitelisted status; the selector is built with json.Marshal, never by string
	// concatenation, so no CouchDB selector injection ($gt, $regex, ...) is possible.
	if !isStatus(status) {
		return nil, newErr(ErrValidation, "unknown status")
	}
	// OWASP SC10:2025 — bounded page.
	if err := validatePageSize(pageSize); err != nil {
		return nil, err
	}
	if len(bookmark) > 256 {
		return nil, newErr(ErrValidation, "bookmark too long")
	}
	q, _ := json.Marshal(map[string]any{
		"selector":  map[string]string{"docType": DocTypePaymentOrder, "status": status},
		"use_index": []string{"_design/indexStatusDoc", "indexStatus"},
	})
	it, meta, err := ctx.GetStub().GetQueryResultWithPagination(string(q), pageSize, bookmark)
	if err != nil {
		return nil, newErr(ErrInternal, "rich query failed")
	}
	defer it.Close()
	res := &PaginatedResult{Records: []*PaymentOrder{}}
	for it.HasNext() {
		kv, err := it.Next()
		if err != nil {
			return nil, newErr(ErrInternal, "query iteration failed")
		}
		var po PaymentOrder
		if json.Unmarshal(kv.Value, &po) != nil || po.DocType != DocTypePaymentOrder {
			continue
		}
		res.Records = append(res.Records, &po)
	}
	res.FetchedRecordsCount = meta.GetFetchedRecordsCount()
	res.Bookmark = meta.GetBookmark()
	return res, nil
}

func isStatus(s string) bool {
	switch s {
	case StatusCreated, StatusSubmitted, StatusAccepted, StatusRejected, StatusSettled, StatusCancelled, StatusReturned:
		return true
	}
	return false
}
