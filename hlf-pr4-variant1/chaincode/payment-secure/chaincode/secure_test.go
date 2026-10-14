package chaincode_test

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
	"github.com/yaikenov/hlf-pr4-variant1/chaincode/paymentsecure/chaincode"
	"github.com/yaikenov/hlf-pr4-variant1/chaincode/paymentsecure/chaincode/mocks"
)

var sc = &chaincode.SmartContract{}

func mustJSON(v any) []byte { b, _ := json.Marshal(v); return b }

func errCode(t *testing.T, err error, code string) {
	t.Helper()
	require.Error(t, err)
	require.True(t, strings.HasPrefix(err.Error(), code), "want %s, got %v", code, err)
}

func create(t *testing.T, l *fakeLedger, id string) {
	t.Helper()
	_, err := sc.CreatePaymentOrder(l.by(initiator1), id, "Org2MSP", "5000000", "KZT", "119", "Invoice 42")
	must(t, err)
}

func setDetails(t *testing.T, l *fakeLedger, id string) {
	t.Helper()
	onPeer(t, "Org1MSP")
	must(t, sc.SetSettlementDetails(l.as(initiator1, map[string][]byte{"settlement": settlementJSON()}), id))
}

// driveTo creates a fully valid order and moves it to the requested status.
func driveTo(t *testing.T, l *fakeLedger, id, status string) {
	t.Helper()
	create(t, l, id)
	if status == chaincode.StatusCreated {
		return
	}
	if status == chaincode.StatusCancelled {
		_, err := sc.CancelPaymentOrder(l.by(initiator1), id)
		must(t, err)
		return
	}
	setDetails(t, l, id)
	_, err := sc.SubmitPaymentOrder(l.by(approver1), id)
	must(t, err)
	switch status {
	case chaincode.StatusAccepted, chaincode.StatusSettled:
		_, err = sc.AcceptPaymentOrder(l.by(processor2), id)
		must(t, err)
		if status == chaincode.StatusSettled {
			_, err = sc.SettlePaymentOrder(l.by(processor2), id)
			must(t, err)
		}
	case chaincode.StatusRejected:
		_, err = sc.RejectPaymentOrder(l.by(processor2), id, "ACCOUNT_CLOSED")
		must(t, err)
	}
}

func TestHappyPathWithPrivateData(t *testing.T) {
	l := newLedger()
	driveTo(t, l, "PO-S001", chaincode.StatusSettled)
	po, err := sc.ReadPaymentOrder(l.by(processor2), "PO-S001")
	must(t, err)
	require.Equal(t, chaincode.StatusSettled, po.Status)
	require.Len(t, po.ApprovedByHash, 64)
	require.Len(t, po.SettlementHash, 64)
	require.NotEqual(t, po.CreatedByHash, po.ApprovedByHash)
	pub, _ := json.Marshal(l.state)
	for _, secret := range []string{ibanPayer, ibanBenef, "999999000001", "SYNTHETIC", saltHex} {
		require.NotContains(t, string(pub), secret, "public state must not contain settlement details")
	}
	require.Contains(t, string(l.private["collectionSettlementDetails/PO-S001"]), ibanPayer)
}

// ---- Invariants -------------------------------------------------------------------------------

func TestINV1_UniqueID(t *testing.T) {
	l := newLedger()
	create(t, l, "PO-0001")
	_, err := sc.CreatePaymentOrder(l.by(initiator1), "PO-0001", "Org2MSP", "1", "KZT", "119", "dup")
	errCode(t, err, chaincode.ErrAlreadyExists)
}

func TestINV2_SenderIsCreatorOrg1(t *testing.T) {
	l := newLedger()
	for _, c := range []caller{initiator2, processor2, norole1, admin1, approver1} {
		_, err := sc.CreatePaymentOrder(l.by(c), "PO-0001", "Org2MSP", "1", "KZT", "119", "x")
		errCode(t, err, chaincode.ErrUnauthorized)
	}
	_, err := sc.CreatePaymentOrder(l.by(initiator1), "PO-0001", "Org1MSP", "1", "KZT", "119", "x")
	errCode(t, err, chaincode.ErrValidation)
	create(t, l, "PO-0001")
	po, _ := sc.ReadPaymentOrder(l.by(initiator1), "PO-0001")
	require.Equal(t, "Org1MSP", po.SenderBankMSP)
}

