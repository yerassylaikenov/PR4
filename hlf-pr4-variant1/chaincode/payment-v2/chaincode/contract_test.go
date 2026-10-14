package chaincode_test

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
	"github.com/yaikenov/hlf-pr4-variant1/chaincode/payment/chaincode"
	"github.com/yaikenov/hlf-pr4-variant1/chaincode/payment/chaincode/mocks"
)

var sc = &chaincode.SmartContract{}

func create(t *testing.T, l *fakeLedger, id string) *chaincode.PaymentOrder {
	t.Helper()
	po, err := sc.CreatePaymentOrder(l.org1(), id, "Org2MSP", "5000000", "KZT", "119", "Invoice 42 payment")
	must(t, err)
	return po
}

// driveTo moves a fresh order into the requested status through legal transitions.
func driveTo(t *testing.T, l *fakeLedger, id, status string) {
	t.Helper()
	create(t, l, id)
	var err error
	switch status {
	case chaincode.StatusCreated:
	case chaincode.StatusSubmitted:
		_, err = sc.SubmitPaymentOrder(l.org1(), id)
	case chaincode.StatusAccepted:
		_, err = sc.SubmitPaymentOrder(l.org1(), id)
		must(t, err)
		_, err = sc.AcceptPaymentOrder(l.org2(), id)
	case chaincode.StatusSettled:
		_, err = sc.SubmitPaymentOrder(l.org1(), id)
		must(t, err)
		_, err = sc.AcceptPaymentOrder(l.org2(), id)
		must(t, err)
		_, err = sc.SettlePaymentOrder(l.org2(), id)
	case chaincode.StatusRejected:
		_, err = sc.SubmitPaymentOrder(l.org1(), id)
		must(t, err)
		_, err = sc.RejectPaymentOrder(l.org2(), id, "ACCOUNT_CLOSED")
	case chaincode.StatusCancelled:
		_, err = sc.CancelPaymentOrder(l.org1(), id)
	}
	must(t, err)
}

func TestHappyPathFullLifecycle(t *testing.T) {
	l := newLedger()
	po := create(t, l, "PO-0001")
	require.Equal(t, chaincode.StatusCreated, po.Status)
	require.Equal(t, "Org1MSP", po.SenderBankMSP)
	require.Equal(t, int64(5000000), po.Amount)
	require.Len(t, po.CreatedByHash, 64)
	require.NotContains(t, po.CreatedByHash, "org1admin", "only the hash of the identity is stored")
	require.Equal(t, "2026-10-14T12:00:01Z", po.CreatedAt, "time comes from GetTxTimestamp")

	po, err := sc.SubmitPaymentOrder(l.org1(), "PO-0001")
	must(t, err)
	require.Equal(t, chaincode.StatusSubmitted, po.Status)
	po, err = sc.AcceptPaymentOrder(l.org2(), "PO-0001")
	must(t, err)
	require.Equal(t, chaincode.StatusAccepted, po.Status)
	po, err = sc.SettlePaymentOrder(l.org2(), "PO-0001")
	must(t, err)
	require.Equal(t, chaincode.StatusSettled, po.Status)
	require.Equal(t, "tx0004", po.LastTxID)

	require.Equal(t, []string{"PaymentOrderCreated", "PaymentOrderSubmitted", "PaymentOrderAccepted", "PaymentOrderSettled"}, l.events)

	read, err := sc.ReadPaymentOrder(l.org2(), "PO-0001")
	must(t, err)
	require.Equal(t, po, read)

	hist, err := sc.GetPaymentOrderHistory(l.org1(), "PO-0001")
	must(t, err)
	require.Len(t, hist, 4)
	require.Equal(t, []string{"tx0001", "tx0002", "tx0003", "tx0004"},
		[]string{hist[0].TxID, hist[1].TxID, hist[2].TxID, hist[3].TxID})
	require.Equal(t, chaincode.StatusSettled, hist[3].Value.Status)
}

func TestRejectAndCancelPaths(t *testing.T) {
	l := newLedger()
	driveTo(t, l, "PO-0002", chaincode.StatusRejected)
	po, err := sc.ReadPaymentOrder(l.org1(), "PO-0002")
	must(t, err)
	require.Equal(t, chaincode.StatusRejected, po.Status)
	require.Equal(t, "ACCOUNT_CLOSED", po.RejectReason)

	driveTo(t, l, "PO-0003", chaincode.StatusCancelled)
	driveTo(t, l, "PO-0004", chaincode.StatusSubmitted)
	po, err = sc.CancelPaymentOrder(l.org1(), "PO-0004")
	must(t, err)
	require.Equal(t, chaincode.StatusCancelled, po.Status)
}

