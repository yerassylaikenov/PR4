package chaincode

import (
	"crypto/sha256"
	"encoding/hex"
)

func hexSHA256(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

func hexBytes(b []byte) string { return hex.EncodeToString(b) }