func TestINV3_ImmutableFields(t *testing.T) {
	l := newLedger()
	create(t, l, "PO-I001")
	before, _ := sc.ReadPaymentOrder(l.by(initiator1), "PO-I001")
	setDetails(t, l, "PO-I001")
	_, _ = sc.SubmitPaymentOrder(l.by(approver1), "PO-I001")
	_, _ = sc.AcceptPaymentOrder(l.by(processor2), "PO-I001")
	after, err := sc.SettlePaymentOrder(l.by(processor2), "PO-I001")
	must(t, err)
	require.Equal(t, before.Amount, after.Amount)
	require.Equal(t, before.Currency, after.Currency)
	require.Equal(t, before.SenderBankMSP, after.SenderBankMSP)
	require.Equal(t, before.ReceiverBankMSP, after.ReceiverBankMSP)
	require.Equal(t, before.CreatedByHash, after.CreatedByHash)
}

func TestINV4_SubmitOnlySenderApprover(t *testing.T) {
	l := newLedger()
	create(t, l, "PO-V001")
	setDetails(t, l, "PO-V001")
	// the exploit of paymentvuln: the receiver bank authorises the debit
	for _, c := range []caller{processor2, approver2} {
		_, err := sc.SubmitPaymentOrder(l.by(c), "PO-V001")
		errCode(t, err, chaincode.ErrUnauthorized)
	}
	for _, c := range []caller{norole1, admin1} {
		_, err := sc.SubmitPaymentOrder(l.by(c), "PO-V001")
		errCode(t, err, chaincode.ErrUnauthorized)
	}
	po, _ := sc.ReadPaymentOrder(l.by(initiator1), "PO-V001")
	require.Equal(t, chaincode.StatusCreated, po.Status)
	_, err := sc.SubmitPaymentOrder(l.by(approver1), "PO-V001")
	must(t, err)
}

func TestINV5_FourEyes(t *testing.T) {
	l := newLedger()
	create(t, l, "PO-F001")
	setDetails(t, l, "PO-F001")
	// initiator1 has no approver role
	_, err := sc.SubmitPaymentOrder(l.by(initiator1), "PO-F001")
	errCode(t, err, chaincode.ErrUnauthorized)
	// the same identity holding the approver role cannot approve its own order
	selfApprover := caller{"Org1MSP", initiator1.id, "approver"}
	_, err = sc.SubmitPaymentOrder(l.by(selfApprover), "PO-F001")
	errCode(t, err, chaincode.ErrUnauthorized)
	require.Contains(t, err.Error(), "four-eyes")
}

func TestINV6_ReceiverProcessorOnly(t *testing.T) {
	l := newLedger()
	driveTo(t, l, "PO-R001", chaincode.StatusSubmitted)
	for _, c := range []caller{approver1, initiator1, approver2, initiator2} {
		_, err := sc.AcceptPaymentOrder(l.by(c), "PO-R001")
		errCode(t, err, chaincode.ErrUnauthorized)
		_, err = sc.RejectPaymentOrder(l.by(c), "PO-R001", "ACCOUNT_CLOSED")
		errCode(t, err, chaincode.ErrUnauthorized)
	}
	driveTo(t, l, "PO-R002", chaincode.StatusAccepted)
	_, err := sc.SettlePaymentOrder(l.by(approver1), "PO-R002")
	errCode(t, err, chaincode.ErrUnauthorized)
	_, err = sc.SettlePaymentOrder(l.by(approver2), "PO-R002")
	errCode(t, err, chaincode.ErrUnauthorized)
}

