package chaincode

import (
	"encoding/json"
	"time"

	"github.com/hyperledger/fabric-contract-api-go/v2/contractapi"
)

// SmartContract implements chaincode "paymentsecure".
type SmartContract struct {
	contractapi.Contract
}

// CreatePaymentOrder — Org1MSP, role initiator. Public fields only (no settlement details here,
// otherwise the transient data would reach the Org2 endorser — see docs/security/paymentsecure-design.md §7).
func (s *SmartContract) CreatePaymentOrder(ctx contractapi.TransactionContextInterface,
	id, receiverBankMSP, amount, currency, purposeCode, reference string) (*PaymentOrder, error) {

	// OWASP SC01:2025 — MSP + role; INV-2: the sender bank is the creator's organisation (Org1MSP).
	if err := requireMSP(ctx, SenderBankMSPID); err != nil {
		return nil, err
	}
	if err := requireRole(ctx, RoleInitiator); err != nil {
		return nil, err
	}
	// OWASP SC04:2025 — validate every argument before touching state.
	if err := validateID(id); err != nil {
		return nil, err
	}
	if !isBankMSP(receiverBankMSP) || receiverBankMSP == SenderBankMSPID {
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
	// INV-1 — unique ID.
	exists, err := s.PaymentOrderExists(ctx, id)
	if err != nil {
		return nil, err
	}
	if exists {
		return nil, newErr(ErrAlreadyExists, "payment order %s already exists", id)
	}
	creator, err := callerIDHash(ctx)
	if err != nil {
		return nil, err
	}
	now, err := txTime(ctx)
	if err != nil {
		return nil, err
	}
	po := &PaymentOrder{
		DocType: DocTypePaymentOrder, ID: id, SenderBankMSP: SenderBankMSPID, ReceiverBankMSP: receiverBankMSP,
		Amount: amt, Currency: currency, PurposeCode: purposeCode, Reference: reference, Status: StatusCreated,
		CreatedByHash: creator, CreatedAt: now, UpdatedAt: now, LastTxID: ctx.GetStub().GetTxID(),
	}
	if err := putOrder(ctx, po); err != nil {
		return nil, err
	}
	return po, emit(ctx, "PaymentOrderCreated", po)
}

// SetSettlementDetails — Org1MSP initiator writes the confidential details taken ONLY from the transient
// field "settlement" into collectionSettlementDetails. Writes private keys only (collection-level EP
// OR('Org1MSP.peer'), endorsed by peer0.org1 alone). Allowed only while the order is CREATED (INV-9).
func (s *SmartContract) SetSettlementDetails(ctx contractapi.TransactionContextInterface, id string) error {
	if err := requireMSP(ctx, SenderBankMSPID); err != nil {
		return err
	}
	if err := requireRole(ctx, RoleInitiator); err != nil {
		return err
	}
	// Never process confidential data on a non-member peer.
	if err := requirePeerOrg(ctx); err != nil {
		return err
	}
	if err := validateID(id); err != nil {
		return err
	}
	po, err := getOrder(ctx, id)
	if err != nil {
		return err
	}
	// OWASP SC03:2025 — INV-9: details are immutable once the debit has been authorised.
	if po.Status != StatusCreated {
		return newErr(ErrInvalidTransition, "settlement details can only be set while status is CREATED")
	}
	tm, err := ctx.GetStub().GetTransient()
	if err != nil {
		return newErr(ErrInternal, "cannot read transient map")
	}
	// OWASP SC10:2025 — bound the whole transient map, not only the used key.
	total := 0
	for k, v := range tm {
		total += len(k) + len(v)
	}
	if total > MaxTransientSize {
		return newErr(ErrValidation, "transient payload exceeds %d bytes", MaxTransientSize)
	}
	raw, ok := tm[TransientSettlement]
	if !ok {
		return newErr(ErrValidation, "transient field %q is required", TransientSettlement)
	}
	d, err := decodeSettlement(raw)
	if err != nil {
		return err
	}
	b, err := canonical(d)
	if err != nil {
		return err
	}
	if err := ctx.GetStub().PutPrivateData(CollectionSettlement, id, b); err != nil {
		return newErr(ErrInternal, "failed to write private data")
	}
	return nil
}

// ReadSettlementDetails — Org1MSP initiator/approver on an Org1 peer. The salt is not returned.
func (s *SmartContract) ReadSettlementDetails(ctx contractapi.TransactionContextInterface, id string) (*SettlementView, error) {
	if err := requireMSP(ctx, SenderBankMSPID); err != nil {
		return nil, err
	}
	if err := requireRole(ctx, RoleInitiator, RoleApprover); err != nil {
		return nil, err
	}
	if err := requirePeerOrg(ctx); err != nil {
		return nil, err
	}
	if err := validateID(id); err != nil {
		return nil, err
	}
	b, err := ctx.GetStub().GetPrivateData(CollectionSettlement, id)
	if err != nil {
		return nil, newErr(ErrUnauthorized, "private data is not accessible")
	}
	if b == nil {
		return nil, newErr(ErrNotFound, "settlement details for %s do not exist", id)
	}
	var d SettlementDetails
	if err := json.Unmarshal(b, &d); err != nil {
		return nil, newErr(ErrInternal, "corrupted private data")
	}
	return &SettlementView{ID: id, PayerIBAN: d.PayerIBAN, PayerBIN: d.PayerBIN, BeneficiaryIBAN: d.BeneficiaryIBAN,
		BeneficiaryBIC: d.BeneficiaryBIC, BeneficiaryName: d.BeneficiaryName}, nil
}

// VerifySettlementDetails — any bank of the channel checks a candidate (transient "candidate") against the
// on-chain hash without the details being disclosed: sha256(canonical(candidate)) == GetPrivateDataHash.
func (s *SmartContract) VerifySettlementDetails(ctx contractapi.TransactionContextInterface, id string) (*VerifyResult, error) {
	msp, err := callerMSP(ctx)
	if err != nil {
		return nil, err
	}
	if !isBankMSP(msp) {
		return nil, newErr(ErrUnauthorized, "caller organisation is not a channel bank")
	}
	if err := validateID(id); err != nil {
		return nil, err
	}
	tm, err := ctx.GetStub().GetTransient()
	if err != nil {
		return nil, newErr(ErrInternal, "cannot read transient map")
	}
	raw, ok := tm[TransientCandidate]
	if !ok {
		return nil, newErr(ErrValidation, "transient field %q is required", TransientCandidate)
	}
	d, err := decodeSettlement(raw)
	if err != nil {
		return nil, err
	}
	b, err := canonical(d)
	if err != nil {
		return nil, err
	}
	onChain, err := ctx.GetStub().GetPrivateDataHash(CollectionSettlement, id)
	if err != nil {
		return nil, newErr(ErrInternal, "cannot read private data hash")
	}
	if onChain == nil {
		return nil, newErr(ErrNotFound, "settlement details for %s do not exist", id)
	}
	return &VerifyResult{ID: id, Match: hexSHA256(b) == hexBytes(onChain)}, nil
}

// SubmitPaymentOrder — the sender bank authorises the debit (fix of the paymentvuln defect):
// MSP == senderBankMSP (INV-4), role approver, approver != creator (INV-5), settlement details exist (INV-9).
func (s *SmartContract) SubmitPaymentOrder(ctx contractapi.TransactionContextInterface, id string) (*PaymentOrder, error) {
	if err := validateID(id); err != nil {
		return nil, err
	}
	po, err := getOrder(ctx, id)
	if err != nil {
		return nil, err
	}
	// OWASP SC01:2025 — INV-4.
	if err := requireMSP(ctx, po.SenderBankMSP); err != nil {
		return nil, err
	}
	if err := requireRole(ctx, RoleApprover); err != nil {
		return nil, err
	}
	approver, err := callerIDHash(ctx)
	if err != nil {
		return nil, err
	}
	// OWASP SC03:2025 — INV-5: four-eyes principle.
	if approver == po.CreatedByHash {
		return nil, newErr(ErrUnauthorized, "four-eyes principle: the creator cannot approve the same order")
	}
	if !canTransition(po.Status, StatusSubmitted) {
		return nil, newErr(ErrInvalidTransition, "transition %s -> %s is not allowed", po.Status, StatusSubmitted)
	}
	// INV-9: details must exist; their hash is frozen into the public state.
	h, err := ctx.GetStub().GetPrivateDataHash(CollectionSettlement, id)
	if err != nil {
		return nil, newErr(ErrInternal, "cannot read private data hash")
	}
	if h == nil {
		return nil, newErr(ErrValidation, "settlement details must be set before submit")
	}
	po.ApprovedByHash = approver
	po.SettlementHash = hexBytes(h)
	return s.apply(ctx, po, StatusSubmitted, "")
}

// AcceptPaymentOrder — receiver bank processor: SUBMITTED -> ACCEPTED.
func (s *SmartContract) AcceptPaymentOrder(ctx contractapi.TransactionContextInterface, id string) (*PaymentOrder, error) {
	return s.receiverStep(ctx, id, StatusAccepted, "")
}

// RejectPaymentOrder — receiver bank processor: SUBMITTED -> REJECTED.
func (s *SmartContract) RejectPaymentOrder(ctx contractapi.TransactionContextInterface, id, reasonCode string) (*PaymentOrder, error) {
	if err := validateReasonCode(reasonCode); err != nil {
		return nil, err
	}
	return s.receiverStep(ctx, id, StatusRejected, reasonCode)
}

// SettlePaymentOrder — receiver bank processor: ACCEPTED -> SETTLED exactly once (INV-7).
func (s *SmartContract) SettlePaymentOrder(ctx contractapi.TransactionContextInterface, id string) (*PaymentOrder, error) {
	return s.receiverStep(ctx, id, StatusSettled, "")
}

// CancelPaymentOrder — sender bank initiator/approver: CREATED|SUBMITTED -> CANCELLED.
func (s *SmartContract) CancelPaymentOrder(ctx contractapi.TransactionContextInterface, id string) (*PaymentOrder, error) {
	if err := validateID(id); err != nil {
		return nil, err
	}
	po, err := getOrder(ctx, id)
	if err != nil {
		return nil, err
	}
	if err := requireMSP(ctx, po.SenderBankMSP); err != nil {
		return nil, err
	}
	if err := requireRole(ctx, RoleInitiator, RoleApprover); err != nil {
		return nil, err
	}
	return s.apply(ctx, po, StatusCancelled, "")
}

// ReadPaymentOrder — public data only.
func (s *SmartContract) ReadPaymentOrder(ctx contractapi.TransactionContextInterface, id string) (*PaymentOrder, error) {
	if err := validateID(id); err != nil {
		return nil, err
	}
	return getOrder(ctx, id)
}

// PaymentOrderExists reports whether the order exists.
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

// GetAllPaymentOrders — OWASP SC10:2025 — paginated, pageSize 1..50, PO- key range only.
func (s *SmartContract) GetAllPaymentOrders(ctx contractapi.TransactionContextInterface,
	pageSize int32, bookmark string) (*PaginatedResult, error) {
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
		if json.Unmarshal(kv.Value, &po) != nil || po.DocType != DocTypePaymentOrder {
			continue
		}
		res.Records = append(res.Records, &po)
	}
	res.FetchedRecordsCount = meta.GetFetchedRecordsCount()
	res.Bookmark = meta.GetBookmark()
	return res, nil
}