func TestEveryInvalidTransitionIsRejected(t *testing.T) {
	type op struct {
		name string
		to   string
		call func(l *fakeLedger, id string) error
	}
	ops := []op{
		{"Submit", chaincode.StatusSubmitted, func(l *fakeLedger, id string) error { _, e := sc.SubmitPaymentOrder(l.org1(), id); return e }},
		{"Accept", chaincode.StatusAccepted, func(l *fakeLedger, id string) error { _, e := sc.AcceptPaymentOrder(l.org2(), id); return e }},
		{"Reject", chaincode.StatusRejected, func(l *fakeLedger, id string) error {
			_, e := sc.RejectPaymentOrder(l.org2(), id, "ACCOUNT_CLOSED")
			return e
		}},
		{"Settle", chaincode.StatusSettled, func(l *fakeLedger, id string) error { _, e := sc.SettlePaymentOrder(l.org2(), id); return e }},
		{"Cancel", chaincode.StatusCancelled, func(l *fakeLedger, id string) error { _, e := sc.CancelPaymentOrder(l.org1(), id); return e }},
	}
	allowed := map[string][]string{
		chaincode.StatusCreated:   {chaincode.StatusSubmitted, chaincode.StatusCancelled},
		chaincode.StatusSubmitted: {chaincode.StatusAccepted, chaincode.StatusRejected, chaincode.StatusCancelled},
		chaincode.StatusAccepted:  {chaincode.StatusSettled},
		chaincode.StatusSettled:   {},
		chaincode.StatusRejected:  {},
		chaincode.StatusCancelled: {},
	}
	n := 0
	for _, from := range []string{chaincode.StatusCreated, chaincode.StatusSubmitted, chaincode.StatusAccepted,
		chaincode.StatusSettled, chaincode.StatusRejected, chaincode.StatusCancelled} {
		for _, o := range ops {
			isAllowed := false
			for _, a := range allowed[from] {
				if a == o.to {
					isAllowed = true
				}
			}
			if isAllowed {
				continue
			}
			n++
			t.Run(from+"_"+o.name, func(t *testing.T) {
				l := newLedger()
				driveTo(t, l, "PO-T001", from)
				err := o.call(l, "PO-T001")
				require.Error(t, err)
				require.True(t, strings.HasPrefix(err.Error(), chaincode.ErrInvalidTransition), err.Error())
			})
		}
	}
	require.Equal(t, 24, n, "6 statuses x 5 operations minus 6 legal edges")
}

func TestForeignMSPIsUnauthorized(t *testing.T) {
	l := newLedger()
	driveTo(t, l, "PO-A001", chaincode.StatusCreated)
	driveTo(t, l, "PO-A002", chaincode.StatusSubmitted)
	driveTo(t, l, "PO-A003", chaincode.StatusAccepted)

	cases := []struct {
		name string
		call func() error
	}{
		{"Create by Org2", func() error {
			_, e := sc.CreatePaymentOrder(l.org2(), "PO-0004", "Org1MSP", "100", "KZT", "119", "x")
			return e
		}},
		{"Submit by Org2", func() error { _, e := sc.SubmitPaymentOrder(l.org2(), "PO-A001"); return e }},
		{"Cancel by Org2", func() error { _, e := sc.CancelPaymentOrder(l.org2(), "PO-A001"); return e }},
		{"Accept by Org1", func() error { _, e := sc.AcceptPaymentOrder(l.org1(), "PO-A002"); return e }},
		{"Reject by Org1", func() error { _, e := sc.RejectPaymentOrder(l.org1(), "PO-A002", "ACCOUNT_CLOSED"); return e }},
		{"Settle by Org1", func() error { _, e := sc.SettlePaymentOrder(l.org1(), "PO-A003"); return e }},
		{"Unknown Org3", func() error { _, e := sc.SubmitPaymentOrder(l.as("Org3MSP", "x509::CN=x"), "PO-A001"); return e }},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			err := c.call()
			require.Error(t, err)
			require.True(t, strings.HasPrefix(err.Error(), chaincode.ErrUnauthorized), err.Error())
			require.NotContains(t, err.Error(), "Org1MSP", "error must not reveal the required MSP")
		})
	}
	po, err := sc.ReadPaymentOrder(l.org1(), "PO-A001")
	must(t, err)
	require.Equal(t, chaincode.StatusCreated, po.Status, "state unchanged after rejected calls")
}