func TestINV7_SettleOnceFromAccepted(t *testing.T) {
	l := newLedger()
	driveTo(t, l, "PO-X001", chaincode.StatusSubmitted)
	_, err := sc.SettlePaymentOrder(l.by(processor2), "PO-X001") // bypass ACCEPTED
	errCode(t, err, chaincode.ErrInvalidTransition)
	_, err = sc.AcceptPaymentOrder(l.by(processor2), "PO-X001")
	must(t, err)
	_, err = sc.SettlePaymentOrder(l.by(processor2), "PO-X001")
	must(t, err)
	_, err = sc.SettlePaymentOrder(l.by(processor2), "PO-X001") // replay
	errCode(t, err, chaincode.ErrInvalidTransition)
}

func TestINV8_TerminalStatuses(t *testing.T) {
	for _, st := range []string{chaincode.StatusSettled, chaincode.StatusRejected, chaincode.StatusCancelled} {
		l := newLedger()
		driveTo(t, l, "PO-T001", st)
		_, err := sc.CancelPaymentOrder(l.by(approver1), "PO-T001")
		errCode(t, err, chaincode.ErrInvalidTransition)
		_, err = sc.AcceptPaymentOrder(l.by(processor2), "PO-T001")
		errCode(t, err, chaincode.ErrInvalidTransition)
		_, err = sc.SettlePaymentOrder(l.by(processor2), "PO-T001")
		errCode(t, err, chaincode.ErrInvalidTransition)
		_, err = sc.RejectPaymentOrder(l.by(processor2), "PO-T001", "ACCOUNT_CLOSED")
		errCode(t, err, chaincode.ErrInvalidTransition)
		_, err = sc.SubmitPaymentOrder(l.by(approver1), "PO-T001")
		require.Error(t, err)
	}
}

func TestINV9_DetailsRequiredAndFrozen(t *testing.T) {
	l := newLedger()
	create(t, l, "PO-D001")
	_, err := sc.SubmitPaymentOrder(l.by(approver1), "PO-D001")
	errCode(t, err, chaincode.ErrValidation)
	require.Contains(t, err.Error(), "settlement details must be set")
	setDetails(t, l, "PO-D001")
	po, err := sc.SubmitPaymentOrder(l.by(approver1), "PO-D001")
	must(t, err)
	onPeer(t, "Org1MSP")
	err = sc.SetSettlementDetails(l.as(initiator1, map[string][]byte{"settlement": settlementJSON()}), "PO-D001")
	errCode(t, err, chaincode.ErrInvalidTransition)
	require.Equal(t, po.SettlementHash, func() string { p, _ := sc.ReadPaymentOrder(l.by(processor2), "PO-D001"); return p.SettlementHash }())
}

// ---- Private data & transient ----------------------------------------------------------------

func TestSetSettlementDetailsAuthorization(t *testing.T) {
	l := newLedger()
	create(t, l, "PO-P001")
	tm := map[string][]byte{"settlement": settlementJSON()}
	onPeer(t, "Org1MSP")
	for _, c := range []caller{approver1, norole1, processor2, initiator2} {
		errCode(t, sc.SetSettlementDetails(l.as(c, tm), "PO-P001"), chaincode.ErrUnauthorized)
	}
	// endorsement by a non-member peer is refused (data must never be processed outside Org1)
	onPeer(t, "Org2MSP")
	errCode(t, sc.SetSettlementDetails(l.as(initiator1, tm), "PO-P001"), chaincode.ErrUnauthorized)
	require.Empty(t, l.private)
	onPeer(t, "Org1MSP")
	errCode(t, sc.SetSettlementDetails(l.as(initiator1, tm), "PO-NONE"), chaincode.ErrNotFound)
	errCode(t, sc.SetSettlementDetails(l.as(initiator1, tm), "bad"), chaincode.ErrValidation)
}

