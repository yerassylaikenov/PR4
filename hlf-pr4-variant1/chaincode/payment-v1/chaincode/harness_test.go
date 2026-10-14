package chaincode_test

import (
	"fmt"
	"sort"
	"testing"
	"time"

	"github.com/hyperledger/fabric-chaincode-go/v2/shim"
	"github.com/hyperledger/fabric-protos-go-apiv2/ledger/queryresult"
	"github.com/hyperledger/fabric-protos-go-apiv2/peer"
	"github.com/yaikenov/hlf-pr4-variant1/chaincode/payment/chaincode/mocks"
	"google.golang.org/protobuf/types/known/timestamppb"
)

// fakeLedger wires counterfeiter fakes to an in-memory world state + history so that
// multi-step business scenarios can be tested end to end.
type fakeLedger struct {
	state   map[string][]byte
	history map[string][]*queryresult.KeyModification
	events  []string
	txSeq   int
	failPut bool
}

func newLedger() *fakeLedger {
	return &fakeLedger{state: map[string][]byte{}, history: map[string][]*queryresult.KeyModification{}}
}

// as returns a transaction context for a caller with the given MSP and X.509 identity string.
func (l *fakeLedger) as(msp, id string) *mocks.TransactionContext {
	l.txSeq++
	txID := fmt.Sprintf("tx%04d", l.txSeq)
	ts := timestamppb.New(time.Date(2026, 10, 14, 12, 0, l.txSeq, 0, time.UTC))

	stub := &mocks.ChaincodeStub{}
	stub.GetTxIDReturns(txID)
	stub.GetTxTimestampReturns(ts, nil)
	stub.GetStateStub = func(k string) ([]byte, error) { return l.state[k], nil }
	stub.PutStateStub = func(k string, v []byte) error {
		if l.failPut {
			return fmt.Errorf("put failed")
		}
		l.state[k] = v
		l.history[k] = append(l.history[k], &queryresult.KeyModification{TxId: txID, Value: v, Timestamp: ts})
		return nil
	}
	stub.SetEventStub = func(name string, _ []byte) error { l.events = append(l.events, name); return nil }
	stub.GetStateByRangeWithPaginationCalls(func(start, end string, size int32, bookmark string) (
		shim.StateQueryIteratorInterface, *peer.QueryResponseMetadata, error) {
		keys := make([]string, 0, len(l.state))
		for k := range l.state {
			if k >= start && k < end && (bookmark == "" || k >= bookmark) {
				keys = append(keys, k)
			}
		}
		sort.Strings(keys)
		next := ""
		if len(keys) > int(size) {
			next = keys[size]
			keys = keys[:size]
		}
		return l.iterator(keys), &peer.QueryResponseMetadata{FetchedRecordsCount: int32(len(keys)), Bookmark: next}, nil
	})
	stub.GetHistoryForKeyCalls(func(k string) (shim.HistoryQueryIteratorInterface, error) {
		mods := l.history[k]
		i := 0
		it := &mocks.HistoryQueryIterator{}
		it.HasNextCalls(func() bool { return i < len(mods) })
		it.NextCalls(func() (*queryresult.KeyModification, error) { i++; return mods[i-1], nil })
		return it, nil
	})

	ci := &mocks.ClientIdentity{}
	ci.GetMSPIDReturns(msp, nil)
	ci.GetIDReturns(id, nil)

	ctx := &mocks.TransactionContext{}
	ctx.GetStubReturns(stub)
	ctx.GetClientIdentityReturns(ci)
	return ctx
}

func (l *fakeLedger) iterator(keys []string) *mocks.StateQueryIterator {
	i := 0
	it := &mocks.StateQueryIterator{}
	it.HasNextCalls(func() bool { return i < len(keys) })
	it.NextCalls(func() (*queryresult.KV, error) {
		k := keys[i]
		i++
		return &queryresult.KV{Key: k, Value: l.state[k]}, nil
	})
	return it
}

const (
	org1Admin = "x509::CN=org1admin::CN=ca.org1.example.com"
	org2Admin = "x509::CN=org2admin::CN=ca.org2.example.com"
)

func (l *fakeLedger) org1() *mocks.TransactionContext { return l.as("Org1MSP", org1Admin) }
func (l *fakeLedger) org2() *mocks.TransactionContext { return l.as("Org2MSP", org2Admin) }

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}