func TestCreateInputValidation(t *testing.T) {
	type args struct{ id, recv, amount, cur, knp, ref string }
	ok := args{"PO-0001", "Org2MSP", "5000000", "KZT", "119", "Invoice"}
	mut := func(f func(a *args)) args { a := ok; f(&a); return a }
	cases := map[string]args{
		"empty id":            mut(func(a *args) { a.id = "" }),
		"lowercase id":        mut(func(a *args) { a.id = "po-0001" }),
		"short id":            mut(func(a *args) { a.id = "PO-1" }),
		"selector chars id":   mut(func(a *args) { a.id = `PO-{"$gt":""}` }),
		"spaces id":           mut(func(a *args) { a.id = " PO-0001" }),
		"receiver = sender":   mut(func(a *args) { a.recv = "Org1MSP" }),
		"unknown receiver":    mut(func(a *args) { a.recv = "Org9MSP" }),
		"empty amount":        mut(func(a *args) { a.amount = "" }),
		"spaces amount":       mut(func(a *args) { a.amount = " 100" }),
		"negative amount":     mut(func(a *args) { a.amount = "-1" }),
		"zero amount":         mut(func(a *args) { a.amount = "0" }),
		"exponent amount":     mut(func(a *args) { a.amount = "1e3" }),
		"plus sign amount":    mut(func(a *args) { a.amount = "+5" }),
		"float amount":        mut(func(a *args) { a.amount = "10.50" }),
		"int64 overflow":      mut(func(a *args) { a.amount = "9223372036854775808" }),
		"above MaxAmount":     mut(func(a *args) { a.amount = "100000000000001" }),
		"leading zero amount": mut(func(a *args) { a.amount = "0100" }),
		"unknown currency":    mut(func(a *args) { a.cur = "XXX" }),
		"lowercase currency":  mut(func(a *args) { a.cur = "kzt" }),
		"knp letters":         mut(func(a *args) { a.knp = "1A9" }),
		"knp 4 digits":        mut(func(a *args) { a.knp = "1190" }),
		"empty reference":     mut(func(a *args) { a.ref = "" }),
		"long reference":      mut(func(a *args) { a.ref = strings.Repeat("я", 141) }),
		"control chars":       mut(func(a *args) { a.ref = "pay\x00ment" }),
		"newline":             mut(func(a *args) { a.ref = "line1\nline2" }),
		"invalid utf8":        mut(func(a *args) { a.ref = "\xff\xfe" }),
	}
	for name, a := range cases {
		t.Run(name, func(t *testing.T) {
			l := newLedger()
			_, err := sc.CreatePaymentOrder(l.org1(), a.id, a.recv, a.amount, a.cur, a.knp, a.ref)
			require.Error(t, err)
			require.True(t, strings.HasPrefix(err.Error(), chaincode.ErrValidation), err.Error())
			require.Empty(t, l.state, "nothing written on validation failure")
		})
	}
	// boundary values that must pass
	l := newLedger()
	_, err := sc.CreatePaymentOrder(l.org1(), "PO-MAX1", "Org2MSP", "100000000000000", "USD", "000", strings.Repeat("я", 140))
	must(t, err)
	_, err = sc.CreatePaymentOrder(l.org1(), "PO-MIN1", "Org2MSP", "1", "CNY", "999", "Оплата по договору №7")
	must(t, err)
}

func TestDuplicateIDRejected(t *testing.T) {
	l := newLedger()
	create(t, l, "PO-0001")
	_, err := sc.CreatePaymentOrder(l.org1(), "PO-0001", "Org2MSP", "1", "KZT", "119", "dup")
	require.Error(t, err)
	require.True(t, strings.HasPrefix(err.Error(), chaincode.ErrAlreadyExists))
	po, _ := sc.ReadPaymentOrder(l.org1(), "PO-0001")
	require.Equal(t, int64(5000000), po.Amount, "original order is not overwritten")
}

func TestRejectReasonValidation(t *testing.T) {
	l := newLedger()
	driveTo(t, l, "PO-R001", chaincode.StatusSubmitted)
	for _, r := range []string{"", "a", "closed account", strings.Repeat("A", 33), "X;DROP"} {
		_, err := sc.RejectPaymentOrder(l.org2(), "PO-R001", r)
		require.Error(t, err, r)
		require.True(t, strings.HasPrefix(err.Error(), chaincode.ErrValidation))
	}
}