func TestTransientValidation(t *testing.T) {
	l := newLedger()
	create(t, l, "PO-P002")
	onPeer(t, "Org1MSP")
	cases := map[string]map[string][]byte{
		"no transient":       nil,
		"wrong key":          {"details": settlementJSON()},
		"empty":              {"settlement": {}},
		"too large":          {"settlement": settlementJSON(), "pad": []byte(strings.Repeat("x", 4096))},
		"not json":           {"settlement": []byte("IBAN=KZ09")},
		"trailing data":      {"settlement": append(settlementJSON(), []byte(`{}`)...)},
		"unknown field":      {"settlement": settlementJSON(func(m map[string]any) { m["cvv"] = "123" })},
		"short salt":         {"settlement": settlementJSON(func(m map[string]any) { m["salt"] = "abcd" })},
		"uppercase salt":     {"settlement": settlementJSON(func(m map[string]any) { m["salt"] = strings.ToUpper(saltHex) })},
		"bad IBAN checksum":  {"settlement": settlementJSON(func(m map[string]any) { m["payerIBAN"] = "KZ10999TESTPAYER0001" })},
		"KZ IBAN length":     {"settlement": settlementJSON(func(m map[string]any) { m["beneficiaryIBAN"] = "KZ17999TESTBENEF00021" })},
		"lowercase IBAN":     {"settlement": settlementJSON(func(m map[string]any) { m["payerIBAN"] = strings.ToLower(ibanPayer) })},
		"BIN 11 digits":      {"settlement": settlementJSON(func(m map[string]any) { m["payerBIN"] = "99999900000" })},
		"BIN letters":        {"settlement": settlementJSON(func(m map[string]any) { m["payerBIN"] = "99999900000A" })},
		"BIC 9 chars":        {"settlement": settlementJSON(func(m map[string]any) { m["beneficiaryBIC"] = "TESTKZKAX" })},
		"name empty":         {"settlement": settlementJSON(func(m map[string]any) { m["beneficiaryName"] = "" })},
		"name control chars": {"settlement": settlementJSON(func(m map[string]any) { m["beneficiaryName"] = "A\u0007B" })},
		"name too long":      {"settlement": settlementJSON(func(m map[string]any) { m["beneficiaryName"] = strings.Repeat("Ж", 141) })},
	}
	for name, tm := range cases {
		t.Run(name, func(t *testing.T) {
			err := sc.SetSettlementDetails(l.as(initiator1, tm), "PO-P002")
			errCode(t, err, chaincode.ErrValidation)
			for _, v := range []string{ibanPayer, ibanBenef, "999999000001", saltHex} {
				require.NotContains(t, err.Error(), v, "errors must not echo settlement values")
			}
		})
	}
	require.Empty(t, l.private)
	// valid foreign IBAN + 8-char BIC are accepted
	must(t, sc.SetSettlementDetails(l.as(initiator1, map[string][]byte{"settlement": settlementJSON(func(m map[string]any) {
		m["beneficiaryIBAN"] = "DE89370400440532013000"
		m["beneficiaryBIC"] = "TESTKZKA"
	})}), "PO-P002"))
}

func TestReadSettlementDetailsAccess(t *testing.T) {
	l := newLedger()
	create(t, l, "PO-S001")
	setDetails(t, l, "PO-S001")
	onPeer(t, "Org1MSP")
	for _, c := range []caller{initiator1, approver1} {
		v, err := sc.ReadSettlementDetails(l.by(c), "PO-S001")
		must(t, err)
		require.Equal(t, ibanPayer, v.PayerIBAN)
		require.NotContains(t, string(mustJSON(v)), saltHex, "salt is never returned")
	}
	for _, c := range []caller{processor2, approver2, norole1, admin1} {
		_, err := sc.ReadSettlementDetails(l.by(c), "PO-S001")
		errCode(t, err, chaincode.ErrUnauthorized)
	}
	onPeer(t, "Org2MSP") // Org1 client on an Org2 peer: client org != peer org
	_, err := sc.ReadSettlementDetails(l.by(initiator1), "PO-S001")
	errCode(t, err, chaincode.ErrUnauthorized)
	onPeer(t, "Org1MSP")
	_, err = sc.ReadSettlementDetails(l.by(initiator1), "PO-NONE")
	errCode(t, err, chaincode.ErrNotFound)
	_, err = sc.ReadSettlementDetails(l.by(initiator1), "bad")
	errCode(t, err, chaincode.ErrValidation)
}

