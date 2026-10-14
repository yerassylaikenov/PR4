package chaincode

// DocTypePaymentOrder marks PaymentOrder documents in the world state.
const DocTypePaymentOrder = "PaymentOrder"

// SenderBankMSPID is the only organisation allowed to originate payment orders in variant 1.
const SenderBankMSPID = "Org1MSP"

// CollectionSettlement holds the confidential settlement details (members: Org1MSP only).
const CollectionSettlement = "collectionSettlementDetails"

// Transient map keys.
const (
	TransientSettlement = "settlement"
	TransientCandidate  = "candidate"
)

// Roles issued by Fabric CA as the "role" attribute of the enrollment certificate.
const (
	AttrRole      = "role"
	RoleInitiator = "initiator"
	RoleApprover  = "approver"
	RoleProcessor = "processor"
)

// Payment order statuses.
const (
	StatusCreated   = "CREATED"
	StatusSubmitted = "SUBMITTED"
	StatusAccepted  = "ACCEPTED"
	StatusRejected  = "REJECTED"
	StatusSettled   = "SETTLED"
	StatusCancelled = "CANCELLED"
)

// Limits.
const (
	// OWASP SC08:2025 — explicit upper bound in minor units (10^14 tiyn).
	MaxAmount         int64 = 100_000_000_000_000
	MaxReferenceRunes       = 140
	MaxNameRunes            = 140
	// OWASP SC10:2025 — bounded range queries and transient payload.
	MaxPageSize      = 50
	MaxTransientSize = 4096
)

// PaymentOrder — public state. Only hashes of identities and of the settlement details are stored.
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
	RejectReason    string `json:"rejectReason,omitempty" metadata:",optional"`
	CreatedByHash   string `json:"createdByHash"`
	ApprovedByHash  string `json:"approvedByHash,omitempty" metadata:",optional"`
	// SettlementHash — sha256 of the private settlement details frozen at Submit (INV-9);
	// lets the receiver bank verify a candidate without seeing the details.
	SettlementHash string `json:"settlementHash,omitempty" metadata:",optional"`
	CreatedAt      string `json:"createdAt"`
	UpdatedAt      string `json:"updatedAt"`
	LastTxID       string `json:"lastTxId"`
}

// SettlementDetails — confidential payload stored only in collectionSettlementDetails.
// Field order is fixed: json.Marshal of this struct is the canonical form that is hashed.
type SettlementDetails struct {
	PayerIBAN       string `json:"payerIBAN"`
	PayerBIN        string `json:"payerBIN"`
	BeneficiaryIBAN string `json:"beneficiaryIBAN"`
	BeneficiaryBIC  string `json:"beneficiaryBIC"`
	BeneficiaryName string `json:"beneficiaryName"`
	Salt            string `json:"salt"`
}

// SettlementView is returned by ReadSettlementDetails (the salt is never returned).
type SettlementView struct {
	ID              string `json:"id"`
	PayerIBAN       string `json:"payerIBAN"`
	PayerBIN        string `json:"payerBIN"`
	BeneficiaryIBAN string `json:"beneficiaryIBAN"`
	BeneficiaryBIC  string `json:"beneficiaryBIC"`
	BeneficiaryName string `json:"beneficiaryName"`
}

// VerifyResult is returned by VerifySettlementDetails.
type VerifyResult struct {
	ID    string `json:"id"`
	Match bool   `json:"match"`
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

// allowedTransitions — single source of truth for the state machine (OWASP SC03:2025).
func allowedTransitions(from string) []string {
	switch from {
	case StatusCreated:
		return []string{StatusSubmitted, StatusCancelled}
	case StatusSubmitted:
		return []string{StatusAccepted, StatusRejected, StatusCancelled}
	case StatusAccepted:
		return []string{StatusSettled}
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

func isBankMSP(msp string) bool {
	switch msp {
	case "Org1MSP", "Org2MSP":
		return true
	}
	return false
}
