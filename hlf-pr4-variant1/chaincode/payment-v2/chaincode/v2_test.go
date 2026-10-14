package chaincode_test

import (
	"encoding/json"
	"errors"
	"os"
	"sort"
	"strings"
	"testing"

	"github.com/hyperledger/fabric-chaincode-go/v2/shim"
	"github.com/hyperledger/fabric-protos-go-apiv2/ledger/queryresult"
	"github.com/hyperledger/fabric-protos-go-apiv2/peer"
	"github.com/stretchr/testify/require"
	"github.com/yaikenov/hlf-pr4-variant1/chaincode/payment/chaincode"
	"github.com/yaikenov/hlf-pr4-variant1/chaincode/payment/chaincode/mocks"
)

// loadGolden puts the REAL JSON returned by payment v1.0 on the network (testdata/v1_*.json, saved by
// scripts/30_pre_upgrade_snapshot.sh) into the fake world state, byte for byte.
func loadGolden(t *testing.T, l *fakeLedger, id string) []byte {
	t.Helper()
	b, err := os.ReadFile("testdata/v1_" + id + ".json")
	require.NoError(t, err)
	b = []byte(strings.TrimSpace(string(b)))
	l.state[id] = b
	return b
}

func TestGoldenV1ObjectsAreReadUnchanged(t *testing.T) {
	l := newLedger()
	for _, id := range []string{"PO-0001", "PO-0003"} {
		raw := loadGolden(t, l, id)
		require.NotContains(t, string(raw), "schemaVersion", "fixture was written by v1.0")
		po, err := sc.ReadPaymentOrder(l.org2(), id)
		must(t, err)
		require.Equal(t, 0, po.SchemaVersion)
		require.Equal(t, 1, po.EffectiveSchemaVersion(), "absent schemaVersion is read as schema 1")
		out, _ := json.Marshal(po)
		require.JSONEq(t, string(raw), string(out), "v2.0 returns exactly the v1.0 document (compat rules 1–3)")
	}
}

func TestLazyMigrationOnFirstWrite(t *testing.T) {
	l := newLedger()
	raw := loadGolden(t, l, "PO-0003") // CREATED in v1.0
	var v1 map[string]any
	require.NoError(t, json.Unmarshal(raw, &v1))

	_, err := sc.SubmitPaymentOrder(l.org1(), "PO-0003") // old operation through v2.0
	must(t, err)
	var v2 map[string]any
	require.NoError(t, json.Unmarshal(l.state["PO-0003"], &v2))
	require.EqualValues(t, 2, v2["schemaVersion"], "first v2.0 write stamps schemaVersion 2")
	for _, k := range []string{"docType", "id", "senderBankMSP", "receiverBankMSP", "amount", "currency",
		"purposeCode", "reference", "createdByHash", "createdAt"} {
		require.Equal(t, v1[k], v2[k], "v1.0 field %s preserved with the same name and type", k)
	}
	require.Equal(t, "SUBMITTED", v2["status"])
	_, err = sc.AcceptPaymentOrder(l.org2(), "PO-0003")
	must(t, err)
	po, err := sc.SettlePaymentOrder(l.org2(), "PO-0003")
	must(t, err)
	require.Equal(t, chaincode.StatusSettled, po.Status)
}

func TestReturnPaymentOrder(t *testing.T) {
	l := newLedger()
	loadGolden(t, l, "PO-0001") // SETTLED by v1.0
	_, err := sc.ReturnPaymentOrder(l.org1(), "PO-0001", "ACCOUNT_CLOSED")
	require.True(t, strings.HasPrefix(err.Error(), chaincode.ErrUnauthorized), "only the receiver bank (SC01)")
	_, err = sc.ReturnPaymentOrder(l.org2(), "PO-0001", "closed account")
	require.True(t, strings.HasPrefix(err.Error(), chaincode.ErrValidation))
	_, err = sc.ReturnPaymentOrder(l.org2(), "bad", "ACCOUNT_CLOSED")
	require.True(t, strings.HasPrefix(err.Error(), chaincode.ErrValidation))
	_, err = sc.ReturnPaymentOrder(l.org2(), "PO-NONE", "ACCOUNT_CLOSED")
	require.True(t, strings.HasPrefix(err.Error(), chaincode.ErrNotFound))

	po, err := sc.ReturnPaymentOrder(l.org2(), "PO-0001", "ACCOUNT_CLOSED")
	must(t, err)
	require.Equal(t, chaincode.StatusReturned, po.Status)
	require.Equal(t, "ACCOUNT_CLOSED", po.ReturnReason)
	require.NotEmpty(t, po.ReturnedAt)
	require.Equal(t, 2, po.SchemaVersion)
	require.Equal(t, int64(5000000), po.Amount, "amount unchanged by the return")
	require.Contains(t, l.events, "PaymentOrderReturned")

	_, err = sc.ReturnPaymentOrder(l.org2(), "PO-0001", "ACCOUNT_CLOSED") // second return
	require.True(t, strings.HasPrefix(err.Error(), chaincode.ErrInvalidTransition))
	_, err = sc.SettlePaymentOrder(l.org2(), "PO-0001") // RETURNED is terminal
	require.True(t, strings.HasPrefix(err.Error(), chaincode.ErrInvalidTransition))

	// Return is not a shortcut around SETTLED (SC03)
	for _, st := range []string{chaincode.StatusCreated, chaincode.StatusSubmitted, chaincode.StatusAccepted,
		chaincode.StatusRejected, chaincode.StatusCancelled} {
		l2 := newLedger()
		driveTo(t, l2, "PO-R001", st)
		_, err := sc.ReturnPaymentOrder(l2.org2(), "PO-R001", "ACCOUNT_CLOSED")
		require.True(t, strings.HasPrefix(err.Error(), chaincode.ErrInvalidTransition), st)
	}
}

