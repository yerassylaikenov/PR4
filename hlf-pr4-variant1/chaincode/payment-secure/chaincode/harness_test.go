package chaincode_test

import (
	"crypto/sha256"
	"fmt"
	"sort"
	"testing"
	"time"

	"github.com/hyperledger/fabric-chaincode-go/v2/shim"
	"github.com/hyperledger/fabric-protos-go-apiv2/ledger/queryresult"
	"github.com/hyperledger/fabric-protos-go-apiv2/peer"
	"github.com/yaikenov/hlf-pr4-variant1/chaincode/paymentsecure/chaincode/mocks"
	"google.golang.org/protobuf/types/known/timestamppb"
)

// fakeLedger — counterfeiter fakes wired to in-memory public state, history and one private collection
// (with Fabric's SHA-256 value hashes visible to everyone, like the $$h namespace).
type fakeLedger struct {
	state   map[string][]byte
	private map[string][]byte
	history map[string][]*queryresult.KeyModification
	events  []string
	txSeq   int
	failPut bool
}

func newLedger() *fakeLedger {
	return &fakeLedger{state: map[string][]byte{}, private: map[string][]byte{},
		history: map[string][]*queryresult.KeyModification{}}
}

type caller struct {
	msp, id string
	role    string // "" = no role attribute
}

var (
	initiator1 = caller{"Org1MSP", "x509::CN=initiator1::CN=ca.org1.example.com", "initiator"}
	initiatorB = caller{"Org1MSP", "x509::CN=initiator9::CN=ca.org1.example.com", "initiator"}
	approver1  = caller{"Org1MSP", "x509::CN=approver1::CN=ca.org1.example.com", "approver"}
	norole1    = caller{"Org1MSP", "x509::CN=norole1::CN=ca.org1.example.com", ""}
	admin1     = caller{"Org1MSP", "x509::CN=org1admin::CN=ca.org1.example.com", ""}
	processor2 = caller{"Org2MSP", "x509::CN=processor2::CN=ca.org2.example.com", "processor"}
	approver2  = caller{"Org2MSP", "x509::CN=approver2::CN=ca.org2.example.com", "approver"}
	initiator2 = caller{"Org2MSP", "x509::CN=initiator2::CN=ca.org2.example.com", "initiator"}
)

// as builds a transaction context for caller c with the given transient map.
func (l *fakeLedger) as(c caller, transient map[string][]byte) *mocks.TransactionContext {
	l.txSeq++
	txID := fmt.Sprintf("tx%04d", l.txSeq)
	ts := timestamppb.New(time.Date(2026, 10, 14, 12, 0, l.txSeq, 0, time.UTC))

	stub := &mocks.ChaincodeStub{}
	stub.GetTxIDReturns(txID)
	stub.GetTxTimestampReturns(ts, nil)
	stub.GetTransientReturns(transient, nil)
	stub.GetStateStub = func(k string) ([]byte, error) { return l.state[k], nil }
	stub.PutStateStub = func(k string, v []byte) error {
		if l.failPut {
			return fmt.Errorf("put failed")
		}
		l.state[k] = v
		l.history[k] = append(l.history[k], &queryresult.KeyModification{TxId: txID, Value: v, Timestamp: ts})
		return nil
	}
	stub.PutPrivateDataStub = func(coll, k string, v []byte) error {
		if l.failPut {
			return fmt.Errorf("put failed")
		}
		l.private[coll+"/"+k] = v
		return nil
	}
	stub.GetPrivateDataStub = func(coll, k string) ([]byte, error) { return l.private[coll+"/"+k], nil }
	stub.GetPrivateDataHashStub = func(coll, k string) ([]byte, error) {
		v, ok := l.private[coll+"/"+k]
		if !ok {
			return nil, nil
		}
		h := sha256.Sum256(v)
		return h[:], nil
	}
	stub.SetEventStub = func(name string, _ []byte) error { l.events = append(l.events, name); return nil }
	stub.GetStateByRangeWithPaginationCalls(func(start, end string, size int32, bookmark string) (
		shim.StateQueryIteratorInterface, *peer.QueryResponseMetadata, error) {
		keys := []string{}
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
		i := 0
		it := &mocks.StateQueryIterator{}
		it.HasNextCalls(func() bool { return i < len(keys) })
		it.NextCalls(func() (*queryresult.KV, error) {
			i++
			return &queryresult.KV{Key: keys[i-1], Value: l.state[keys[i-1]]}, nil
		})
		return it, &peer.QueryResponseMetadata{FetchedRecordsCount: int32(len(keys)), Bookmark: next}, nil
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
	ci.GetMSPIDReturns(c.msp, nil)
	ci.GetIDReturns(c.id, nil)
	ci.AssertAttributeValueCalls(func(name, value string) error {
		if name == "role" && c.role != "" && c.role == value {
			return nil
		}
		return fmt.Errorf("attribute %s does not match", name)
	})

	ctx := &mocks.TransactionContext{}
	ctx.GetStubReturns(stub)
	ctx.GetClientIdentityReturns(ci)
	return ctx
}

func (l *fakeLedger) by(c caller) *mocks.TransactionContext { return l.as(c, nil) }

// onPeer sets the MSP of the peer running the chaincode (shim.GetMSPID reads CORE_PEER_LOCALMSPID).
func onPeer(t *testing.T, msp string) { t.Helper(); t.Setenv("CORE_PEER_LOCALMSPID", msp) }

// Synthetic test data: IBANs are checksum-valid but use the non-existent bank code 999 and "TEST".
const (
	ibanPayer = "KZ09999TESTPAYER0001"
	ibanBenef = "KZ17999TESTBENEF0002"
	saltHex   = "6f1c2a9e0b7d4c3a8e5f1029384756aa6f1c2a9e0b7d4c3a8e5f1029384756aa"
)

func settlementJSON(mut ...func(m map[string]any)) []byte {
	m := map[string]any{
		"payerIBAN": ibanPayer, "payerBIN": "999999000001", "beneficiaryIBAN": ibanBenef,
		"beneficiaryBIC": "TESTKZKAXXX", "beneficiaryName": "TOO SYNTHETIC BENEFICIARY", "salt": saltHex,
	}
	for _, f := range mut {
		f(m)
	}
	return mustJSON(m)
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}