func TestNotFoundAndExists(t *testing.T) {
	l := newLedger()
	_, err := sc.ReadPaymentOrder(l.org1(), "PO-NONE")
	require.True(t, strings.HasPrefix(err.Error(), chaincode.ErrNotFound))
	_, err = sc.SettlePaymentOrder(l.org2(), "PO-NONE")
	require.True(t, strings.HasPrefix(err.Error(), chaincode.ErrNotFound))
	ex, err := sc.PaymentOrderExists(l.org1(), "PO-NONE")
	must(t, err)
	require.False(t, ex)
	create(t, l, "PO-0001")
	ex, err = sc.PaymentOrderExists(l.org2(), "PO-0001")
	must(t, err)
	require.True(t, ex)
	_, err = sc.PaymentOrderExists(l.org1(), "bad")
	require.Error(t, err)
	_, err = sc.ReadPaymentOrder(l.org1(), "bad")
	require.Error(t, err)
	_, err = sc.GetPaymentOrderHistory(l.org1(), "bad")
	require.Error(t, err)
	_, err = sc.SubmitPaymentOrder(l.org1(), "bad")
	require.Error(t, err)
}

func TestImmutableFieldsAcrossLifecycle(t *testing.T) {
	l := newLedger()
	before := create(t, l, "PO-I001")
	driveTo(t, l, "PO-I002", chaincode.StatusSettled)
	_, _ = sc.SubmitPaymentOrder(l.org1(), "PO-I001")
	_, _ = sc.AcceptPaymentOrder(l.org2(), "PO-I001")
	after, _ := sc.SettlePaymentOrder(l.org2(), "PO-I001")
	require.Equal(t, before.Amount, after.Amount)
	require.Equal(t, before.Currency, after.Currency)
	require.Equal(t, before.SenderBankMSP, after.SenderBankMSP)
	require.Equal(t, before.ReceiverBankMSP, after.ReceiverBankMSP)
	require.Equal(t, before.CreatedAt, after.CreatedAt)
	require.Equal(t, before.CreatedByHash, after.CreatedByHash)
}

func TestSettleExactlyOnce(t *testing.T) {
	l := newLedger()
	driveTo(t, l, "PO-S001", chaincode.StatusSettled)
	_, err := sc.SettlePaymentOrder(l.org2(), "PO-S001")
	require.True(t, strings.HasPrefix(err.Error(), chaincode.ErrInvalidTransition))
}

func TestGetAllPaymentOrdersPagination(t *testing.T) {
	l := newLedger()
	for _, id := range []string{"PO-0003", "PO-0001", "PO-0002"} {
		create(t, l, id)
	}
	l.state["OTHER-KEY"] = []byte(`{"docType":"Other"}`)
	l.state["PO-JUNK"] = []byte(`{"docType":"Other"}`)

	for _, bad := range []int32{0, -1, 51, 10000} {
		_, err := sc.GetAllPaymentOrders(l.org1(), bad, "")
		require.Error(t, err, bad)
		require.True(t, strings.HasPrefix(err.Error(), chaincode.ErrValidation))
	}
	_, err := sc.GetAllPaymentOrders(l.org1(), 10, strings.Repeat("B", 65))
	require.Error(t, err)

	p1, err := sc.GetAllPaymentOrders(l.org1(), 2, "")
	must(t, err)
	require.Len(t, p1.Records, 2)
	require.Equal(t, "PO-0001", p1.Records[0].ID)
	require.Equal(t, "PO-0003", p1.Bookmark)
	p2, err := sc.GetAllPaymentOrders(l.org2(), 2, p1.Bookmark)
	must(t, err)
	require.Len(t, p2.Records, 1, "PO-JUNK is skipped (wrong docType); OTHER-KEY is outside range")
	require.Equal(t, "PO-0003", p2.Records[0].ID)
	require.Equal(t, "", p2.Bookmark)

	empty, err := sc.GetAllPaymentOrders(newLedger().org1(), 50, "")
	must(t, err)
	b, _ := json.Marshal(empty)
	require.Contains(t, string(b), `"records":[]`)
}

