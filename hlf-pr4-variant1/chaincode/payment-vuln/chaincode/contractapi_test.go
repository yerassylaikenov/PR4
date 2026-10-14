package chaincode_test

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"math/big"
	"testing"
	"time"

	"github.com/hyperledger/fabric-contract-api-go/v2/contractapi"
	"github.com/hyperledger/fabric-protos-go-apiv2/msp"
	"github.com/hyperledger/fabric-protos-go-apiv2/peer"
	"github.com/stretchr/testify/require"
	"github.com/yaikenov/hlf-pr4-variant1/chaincode/paymentvuln/chaincode"
	"github.com/yaikenov/hlf-pr4-variant1/chaincode/paymentvuln/chaincode/mocks"
	"google.golang.org/protobuf/proto"
)

// Regression test for a defect found during the first deployment: contractapi validates every
// return value against the generated JSON schema; an omitempty field without metadata:",optional"
// made all PaymentOrder-returning functions fail at endorsement ("rejectReason is required").
// These tests go through ContractChaincode.Invoke, i.e. the same path the peer uses.

func creatorBytes(t *testing.T, mspID string) []byte {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "tester", OrganizationalUnit: []string{"admin"}},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	require.NoError(t, err)
	b, err := proto.Marshal(&msp.SerializedIdentity{
		Mspid:   mspID,
		IdBytes: pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}),
	})
	require.NoError(t, err)
	return b
}

func invokeCC(t *testing.T, cc *contractapi.ContractChaincode, l *fakeLedger, mspID, fn string, args ...string) *peer.Response {
	t.Helper()
	stub := l.as(mspID, "x509::CN=tester").GetStub().(*mocks.ChaincodeStub)
	stub.GetCreatorReturns(creatorBytes(t, mspID), nil)
	stub.GetFunctionAndParametersReturns(fn, args)
	return cc.Invoke(stub)
}

func TestThroughContractAPISchemaValidation(t *testing.T) {
	cc, err := contractapi.NewChaincode(&chaincode.SmartContract{})
	require.NoError(t, err)
	l := newLedger()

	steps := []struct {
		msp, fn string
		args    []string
	}{
		{"Org1MSP", "CreatePaymentOrder", []string{"PO-0001", "Org2MSP", "5000000", "KZT", "119", "Invoice"}},
		{"Org1MSP", "SubmitPaymentOrder", []string{"PO-0001"}},
		{"Org2MSP", "RejectPaymentOrder", []string{"PO-0001", "ACCOUNT_CLOSED"}},
		{"Org2MSP", "ReadPaymentOrder", []string{"PO-0001"}},
		{"Org1MSP", "CreatePaymentOrder", []string{"PO-0002", "Org2MSP", "1", "USD", "710", "x"}},
		{"Org1MSP", "SubmitPaymentOrder", []string{"PO-0002"}},
		{"Org2MSP", "AcceptPaymentOrder", []string{"PO-0002"}},
		{"Org2MSP", "SettlePaymentOrder", []string{"PO-0002"}},
		{"Org1MSP", "CreatePaymentOrder", []string{"PO-0003", "Org2MSP", "1", "EUR", "119", "x"}},
		{"Org1MSP", "CancelPaymentOrder", []string{"PO-0003"}},
		{"Org1MSP", "PaymentOrderExists", []string{"PO-0002"}},
		{"Org1MSP", "GetAllPaymentOrders", []string{"10", ""}},
		{"Org1MSP", "GetPaymentOrderHistory", []string{"PO-0002"}},
	}
	for _, s := range steps {
		res := invokeCC(t, cc, l, s.msp, s.fn, s.args...)
		require.Equal(t, int32(200), res.GetStatus(), "%s: %s", s.fn, res.GetMessage())
	}

	res := invokeCC(t, cc, l, "Org1MSP", "ReadPaymentOrder", "PO-0001")
	var po chaincode.PaymentOrder
	require.NoError(t, json.Unmarshal(res.GetPayload(), &po))
	require.Equal(t, "REJECTED", po.Status)
	require.Equal(t, "ACCOUNT_CLOSED", po.RejectReason)

	res = invokeCC(t, cc, l, "Org2MSP", "CreatePaymentOrder", "PO-0009", "Org1MSP", "1", "KZT", "119", "x")
	require.Equal(t, int32(500), res.GetStatus())
	require.Contains(t, res.GetMessage(), "ERR_UNAUTHORIZED")
}