// GetPaymentOrderHistory — public history of the key.
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
		var po PaymentOrder
		if !m.GetIsDelete() && json.Unmarshal(m.GetValue(), &po) == nil {
			rec.Value = &po
		}
		out = append(out, rec)
	}
	return out, nil
}

// ---------------------------------------------------------------------------

// receiverStep — INV-6: only a processor of the receiver bank moves the order after Submit.
func (s *SmartContract) receiverStep(ctx contractapi.TransactionContextInterface, id, to, reason string) (*PaymentOrder, error) {
	if err := validateID(id); err != nil {
		return nil, err
	}
	po, err := getOrder(ctx, id)
	if err != nil {
		return nil, err
	}
	if err := requireMSP(ctx, po.ReceiverBankMSP); err != nil {
		return nil, err
	}
	if err := requireRole(ctx, RoleProcessor); err != nil {
		return nil, err
	}
	return s.apply(ctx, po, to, reason)
}

// apply — OWASP SC03:2025 — one transaction = one legal transition; INV-3 fields are never written.
func (s *SmartContract) apply(ctx contractapi.TransactionContextInterface, po *PaymentOrder, to, reason string) (*PaymentOrder, error) {
	if !canTransition(po.Status, to) {
		return nil, newErr(ErrInvalidTransition, "transition %s -> %s is not allowed", po.Status, to)
	}
	now, err := txTime(ctx)
	if err != nil {
		return nil, err
	}
	po.Status = to
	if reason != "" {
		po.RejectReason = reason
	}
	po.UpdatedAt = now
	po.LastTxID = ctx.GetStub().GetTxID()
	if err := putOrder(ctx, po); err != nil {
		return nil, err
	}
	return po, emit(ctx, "PaymentOrder"+eventSuffix(to), po)
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
	b, err := json.Marshal(po)
	if err != nil {
		return newErr(ErrInternal, "marshal failed")
	}
	if err := ctx.GetStub().PutState(po.ID, b); err != nil {
		return newErr(ErrInternal, "failed to write world state")
	}
	return nil
}

// emit — events carry no amounts, identities or settlement details.
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

// txTime — OWASP SC09:2025 — deterministic proposal timestamp.
func txTime(ctx contractapi.TransactionContextInterface) (string, error) {
	ts, err := ctx.GetStub().GetTxTimestamp()
	if err != nil || ts == nil {
		return "", newErr(ErrInternal, "cannot read transaction timestamp")
	}
	return ts.AsTime().UTC().Format(time.RFC3339), nil
}
