package chaincode

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"time"

	"github.com/hyperledger/fabric-contract-api-go/v2/contractapi"
)

// SmartContract implements the PaymentOrder lifecycle (chaincode "payment" v1.0).
type SmartContract struct {
	contractapi.Contract
}

// ---------------------------------------------------------------------------
// Submit transactions
// ---------------------------------------------------------------------------

// CreatePaymentOrder creates a new order in status CREATED. Only the sender bank (Org1MSP).
func (s *SmartContract) CreatePaymentOrder(ctx contractapi.TransactionContextInterface,
	id, receiverBankMSP, amount, currency, purposeCode, reference string) (*PaymentOrder, error) {

	// OWASP SC01:2025 — access control: only the sender bank originates payment orders.
	callerMSP, err := ctx.GetClientIdentity().GetMSPID()
	if err != nil {
		return nil, newErr(ErrInternal, "cannot read caller MSP")
	}
	if callerMSP != SenderBankMSPID {
		return nil, newErr(ErrUnauthorized, "caller organisation may not create payment orders")
	}

	// OWASP SC04:2025 — input validation of every argument before any state access.
	if err := validateID(id); err != nil {
		return nil, err
	}
	if !isBankMSP(receiverBankMSP) || receiverBankMSP == callerMSP {
		return nil, newErr(ErrValidation, "receiverBankMSP must be a known bank different from the sender")
	}
	amt, err := parseAmount(amount)
	if err != nil {
		return nil, err
	}
	if err := validateCurrency(currency); err != nil {
		return nil, err
	}
	if err := validatePurposeCode(purposeCode); err != nil {
		return nil, err
	}
	if err := validateText("reference", reference, MaxReferenceRunes); err != nil {
		return nil, err
	}

	// OWASP SC03:2025 — invariant I-1: unique ID (no overwrite of an existing order).
	exists, err := s.PaymentOrderExists(ctx, id)
	if err != nil {
		return nil, err
	}
	if exists {
		return nil, newErr(ErrAlreadyExists, "payment order %s already exists", id)
	}

	creatorHash, err := callerIDHash(ctx)
	if err != nil {
		return nil, err
	}
	now, err := txTime(ctx)
	if err != nil {
		return nil, err
	}
	po := &PaymentOrder{
		DocType:         DocTypePaymentOrder,
		ID:              id,
		SenderBankMSP:   callerMSP, // invariant I-2: sender = creator MSP
		ReceiverBankMSP: receiverBankMSP,
		Amount:          amt,
		Currency:        currency,
		PurposeCode:     purposeCode,
		Reference:       reference,
		Status:          StatusCreated,
		CreatedByHash:   creatorHash,
		CreatedAt:       now,
		UpdatedAt:       now,
		LastTxID:        ctx.GetStub().GetTxID(),
	}
	if err := putOrder(ctx, po); err != nil {
		return nil, err
	}
	if err := emit(ctx, "PaymentOrderCreated", po); err != nil {
		return nil, err
	}
	return po, nil
}

// SubmitPaymentOrder — sender bank authorises the debit: CREATED -> SUBMITTED.
func (s *SmartContract) SubmitPaymentOrder(ctx contractapi.TransactionContextInterface, id string) (*PaymentOrder, error) {
	return s.transition(ctx, id, StatusSubmitted, partySender, "")
}

// AcceptPaymentOrder — receiver bank accepts: SUBMITTED -> ACCEPTED.
func (s *SmartContract) AcceptPaymentOrder(ctx contractapi.TransactionContextInterface, id string) (*PaymentOrder, error) {
	return s.transition(ctx, id, StatusAccepted, partyReceiver, "")
}

// RejectPaymentOrder — receiver bank rejects: SUBMITTED -> REJECTED (terminal).
func (s *SmartContract) RejectPaymentOrder(ctx contractapi.TransactionContextInterface, id, reasonCode string) (*PaymentOrder, error) {
	if err := validateReasonCode(reasonCode); err != nil {
		return nil, err
	}
	return s.transition(ctx, id, StatusRejected, partyReceiver, reasonCode)
}

// SettlePaymentOrder — main business operation, the receiver bank credits the beneficiary:
// ACCEPTED -> SETTLED (terminal). Exactly once (SETTLED has no outgoing transitions).
func (s *SmartContract) SettlePaymentOrder(ctx contractapi.TransactionContextInterface, id string) (*PaymentOrder, error) {
	return s.transition(ctx, id, StatusSettled, partyReceiver, "")
}