func TestInternalFailuresAreWrapped(t *testing.T) {
	l := newLedger()
	l.failPut = true
	_, err := sc.CreatePaymentOrder(l.org1(), "PO-E001", "Org2MSP", "1", "KZT", "119", "x")
	require.True(t, strings.HasPrefix(err.Error(), chaincode.ErrInternal))

	l = newLedger()
	ctx := l.org1()
	ctx.GetStub().(*mocks.ChaincodeStub).GetStateReturns(nil, errors.New("couch down"))
	ctx.GetStub().(*mocks.ChaincodeStub).GetStateStub = nil
	_, err = sc.ReadPaymentOrder(ctx, "PO-E001")
	require.True(t, strings.HasPrefix(err.Error(), chaincode.ErrInternal))
	require.NotContains(t, err.Error(), "couch down", "internal details are not leaked")
	_, err = sc.PaymentOrderExists(ctx, "PO-E001")
	require.True(t, strings.HasPrefix(err.Error(), chaincode.ErrInternal))

	l = newLedger()
	ctx = l.org1()
	ctx.GetClientIdentity().(*mocks.ClientIdentity).GetMSPIDReturns("", errors.New("no cert"))
	_, err = sc.CreatePaymentOrder(ctx, "PO-E001", "Org2MSP", "1", "KZT", "119", "x")
	require.True(t, strings.HasPrefix(err.Error(), chaincode.ErrInternal))

	l = newLedger()
	create(t, l, "PO-E002")
	ctx = l.org1()
	ctx.GetClientIdentity().(*mocks.ClientIdentity).GetMSPIDReturns("", errors.New("no cert"))
	_, err = sc.SubmitPaymentOrder(ctx, "PO-E002")
	require.True(t, strings.HasPrefix(err.Error(), chaincode.ErrInternal))

	l = newLedger()
	ctx = l.org1()
	ctx.GetClientIdentity().(*mocks.ClientIdentity).GetIDReturns("", errors.New("no id"))
	_, err = sc.CreatePaymentOrder(ctx, "PO-E003", "Org2MSP", "1", "KZT", "119", "x")
	require.True(t, strings.HasPrefix(err.Error(), chaincode.ErrInternal))

	l = newLedger()
	ctx = l.org1()
	ctx.GetStub().(*mocks.ChaincodeStub).GetTxTimestampReturns(nil, errors.New("no ts"))
	_, err = sc.CreatePaymentOrder(ctx, "PO-E004", "Org2MSP", "1", "KZT", "119", "x")
	require.True(t, strings.HasPrefix(err.Error(), chaincode.ErrInternal))

	l = newLedger()
	create(t, l, "PO-E005")
	ctx = l.org1()
	ctx.GetStub().(*mocks.ChaincodeStub).GetTxTimestampReturns(nil, errors.New("no ts"))
	_, err = sc.SubmitPaymentOrder(ctx, "PO-E005")
	require.True(t, strings.HasPrefix(err.Error(), chaincode.ErrInternal))

	l = newLedger()
	create(t, l, "PO-E006")
	ctx = l.org1()
	ctx.GetStub().(*mocks.ChaincodeStub).SetEventStub = nil
	ctx.GetStub().(*mocks.ChaincodeStub).SetEventReturns(errors.New("event"))
	_, err = sc.SubmitPaymentOrder(ctx, "PO-E006")
	require.True(t, strings.HasPrefix(err.Error(), chaincode.ErrInternal))
	// the fake ledger already applied the write above (a real peer would discard the whole tx)
	l.failPut = true
	_, err = sc.CancelPaymentOrder(l.org1(), "PO-E006")
	require.True(t, strings.HasPrefix(err.Error(), chaincode.ErrInternal))

	l = newLedger()
	l.state["PO-BAD1"] = []byte("{not json")
	_, err = sc.ReadPaymentOrder(l.org1(), "PO-BAD1")
	require.True(t, strings.HasPrefix(err.Error(), chaincode.ErrInternal))

	l = newLedger()
	ctx = l.org1()
	ctx.GetStub().(*mocks.ChaincodeStub).GetStateByRangeWithPaginationCalls(nil)
	ctx.GetStub().(*mocks.ChaincodeStub).GetStateByRangeWithPaginationReturns(nil, nil, errors.New("range"))
	_, err = sc.GetAllPaymentOrders(ctx, 10, "")
	require.True(t, strings.HasPrefix(err.Error(), chaincode.ErrInternal))

	l = newLedger()
	ctx = l.org1()
	ctx.GetStub().(*mocks.ChaincodeStub).GetHistoryForKeyCalls(nil)
	ctx.GetStub().(*mocks.ChaincodeStub).GetHistoryForKeyReturns(nil, errors.New("hist"))
	_, err = sc.GetPaymentOrderHistory(ctx, "PO-0001")
	require.True(t, strings.HasPrefix(err.Error(), chaincode.ErrInternal))
}