func TestSetValueDate(t *testing.T) {
	l := newLedger()
	create(t, l, "PO-D001") // createdAt 2026-10-14
	for _, bad := range []string{"", "2026-13-01", "2026-02-30", "14.10.2026", "2026-10-14T00:00:00Z", "2026-10-13"} {
		_, err := sc.SetValueDate(l.org1(), "PO-D001", bad)
		require.Error(t, err, bad)
		require.True(t, strings.HasPrefix(err.Error(), chaincode.ErrValidation), bad)
	}
	_, err := sc.SetValueDate(l.org2(), "PO-D001", "2026-10-20")
	require.True(t, strings.HasPrefix(err.Error(), chaincode.ErrUnauthorized))
	_, err = sc.SetValueDate(l.org1(), "bad", "2026-10-20")
	require.Error(t, err)
	_, err = sc.SetValueDate(l.org1(), "PO-NONE", "2026-10-20")
	require.True(t, strings.HasPrefix(err.Error(), chaincode.ErrNotFound))
	po, err := sc.SetValueDate(l.org1(), "PO-D001", "2026-10-20")
	must(t, err)
	require.Equal(t, "2026-10-20", po.ValueDate)
	_, err = sc.SubmitPaymentOrder(l.org1(), "PO-D001")
	must(t, err)
	_, err = sc.SetValueDate(l.org1(), "PO-D001", "2026-10-21")
	require.True(t, strings.HasPrefix(err.Error(), chaincode.ErrInvalidTransition))
}

// wireRichQuery emulates CouchDB selector evaluation for {"docType","status"} on the fake ledger.
func wireRichQuery(l *fakeLedger, ctx *mocks.TransactionContext, seen *string) {
	ctx.GetStub().(*mocks.ChaincodeStub).GetQueryResultWithPaginationCalls(func(q string, size int32, bm string) (
		shim.StateQueryIteratorInterface, *peer.QueryResponseMetadata, error) {
		*seen = q
		var parsed struct {
			Selector map[string]string `json:"selector"`
		}
		if err := json.Unmarshal([]byte(q), &parsed); err != nil {
			return nil, nil, err
		}
		keys := []string{}
		for k, v := range l.state {
			var po chaincode.PaymentOrder
			if json.Unmarshal(v, &po) == nil && po.DocType == parsed.Selector["docType"] && po.Status == parsed.Selector["status"] && k > bm {
				keys = append(keys, k)
			}
		}
		sort.Strings(keys)
		next := ""
		if len(keys) > int(size) {
			keys = keys[:size]
			next = keys[size-1]
		}
		i := 0
		it := &mocks.StateQueryIterator{}
		it.HasNextCalls(func() bool { return i < len(keys) })
		it.NextCalls(func() (*queryresult.KV, error) {
			i++
			return &queryresult.KV{Key: keys[i-1], Value: l.state[keys[i-1]]}, nil
		})
		return it, &peer.QueryResponseMetadata{FetchedRecordsCount: int32(len(keys)), Bookmark: next}, nil
	})
}