// CancelPaymentOrder — sender bank withdraws the order: CREATED|SUBMITTED -> CANCELLED (terminal).
func (s *SmartContract) CancelPaymentOrder(ctx contractapi.TransactionContextInterface, id string) (*PaymentOrder, error) {
	return s.transition(ctx, id, StatusCancelled, partySender, "")
}

// ---------------------------------------------------------------------------
// Evaluate transactions
// ---------------------------------------------------------------------------

// ReadPaymentOrder returns the public state of an order.
func (s *SmartContract) ReadPaymentOrder(ctx contractapi.TransactionContextInterface, id string) (*PaymentOrder, error) {
	if err := validateID(id); err != nil {
		return nil, err
	}
	return getOrder(ctx, id)
}

// PaymentOrderExists reports whether an order with the given ID exists.
func (s *SmartContract) PaymentOrderExists(ctx contractapi.TransactionContextInterface, id string) (bool, error) {
	if err := validateID(id); err != nil {
		return false, err
	}
	b, err := ctx.GetStub().GetState(id)
	if err != nil {
		return false, newErr(ErrInternal, "failed to read world state")
	}
	return b != nil, nil
}

// GetAllPaymentOrders lists orders page by page (pageSize 1..50, bookmark from the previous page).
func (s *SmartContract) GetAllPaymentOrders(ctx contractapi.TransactionContextInterface,
	pageSize int32, bookmark string) (*PaginatedResult, error) {

	// OWASP SC10:2025 — denial of service: bounded, paginated range query over the PO- key space only.
	if err := validatePageSize(pageSize); err != nil {
		return nil, err
	}
	if len(bookmark) > 64 {
		return nil, newErr(ErrValidation, "bookmark too long")
	}
	it, meta, err := ctx.GetStub().GetStateByRangeWithPagination("PO-", "PO.", pageSize, bookmark)
	if err != nil {
		return nil, newErr(ErrInternal, "range query failed")
	}
	defer it.Close()

	res := &PaginatedResult{Records: []*PaymentOrder{}}
	for it.HasNext() {
		kv, err := it.Next()
		if err != nil {
			return nil, newErr(ErrInternal, "range iteration failed")
		}
		var po PaymentOrder
		if err := json.Unmarshal(kv.Value, &po); err != nil || po.DocType != DocTypePaymentOrder {
			continue
		}
		res.Records = append(res.Records, &po)
	}
	res.FetchedRecordsCount = meta.GetFetchedRecordsCount()
	res.Bookmark = meta.GetBookmark()
	return res, nil
}

// GetPaymentOrderHistory returns every committed version of the order (GetHistoryForKey).
func (s *SmartContract) GetPaymentOrderHistory(ctx contractapi.TransactionContextInterface, id string) ([]*HistoryRecord, error) {
	if err := validateID(id); err != nil {
		return nil, err
	}
	it, err := ctx.GetStub().GetHistoryForKey(id)
	if err != nil {
		return nil, newErr(ErrInternal, "history query failed")
	}
	defer it.Close()

	out := []*HistoryRecord{}
	for it.HasNext() {
		m, err := it.Next()
		if err != nil {
			return nil, newErr(ErrInternal, "history iteration failed")
		}
		rec := &HistoryRecord{TxID: m.GetTxId(), IsDelete: m.GetIsDelete()}
		if ts := m.GetTimestamp(); ts != nil {
			rec.Timestamp = ts.AsTime().UTC().Format(time.RFC3339)
		}
		if !m.GetIsDelete() && len(m.GetValue()) > 0 {
			var po PaymentOrder
			if err := json.Unmarshal(m.GetValue(), &po); err == nil {
				rec.Value = &po
			}
		}
		out = append(out, rec)
	}
	return out, nil
}

// ---------------------------------------------------------------------------
// Internal helpers (unexported: not exposed as chaincode functions)
// ---------------------------------------------------------------------------

type party int

const (
	partySender party = iota
	partyReceiver
)