func TestVerifySettlementDetails(t *testing.T) {
	l := newLedger()
	create(t, l, "PO-S001")
	setDetails(t, l, "PO-S001")
	onPeer(t, "Org2MSP")
	r, err := sc.VerifySettlementDetails(l.as(processor2, map[string][]byte{"candidate": settlementJSON()}), "PO-S001")
	must(t, err)
	require.True(t, r.Match)
	wrong := settlementJSON(func(m map[string]any) { m["beneficiaryIBAN"] = "KZ60999TESTBENEF0004" })
	r, err = sc.VerifySettlementDetails(l.as(processor2, map[string][]byte{"candidate": wrong}), "PO-S001")
	must(t, err)
	require.False(t, r.Match)
	wrongSalt := settlementJSON(func(m map[string]any) { m["salt"] = strings.Repeat("0", 64) })
	r, err = sc.VerifySettlementDetails(l.as(processor2, map[string][]byte{"candidate": wrongSalt}), "PO-S001")
	must(t, err)
	require.False(t, r.Match, "without the salt the hash cannot be confirmed by guessing")
	_, err = sc.VerifySettlementDetails(l.as(processor2, nil), "PO-S001")
	errCode(t, err, chaincode.ErrValidation)
	_, err = sc.VerifySettlementDetails(l.as(processor2, map[string][]byte{"candidate": settlementJSON()}), "PO-NONE")
	errCode(t, err, chaincode.ErrNotFound)
	_, err = sc.VerifySettlementDetails(l.as(caller{"Org3MSP", "x", ""}, map[string][]byte{"candidate": settlementJSON()}), "PO-S001")
	errCode(t, err, chaincode.ErrUnauthorized)
	_, err = sc.VerifySettlementDetails(l.as(processor2, map[string][]byte{"candidate": settlementJSON()}), "bad")
	errCode(t, err, chaincode.ErrValidation)
	_, err = sc.VerifySettlementDetails(l.as(processor2, map[string][]byte{"candidate": []byte("{")}), "PO-S001")
	errCode(t, err, chaincode.ErrValidation)
}

// ---- Validation, pagination, history, internal errors -----------------------------------------

func TestCreateInputValidation(t *testing.T) {
	l := newLedger()
	bad := [][]string{
		{"po-1", "Org2MSP", "1", "KZT", "119", "x"},
		{"PO-0001", "Org9MSP", "1", "KZT", "119", "x"},
		{"PO-0001", "Org2MSP", "-1", "KZT", "119", "x"},
		{"PO-0001", "Org2MSP", "0", "KZT", "119", "x"},
		{"PO-0001", "Org2MSP", "1e3", "KZT", "119", "x"},
		{"PO-0001", "Org2MSP", "9223372036854775808", "KZT", "119", "x"},
		{"PO-0001", "Org2MSP", "100000000000001", "KZT", "119", "x"},
		{"PO-0001", "Org2MSP", "1", "XXX", "119", "x"},
		{"PO-0001", "Org2MSP", "1", "KZT", "11", "x"},
		{"PO-0001", "Org2MSP", "1", "KZT", "119", ""},
		{"PO-0001", "Org2MSP", "1", "KZT", "119", strings.Repeat("a", 141)},
		{"PO-0001", "Org2MSP", "1", "KZT", "119", "a\tb"},
		{"PO-0001", "Org2MSP", "1", "KZT", "119", "\xff"},
	}
	for _, a := range bad {
		_, err := sc.CreatePaymentOrder(l.by(initiator1), a[0], a[1], a[2], a[3], a[4], a[5])
		errCode(t, err, chaincode.ErrValidation)
	}
	require.Empty(t, l.state)
	_, err := sc.RejectPaymentOrder(l.by(processor2), "PO-0001", "bad reason")
	errCode(t, err, chaincode.ErrValidation)
}

func TestCancelPaths(t *testing.T) {
	l := newLedger()
	driveTo(t, l, "PO-C001", chaincode.StatusSubmitted)
	_, err := sc.CancelPaymentOrder(l.by(processor2), "PO-C001")
	errCode(t, err, chaincode.ErrUnauthorized)
	_, err = sc.CancelPaymentOrder(l.by(norole1), "PO-C001")
	errCode(t, err, chaincode.ErrUnauthorized)
	po, err := sc.CancelPaymentOrder(l.by(approver1), "PO-C001")
	must(t, err)
	require.Equal(t, chaincode.StatusCancelled, po.Status)
	_, err = sc.CancelPaymentOrder(l.by(approver1), "bad")
	errCode(t, err, chaincode.ErrValidation)
	_, err = sc.CancelPaymentOrder(l.by(approver1), "PO-NONE")
	errCode(t, err, chaincode.ErrNotFound)
	driveTo(t, l, "PO-C002", chaincode.StatusRejected)
	p, _ := sc.ReadPaymentOrder(l.by(processor2), "PO-C002")
	require.Equal(t, "ACCOUNT_CLOSED", p.RejectReason)
}