func TestGetPaymentOrdersByStatus(t *testing.T) {
	l := newLedger()
	loadGolden(t, l, "PO-0001")
	loadGolden(t, l, "PO-0003")
	driveTo(t, l, "PO-0006", chaincode.StatusSettled)
	var q string
	ctx := l.org2()
	wireRichQuery(l, ctx, &q)
	res, err := sc.GetPaymentOrdersByStatus(ctx, "SETTLED", 10, "")
	must(t, err)
	ids := []string{}
	for _, r := range res.Records {
		ids = append(ids, r.ID)
	}
	require.Equal(t, []string{"PO-0001", "PO-0006"}, ids, "v1.0 and v2.0 objects are both found")
	require.JSONEq(t, `{"selector":{"docType":"PaymentOrder","status":"SETTLED"},"use_index":["_design/indexStatusDoc","indexStatus"]}`, q)

	ctx = l.org2()
	wireRichQuery(l, ctx, &q)
	p1, err := sc.GetPaymentOrdersByStatus(ctx, "SETTLED", 1, "")
	must(t, err)
	require.Len(t, p1.Records, 1)
	require.Equal(t, "PO-0001", p1.Bookmark)

	for _, bad := range []string{"", "settled", `SETTLED","$gt":"`, `{"$gt":null}`, "UNKNOWN"} {
		_, err := sc.GetPaymentOrdersByStatus(l.org2(), bad, 10, "")
		require.True(t, strings.HasPrefix(err.Error(), chaincode.ErrValidation), "selector injection blocked: %q", bad)
	}
	for _, n := range []int32{0, 51, 10000} {
		_, err := sc.GetPaymentOrdersByStatus(l.org2(), "SETTLED", n, "")
		require.True(t, strings.HasPrefix(err.Error(), chaincode.ErrValidation))
	}
	_, err = sc.GetPaymentOrdersByStatus(l.org2(), "SETTLED", 10, strings.Repeat("b", 257))
	require.Error(t, err)
	ctx = l.org2()
	ctx.GetStub().(*mocks.ChaincodeStub).GetQueryResultWithPaginationReturns(nil, nil, errors.New("couch"))
	_, err = sc.GetPaymentOrdersByStatus(ctx, "SETTLED", 10, "")
	require.True(t, strings.HasPrefix(err.Error(), chaincode.ErrInternal))
}

func TestV2InternalErrors(t *testing.T) {
	l := newLedger()
	loadGolden(t, l, "PO-0001")
	ctx := l.org2()
	ctx.GetClientIdentity().(*mocks.ClientIdentity).GetMSPIDReturns("", errors.New("x"))
	_, err := sc.ReturnPaymentOrder(ctx, "PO-0001", "ACCOUNT_CLOSED")
	require.True(t, strings.HasPrefix(err.Error(), chaincode.ErrInternal))
	ctx = l.org2()
	ctx.GetStub().(*mocks.ChaincodeStub).GetTxTimestampReturns(nil, errors.New("x"))
	_, err = sc.ReturnPaymentOrder(ctx, "PO-0001", "ACCOUNT_CLOSED")
	require.True(t, strings.HasPrefix(err.Error(), chaincode.ErrInternal))
	ctx = l.org2()
	ctx.GetStub().(*mocks.ChaincodeStub).SetEventStub = nil
	ctx.GetStub().(*mocks.ChaincodeStub).SetEventReturns(errors.New("x"))
	_, err = sc.ReturnPaymentOrder(ctx, "PO-0001", "ACCOUNT_CLOSED")
	require.True(t, strings.HasPrefix(err.Error(), chaincode.ErrInternal))
	loadGolden(t, l, "PO-0001") // the fake already applied the write above; restore SETTLED
	l.failPut = true
	_, err = sc.ReturnPaymentOrder(l.org2(), "PO-0001", "ACCOUNT_CLOSED")
	require.True(t, strings.HasPrefix(err.Error(), chaincode.ErrInternal))
	l.failPut = false

	create(t, l, "PO-D002")
	ctx = l.org1()
	ctx.GetClientIdentity().(*mocks.ClientIdentity).GetMSPIDReturns("", errors.New("x"))
	_, err = sc.SetValueDate(ctx, "PO-D002", "2026-10-20")
	require.True(t, strings.HasPrefix(err.Error(), chaincode.ErrInternal))
	ctx = l.org1()
	ctx.GetStub().(*mocks.ChaincodeStub).GetTxTimestampReturns(nil, errors.New("x"))
	_, err = sc.SetValueDate(ctx, "PO-D002", "2026-10-20")
	require.True(t, strings.HasPrefix(err.Error(), chaincode.ErrInternal))
	l.failPut = true
	_, err = sc.SetValueDate(l.org1(), "PO-D002", "2026-10-20")
	require.True(t, strings.HasPrefix(err.Error(), chaincode.ErrInternal))
}