// transition applies one state-machine edge after authorisation and validation.
// One transaction = one transition (OWASP SC07:2025 analogue: no multi-step atomic shortcuts).
func (s *SmartContract) transition(ctx contractapi.TransactionContextInterface,
	id, to string, who party, reason string) (*PaymentOrder, error) {

	if err := validateID(id); err != nil {
		return nil, err
	}
	po, err := getOrder(ctx, id)
	if err != nil {
		return nil, err
	}

	// OWASP SC01:2025 — access control: caller MSP must be the party that owns this step.
	callerMSP, err := ctx.GetClientIdentity().GetMSPID()
	if err != nil {
		return nil, newErr(ErrInternal, "cannot read caller MSP")
	}
	required := po.SenderBankMSP
	if who == partyReceiver {
		required = po.ReceiverBankMSP
	}
	if callerMSP != required {
		return nil, newErr(ErrUnauthorized, "caller organisation is not allowed to move %s to %s", id, to)
	}

	// OWASP SC03:2025 — logic errors: only edges from allowedTransitions are accepted.
	if !canTransition(po.Status, to) {
		return nil, newErr(ErrInvalidTransition, "transition %s -> %s is not allowed", po.Status, to)
	}

	now, err := txTime(ctx)
	if err != nil {
		return nil, err
	}
	// Invariant I-3: amount, currency, senderBankMSP, receiverBankMSP are never written here.
	po.Status = to
	if reason != "" {
		po.RejectReason = reason
	}
	po.UpdatedAt = now
	po.LastTxID = ctx.GetStub().GetTxID()
	if err := putOrder(ctx, po); err != nil {
		return nil, err
	}
	if err := emit(ctx, "PaymentOrder"+eventSuffix(to), po); err != nil {
		return nil, err
	}
	return po, nil
}

func eventSuffix(status string) string {
	switch status {
	case StatusSubmitted:
		return "Submitted"
	case StatusAccepted:
		return "Accepted"
	case StatusRejected:
		return "Rejected"
	case StatusSettled:
		return "Settled"
	case StatusCancelled:
		return "Cancelled"
	case StatusReturned:
		return "Returned"
	}
	return "Updated"
}

func getOrder(ctx contractapi.TransactionContextInterface, id string) (*PaymentOrder, error) {
	b, err := ctx.GetStub().GetState(id)
	if err != nil {
		return nil, newErr(ErrInternal, "failed to read world state")
	}
	if b == nil {
		return nil, newErr(ErrNotFound, "payment order %s does not exist", id)
	}
	var po PaymentOrder
	if err := json.Unmarshal(b, &po); err != nil {
		return nil, newErr(ErrInternal, "corrupted payment order")
	}
	return &po, nil
}

func putOrder(ctx contractapi.TransactionContextInterface, po *PaymentOrder) error {
	// Lazy migration (v2.0): every write stores the current schema; untouched v1.0 objects stay as they are.
	po.SchemaVersion = SchemaVersionV2
	b, err := json.Marshal(po)
	if err != nil {
		return newErr(ErrInternal, "marshal failed")
	}
	if err := ctx.GetStub().PutState(po.ID, b); err != nil {
		return newErr(ErrInternal, "failed to write world state")
	}
	return nil
}

// emit publishes a chaincode event without amounts or personal data.
func emit(ctx contractapi.TransactionContextInterface, name string, po *PaymentOrder) error {
	payload, _ := json.Marshal(struct {
		ID     string `json:"id"`
		Status string `json:"status"`
		TxID   string `json:"txId"`
	}{po.ID, po.Status, po.LastTxID})
	if err := ctx.GetStub().SetEvent(name, payload); err != nil {
		return newErr(ErrInternal, "failed to set event")
	}
	return nil
}

// txTime — OWASP SC09:2025 — determinism: the proposal timestamp is identical on every endorser,
// unlike time.Now().
func txTime(ctx contractapi.TransactionContextInterface) (string, error) {
	ts, err := ctx.GetStub().GetTxTimestamp()
	if err != nil || ts == nil {
		return "", newErr(ErrInternal, "cannot read transaction timestamp")
	}
	return ts.AsTime().UTC().Format(time.RFC3339), nil
}

// callerIDHash stores only sha256 of the X.509 identity (no employee personal data on the ledger).
func callerIDHash(ctx contractapi.TransactionContextInterface) (string, error) {
	id, err := ctx.GetClientIdentity().GetID()
	if err != nil {
		return "", newErr(ErrInternal, "cannot read caller identity")
	}
	sum := sha256.Sum256([]byte(id))
	return hex.EncodeToString(sum[:]), nil
}