func TestPaginationAndHistory(t *testing.T) {
	l := newLedger()
	for _, id := range []string{"PO-0003", "PO-0001", "PO-0002"} {
		create(t, l, id)
	}
	l.state["PO-JUNK"] = []byte(`{"docType":"x"}`)
	for _, n := range []int32{0, -5, 51, 10000} {
		_, err := sc.GetAllPaymentOrders(l.by(processor2), n, "")
		errCode(t, err, chaincode.ErrValidation)
	}
	_, err := sc.GetAllPaymentOrders(l.by(processor2), 5, strings.Repeat("b", 65))
	errCode(t, err, chaincode.ErrValidation)
	p, err := sc.GetAllPaymentOrders(l.by(processor2), 2, "")
	must(t, err)
	require.Len(t, p.Records, 2)
	p, err = sc.GetAllPaymentOrders(l.by(processor2), 50, p.Bookmark)
	must(t, err)
	require.Len(t, p.Records, 1)
	h, err := sc.GetPaymentOrderHistory(l.by(processor2), "PO-0001")
	must(t, err)
	require.Len(t, h, 1)
	_, err = sc.GetPaymentOrderHistory(l.by(processor2), "x")
	errCode(t, err, chaincode.ErrValidation)
	ex, err := sc.PaymentOrderExists(l.by(processor2), "PO-0002")
	must(t, err)
	require.True(t, ex)
	_, err = sc.ReadPaymentOrder(l.by(processor2), "x")
	errCode(t, err, chaincode.ErrValidation)
	_, err = sc.SubmitPaymentOrder(l.by(approver1), "x")
	errCode(t, err, chaincode.ErrValidation)
	_, err = sc.AcceptPaymentOrder(l.by(processor2), "x")
	errCode(t, err, chaincode.ErrValidation)
	_, err = sc.AcceptPaymentOrder(l.by(processor2), "PO-NONE")
	errCode(t, err, chaincode.ErrNotFound)
	_, err = sc.SubmitPaymentOrder(l.by(approver1), "PO-NONE")
	errCode(t, err, chaincode.ErrNotFound)
}

