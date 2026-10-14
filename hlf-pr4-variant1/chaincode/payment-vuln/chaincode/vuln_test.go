package chaincode_test

import (
	"testing"

	"github.com/stretchr/testify/require"
	"github.com/yaikenov/hlf-pr4-variant1/chaincode/paymentvuln/chaincode"
)

// TestVulnSubmitWithoutCallerAuthorization documents the intentional lab defect (OWASP SC01:2025):
// the receiver bank alone drives a payment order from CREATED to SETTLED.
// Violated invariants: INV-4 (only the sender bank authorises the debit) and INV-SoD.
func TestVulnSubmitWithoutCallerAuthorization(t *testing.T) {
	l := newLedger()
	create(t, l, "PO-V001")

	po, err := sc.SubmitPaymentOrder(l.org2(), "PO-V001") // must have been ERR_UNAUTHORIZED
	require.NoError(t, err, "vulnerable: Org2 authorises the debit of Org1's order")
	require.Equal(t, chaincode.StatusSubmitted, po.Status)
	_, err = sc.AcceptPaymentOrder(l.org2(), "PO-V001")
	require.NoError(t, err)
	po, err = sc.SettlePaymentOrder(l.org2(), "PO-V001")
	require.NoError(t, err)
	require.Equal(t, chaincode.StatusSettled, po.Status, "Org2 settled the payment without any action of Org1 after creation")

	_, err = sc.SubmitPaymentOrder(l.as("Org3MSP", "x509::CN=x"), "PO-V001")
	require.Error(t, err, "state machine still applies: SETTLED is terminal")
}
