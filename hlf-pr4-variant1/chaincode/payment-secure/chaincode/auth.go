package chaincode

import (
	"crypto/sha256"
	"encoding/hex"

	"github.com/hyperledger/fabric-chaincode-go/v2/shim"
	"github.com/hyperledger/fabric-contract-api-go/v2/contractapi"
)

// callerMSP — OWASP SC01:2025 — organisation of the transaction creator.
func callerMSP(ctx contractapi.TransactionContextInterface) (string, error) {
	msp, err := ctx.GetClientIdentity().GetMSPID()
	if err != nil || msp == "" {
		return "", newErr(ErrInternal, "cannot read caller MSP")
	}
	return msp, nil
}

// requireMSP — caller must belong to exactly this organisation.
func requireMSP(ctx contractapi.TransactionContextInterface, want string) error {
	msp, err := callerMSP(ctx)
	if err != nil {
		return err
	}
	if msp != want {
		return newErr(ErrUnauthorized, "caller organisation is not allowed to perform this operation")
	}
	return nil
}

// requireRole — OWASP SC01:2025 — the "role" attribute (Fabric CA ecert) must be one of roles.
func requireRole(ctx contractapi.TransactionContextInterface, roles ...string) error {
	for _, r := range roles {
		if err := ctx.GetClientIdentity().AssertAttributeValue(AttrRole, r); err == nil {
			return nil
		}
	}
	return newErr(ErrUnauthorized, "caller role is not permitted for this operation")
}

// requirePeerOrg — private data is served only when client org == peer org (private data tutorial).
func requirePeerOrg(ctx contractapi.TransactionContextInterface) error {
	msp, err := callerMSP(ctx)
	if err != nil {
		return err
	}
	peerMSP, err := shim.GetMSPID()
	if err != nil {
		return newErr(ErrInternal, "cannot read peer MSP")
	}
	if msp != peerMSP {
		return newErr(ErrUnauthorized, "client organisation does not match the peer organisation")
	}
	return nil
}

// callerIDHash — only sha256 of the X.509 identity reaches the public state.
func callerIDHash(ctx contractapi.TransactionContextInterface) (string, error) {
	id, err := ctx.GetClientIdentity().GetID()
	if err != nil {
		return "", newErr(ErrInternal, "cannot read caller identity")
	}
	sum := sha256.Sum256([]byte(id))
	return hex.EncodeToString(sum[:]), nil
}