func TestInternalErrors(t *testing.T) {
	stubOf := func(ctx *mocks.TransactionContext) *mocks.ChaincodeStub { return ctx.GetStub().(*mocks.ChaincodeStub) }
	ciOf := func(ctx *mocks.TransactionContext) *mocks.ClientIdentity {
		return ctx.GetClientIdentity().(*mocks.ClientIdentity)
	}

	l := newLedger()
	ctx := l.by(initiator1)
	ciOf(ctx).GetMSPIDReturns("", errors.New("x"))
	_, err := sc.CreatePaymentOrder(ctx, "PO-E001", "Org2MSP", "1", "KZT", "119", "x")
	errCode(t, err, chaincode.ErrInternal)

	ctx = l.by(initiator1)
	ciOf(ctx).GetIDReturns("", errors.New("x"))
	_, err = sc.CreatePaymentOrder(ctx, "PO-E001", "Org2MSP", "1", "KZT", "119", "x")
	errCode(t, err, chaincode.ErrInternal)

	ctx = l.by(initiator1)
	stubOf(ctx).GetTxTimestampReturns(nil, errors.New("x"))
	_, err = sc.CreatePaymentOrder(ctx, "PO-E001", "Org2MSP", "1", "KZT", "119", "x")
	errCode(t, err, chaincode.ErrInternal)

	ctx = l.by(initiator1)
	stubOf(ctx).GetStateStub = nil
	stubOf(ctx).GetStateReturns(nil, errors.New("x"))
	_, err = sc.CreatePaymentOrder(ctx, "PO-E001", "Org2MSP", "1", "KZT", "119", "x")
	errCode(t, err, chaincode.ErrInternal)
	_, err = sc.ReadPaymentOrder(ctx, "PO-E001")
	errCode(t, err, chaincode.ErrInternal)

	l.failPut = true
	_, err = sc.CreatePaymentOrder(l.by(initiator1), "PO-E001", "Org2MSP", "1", "KZT", "119", "x")
	errCode(t, err, chaincode.ErrInternal)
	l.failPut = false

	create(t, l, "PO-E002")
	onPeer(t, "Org1MSP")
	l.failPut = true
	errCode(t, sc.SetSettlementDetails(l.as(initiator1, map[string][]byte{"settlement": settlementJSON()}), "PO-E002"), chaincode.ErrInternal)
	l.failPut = false

	ctx = l.as(initiator1, nil)
	stubOf(ctx).GetTransientReturns(nil, errors.New("x"))
	errCode(t, sc.SetSettlementDetails(ctx, "PO-E002"), chaincode.ErrInternal)
	ctx = l.as(processor2, nil)
	stubOf(ctx).GetTransientReturns(nil, errors.New("x"))
	_, err = sc.VerifySettlementDetails(ctx, "PO-E002")
	errCode(t, err, chaincode.ErrInternal)

	setDetails(t, l, "PO-E002")
	ctx = l.by(approver1)
	stubOf(ctx).GetPrivateDataHashStub = nil
	stubOf(ctx).GetPrivateDataHashReturns(nil, errors.New("x"))
	_, err = sc.SubmitPaymentOrder(ctx, "PO-E002")
	errCode(t, err, chaincode.ErrInternal)
	ctx = l.as(processor2, map[string][]byte{"candidate": settlementJSON()})
	stubOf(ctx).GetPrivateDataHashStub = nil
	stubOf(ctx).GetPrivateDataHashReturns(nil, errors.New("x"))
	_, err = sc.VerifySettlementDetails(ctx, "PO-E002")
	errCode(t, err, chaincode.ErrInternal)

	ctx = l.by(initiator1)
	stubOf(ctx).GetPrivateDataStub = nil
	stubOf(ctx).GetPrivateDataReturns(nil, errors.New("peer: memberOnlyRead"))
	_, err = sc.ReadSettlementDetails(ctx, "PO-E002")
	errCode(t, err, chaincode.ErrUnauthorized)
	l.private["collectionSettlementDetails/PO-E002"] = []byte("{")
	_, err = sc.ReadSettlementDetails(l.by(initiator1), "PO-E002")
	errCode(t, err, chaincode.ErrInternal)

	ctx = l.by(processor2)
	stubOf(ctx).GetStateByRangeWithPaginationCalls(nil)
	stubOf(ctx).GetStateByRangeWithPaginationReturns(nil, nil, errors.New("x"))
	_, err = sc.GetAllPaymentOrders(ctx, 5, "")
	errCode(t, err, chaincode.ErrInternal)
	ctx = l.by(processor2)
	stubOf(ctx).GetHistoryForKeyCalls(nil)
	stubOf(ctx).GetHistoryForKeyReturns(nil, errors.New("x"))
	_, err = sc.GetPaymentOrderHistory(ctx, "PO-E002")
	errCode(t, err, chaincode.ErrInternal)

	l.state["PO-BAD1"] = []byte("{")
	_, err = sc.ReadPaymentOrder(l.by(processor2), "PO-BAD1")
	errCode(t, err, chaincode.ErrInternal)

	ctx = l.by(initiator1)
	stubOf(ctx).SetEventStub = nil
	stubOf(ctx).SetEventReturns(errors.New("x"))
	_, err = sc.CancelPaymentOrder(ctx, "PO-E002")
	errCode(t, err, chaincode.ErrInternal)

	t.Setenv("CORE_PEER_LOCALMSPID", "")
	errCode(t, sc.SetSettlementDetails(l.as(initiator1, map[string][]byte{"settlement": settlementJSON()}), "PO-E002"), chaincode.ErrInternal)
}
