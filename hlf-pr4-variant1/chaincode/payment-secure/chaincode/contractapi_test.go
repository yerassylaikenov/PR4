package chaincode_test

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/json"
	"encoding/pem"
	"math/big"
	"testing"
	"time"

	"github.com/hyperledger/fabric-contract-api-go/v2/contractapi"
	"github.com/hyperledger/fabric-protos-go-apiv2/msp"
	"github.com/hyperledger/fabric-protos-go-apiv2/peer"
	"github.com/stretchr/testify/require"
	"github.com/yaikenov/hlf-pr4-variant1/chaincode/paymentsecure/chaincode"
	"github.com/yaikenov/hlf-pr4-variant1/chaincode/paymentsecure/chaincode/mocks"
	"google.golang.org/protobuf/proto"
)

// End-to-end through ContractChaincode.Invoke: real cid parsing of the Fabric CA attribute extension
// (OID 1.2.3.4.5.6.7.8.1) and contractapi JSON-schema validation of every return type.

func certWithRole(t *testing.T, mspID, cn, role string) []byte {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(time.Now().UnixNano()),
		Subject:      pkix.Name{CommonName: cn, OrganizationalUnit: []string{"client"}},
		NotBefore:    time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
	}
	if role != "" {
		attrs, _ := json.Marshal(map[string]any{"attrs": map[string]string{"role": role}})
		tmpl.ExtraExtensions = []pkix.Extension{{Id: asn1.ObjectIdentifier{1, 2, 3, 4, 5, 6, 7, 8, 1}, Value: attrs}}
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	require.NoError(t, err)
	b, err := proto.Marshal(&msp.SerializedIdentity{Mspid: mspID, IdBytes: pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})})
	require.NoError(t, err)
	return b
}

type ident struct {
	creator []byte
	msp     string
}

func invokeAs(t *testing.T, cc *contractapi.ContractChaincode, l *fakeLedger, who ident, tm map[string][]byte, fn string, args ...string) *peer.Response {
	t.Helper()
	stub := l.as(caller{msp: who.msp}, tm).GetStub().(*mocks.ChaincodeStub)
	stub.GetCreatorReturns(who.creator, nil)
	stub.GetFunctionAndParametersReturns(fn, args)
	return cc.Invoke(stub)
}

func TestSecureThroughContractAPI(t *testing.T) {
	cc, err := contractapi.NewChaincode(&chaincode.SmartContract{})
	require.NoError(t, err)
	l := newLedger()
	ini := ident{certWithRole(t, "Org1MSP", "initiator1", "initiator"), "Org1MSP"}
	apr := ident{certWithRole(t, "Org1MSP", "approver1", "approver"), "Org1MSP"}
	nor := ident{certWithRole(t, "Org1MSP", "norole1", ""), "Org1MSP"}
	prc := ident{certWithRole(t, "Org2MSP", "processor2", "processor"), "Org2MSP"}
	tm := map[string][]byte{"settlement": settlementJSON()}

	ok := func(r *peer.Response) *peer.Response {
		t.Helper()
		require.Equal(t, int32(200), r.GetStatus(), r.GetMessage())
		return r
	}
	ok(invokeAs(t, cc, l, ini, nil, "CreatePaymentOrder", "PO-S001", "Org2MSP", "5000000", "KZT", "119", "x"))
	onPeer(t, "Org1MSP")
	ok(invokeAs(t, cc, l, ini, tm, "SetSettlementDetails", "PO-S001"))
	r := ok(invokeAs(t, cc, l, apr, nil, "ReadSettlementDetails", "PO-S001"))
	require.Contains(t, string(r.GetPayload()), ibanPayer)
	ok(invokeAs(t, cc, l, apr, nil, "SubmitPaymentOrder", "PO-S001"))
	onPeer(t, "Org2MSP")
	r = ok(invokeAs(t, cc, l, prc, map[string][]byte{"candidate": settlementJSON()}, "VerifySettlementDetails", "PO-S001"))
	require.JSONEq(t, `{"id":"PO-S001","match":true}`, string(r.GetPayload()))
	ok(invokeAs(t, cc, l, prc, nil, "AcceptPaymentOrder", "PO-S001"))
	ok(invokeAs(t, cc, l, prc, nil, "SettlePaymentOrder", "PO-S001"))
	ok(invokeAs(t, cc, l, prc, nil, "ReadPaymentOrder", "PO-S001"))
	ok(invokeAs(t, cc, l, prc, nil, "GetAllPaymentOrders", "10", ""))
	ok(invokeAs(t, cc, l, prc, nil, "GetPaymentOrderHistory", "PO-S001"))
	ok(invokeAs(t, cc, l, prc, nil, "PaymentOrderExists", "PO-S001"))

	// real attribute parsing: no role attribute -> refused; Org2 cannot read private details
	r = invokeAs(t, cc, l, nor, nil, "CreatePaymentOrder", "PO-S002", "Org2MSP", "1", "KZT", "119", "x")
	require.Equal(t, int32(500), r.GetStatus())
	require.Contains(t, r.GetMessage(), "ERR_UNAUTHORIZED")
	r = invokeAs(t, cc, l, prc, nil, "ReadSettlementDetails", "PO-S001")
	require.Equal(t, int32(500), r.GetStatus())
	require.Contains(t, r.GetMessage(), "ERR_UNAUTHORIZED")
}
