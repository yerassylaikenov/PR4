package chaincode

// DocTypePaymentOrder marks PaymentOrder documents in the world state (CouchDB selector friendly).
const DocTypePaymentOrder = "PaymentOrder"

// SenderBankMSPID is the only organisation allowed to originate payment orders in variant 1.
const SenderBankMSPID = "Org1MSP"

// Payment order statuses.
const (
	StatusCreated   = "CREATED"
	StatusSubmitted = "SUBMITTED"
	StatusAccepted  = "ACCEPTED"
	StatusRejected  = "REJECTED"
	StatusSettled   = "SETTLED"
	StatusCancelled = "CANCELLED"
	// StatusReturned — v2.0: a settled payment returned by the receiver bank (terminal).
	StatusReturned = "RETURNED"
)

// SchemaVersionV2 is written by every v2.0 write. Objects without schemaVersion were written by
// v1.0 and are read as schema 1 (lazy migration — no bulk rewrite in Init).
const SchemaVersionV2 = 2

// Limits.
const (
	// MaxAmount in minor units (tiyn): 10^14 = 1 trillion KZT.
	// OWASP SC08:2025 — explicit upper bound keeps arithmetic far from int64 overflow.
	MaxAmount int64 = 100_000_000_000_000
	// MaxReferenceRunes — payment purpose text limit (ISO 20022 unstructured remittance is 140).
	MaxReferenceRunes = 140
	// MaxPageSize — OWASP SC10:2025 — upper bound for range queries.
	MaxPageSize = 50
)

// PaymentOrder is the public business object. JSON field names are frozen:
// version 2.0 must keep reading state written by 1.0 (world-state compatibility).
type PaymentOrder struct {
	DocType         string `json:"docType"`
	ID              string `json:"id"`
	SenderBankMSP   string `json:"senderBankMSP"`
	ReceiverBankMSP string `json:"receiverBankMSP"`
	Amount          int64  `json:"amount"`
	Currency        string `json:"currency"`
	PurposeCode     string `json:"purposeCode"`
	Reference       string `json:"reference"`
	Status          string `json:"status"`
	// metadata:",optional" — contractapi v2 validates return values against the generated JSON
	// schema and treats every field as required unless explicitly marked optional (omitempty is not enough).
	RejectReason  string `json:"rejectReason,omitempty" metadata:",optional"`
	CreatedByHash string `json:"createdByHash"`
	CreatedAt     string `json:"createdAt"`
	UpdatedAt     string `json:"updatedAt"`
	LastTxID      string `json:"lastTxId"`

	// --- v2.0 additions: only new optional fields, v1.0 fields are untouched (compat rules 2–3) ---
	SchemaVersion int    `json:"schemaVersion,omitempty" metadata:",optional"`
	ValueDate     string `json:"valueDate,omitempty" metadata:",optional"`
	ReturnReason  string `json:"returnReason,omitempty" metadata:",optional"`
	ReturnedAt    string `json:"returnedAt,omitempty" metadata:",optional"`
}

// EffectiveSchemaVersion — objects written by v1.0 carry no schemaVersion and are schema 1.
func (po *PaymentOrder) EffectiveSchemaVersion() int {
	if po.SchemaVersion == 0 {
		return 1
	}
	return po.SchemaVersion
}

// PaginatedResult is returned by GetAllPaymentOrders.
type PaginatedResult struct {
	Records             []*PaymentOrder `json:"records"`
	FetchedRecordsCount int32           `json:"fetchedRecordsCount"`
	Bookmark            string          `json:"bookmark"`
}

// HistoryRecord is one entry of GetPaymentOrderHistory.
type HistoryRecord struct {
	TxID      string        `json:"txId"`
	Timestamp string        `json:"timestamp"`
	IsDelete  bool          `json:"isDelete"`
	Value     *PaymentOrder `json:"value,omitempty" metadata:",optional"`
}

// allowedTransitions is the single source of truth for the state machine.
// A function (not a package-level map) keeps the table immutable and iteration-order free.
// OWASP SC03:2025 — logic errors: only the transitions listed here are possible;
// SETTLED, REJECTED and CANCELLED are terminal (no outgoing edges).
func allowedTransitions(from string) []string {
	switch from {
	case StatusCreated:
		return []string{StatusSubmitted, StatusCancelled}
	case StatusSubmitted:
		return []string{StatusAccepted, StatusRejected, StatusCancelled}
	case StatusAccepted:
		return []string{StatusSettled}
	case StatusSettled:
		// v2.0 adds one edge; RETURNED has no outgoing edges, so a payment is returned at most once.
		return []string{StatusReturned}
	default:
		return nil
	}
}

func canTransition(from, to string) bool {
	for _, s := range allowedTransitions(from) {
		if s == to {
			return true
		}
	}
	return false
}

// isBankMSP — whitelist of bank organisations that can be a counterparty.
func isBankMSP(msp string) bool {
	switch msp {
	case "Org1MSP", "Org2MSP":
		return true
	}
	return false
}
