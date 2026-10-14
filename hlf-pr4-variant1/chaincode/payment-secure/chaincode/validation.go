package chaincode

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"regexp"
	"strconv"
	"unicode"
	"unicode/utf8"
)

// Error codes. Messages never contain settlement details or internal state.
const (
	ErrValidation        = "ERR_VALIDATION"
	ErrUnauthorized      = "ERR_UNAUTHORIZED"
	ErrNotFound          = "ERR_NOT_FOUND"
	ErrAlreadyExists     = "ERR_ALREADY_EXISTS"
	ErrInvalidTransition = "ERR_INVALID_TRANSITION"
	ErrInternal          = "ERR_INTERNAL"
)

func newErr(code, format string, args ...any) error {
	return fmt.Errorf("%s: %s", code, fmt.Sprintf(format, args...))
}

// Compiled once; immutable after package initialisation.
var (
	reOrderID     = regexp.MustCompile(`^PO-[A-Z0-9-]{4,32}$`)
	reAmount      = regexp.MustCompile(`^[1-9][0-9]{0,18}$`)
	rePurposeCode = regexp.MustCompile(`^[0-9]{3}$`)
	reReasonCode  = regexp.MustCompile(`^[A-Z0-9_]{2,32}$`)
	reIBAN        = regexp.MustCompile(`^[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}$`)
	reBIC         = regexp.MustCompile(`^[A-Z]{4}[A-Z]{2}[A-Z0-9]{2}([A-Z0-9]{3})?$`)
	reBIN         = regexp.MustCompile(`^[0-9]{12}$`)
	reSalt        = regexp.MustCompile(`^[0-9a-f]{32,128}$`)
)

// OWASP SC04:2025 — strict ID format (no CouchDB selector / wildcard characters).
func validateID(id string) error {
	if !reOrderID.MatchString(id) {
		return newErr(ErrValidation, "id must match ^PO-[A-Z0-9-]{4,32}$")
	}
	return nil
}

// OWASP SC08:2025 — canonical positive integer in minor units, int64-safe, bounded, no float.
func parseAmount(s string) (int64, error) {
	if !reAmount.MatchString(s) {
		return 0, newErr(ErrValidation, "amount must be a positive integer in minor units")
	}
	v, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		return 0, newErr(ErrValidation, "amount out of int64 range")
	}
	if v < 1 || v > MaxAmount {
		return 0, newErr(ErrValidation, "amount must be in range 1..%d", MaxAmount)
	}
	return v, nil
}

func validateCurrency(c string) error {
	switch c {
	case "KZT", "USD", "EUR", "RUB", "CNY":
		return nil
	}
	return newErr(ErrValidation, "currency is not supported")
}

func validatePurposeCode(p string) error {
	if !rePurposeCode.MatchString(p) {
		return newErr(ErrValidation, "purposeCode must be 3 digits")
	}
	return nil
}

// OWASP SC04:2025 / SC10:2025 — bounded UTF-8 text without control characters.
func validateText(field, s string, maxRunes int) error {
	if s == "" || !utf8.ValidString(s) {
		return newErr(ErrValidation, "%s must be non-empty valid UTF-8", field)
	}
	if utf8.RuneCountInString(s) > maxRunes {
		return newErr(ErrValidation, "%s exceeds %d characters", field, maxRunes)
	}
	for _, r := range s {
		if unicode.IsControl(r) {
			return newErr(ErrValidation, "%s contains control characters", field)
		}
	}
	return nil
}

func validateReasonCode(c string) error {
	if !reReasonCode.MatchString(c) {
		return newErr(ErrValidation, "reasonCode must match ^[A-Z0-9_]{2,32}$")
	}
	return nil
}

func validatePageSize(n int32) error {
	if n < 1 || n > MaxPageSize {
		return newErr(ErrValidation, "pageSize must be in range 1..%d", MaxPageSize)
	}
	return nil
}

// validIBAN — ISO 13616: format, country length for KZ (20) and mod-97 checksum == 1.
// The value itself is never put into an error message.
func validIBAN(iban string) bool {
	if !reIBAN.MatchString(iban) {
		return false
	}
	if iban[:2] == "KZ" && len(iban) != 20 {
		return false
	}
	rearranged := iban[4:] + iban[:4]
	rem := 0
	for _, r := range rearranged {
		var v int
		if r >= '0' && r <= '9' {
			v = int(r - '0')
			rem = (rem*10 + v) % 97
		} else {
			v = int(r-'A') + 10
			rem = (rem*100 + v) % 97
		}
	}
	return rem == 1
}

// decodeSettlement — OWASP SC04:2025 / SC10:2025: size limit, strict JSON (unknown fields rejected,
// no trailing data), field-level validation. Errors name the field, never the value.
func decodeSettlement(raw []byte) (*SettlementDetails, error) {
	if len(raw) == 0 {
		return nil, newErr(ErrValidation, "transient settlement payload is empty")
	}
	if len(raw) > MaxTransientSize {
		return nil, newErr(ErrValidation, "transient payload exceeds %d bytes", MaxTransientSize)
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	var d SettlementDetails
	if err := dec.Decode(&d); err != nil {
		return nil, newErr(ErrValidation, "settlement payload is not valid JSON or has unknown fields")
	}
	if _, err := dec.Token(); err != io.EOF {
		return nil, newErr(ErrValidation, "unexpected data after settlement JSON")
	}
	if !validIBAN(d.PayerIBAN) {
		return nil, newErr(ErrValidation, "payerIBAN is invalid (format or mod-97 checksum)")
	}
	if !validIBAN(d.BeneficiaryIBAN) {
		return nil, newErr(ErrValidation, "beneficiaryIBAN is invalid (format or mod-97 checksum)")
	}
	if !reBIN.MatchString(d.PayerBIN) {
		return nil, newErr(ErrValidation, "payerBIN must be 12 digits")
	}
	if !reBIC.MatchString(d.BeneficiaryBIC) {
		return nil, newErr(ErrValidation, "beneficiaryBIC is invalid")
	}
	if err := validateText("beneficiaryName", d.BeneficiaryName, MaxNameRunes); err != nil {
		return nil, err
	}
	// OWASP SC09:2025 — the salt is produced by the client; chaincode never generates randomness.
	if !reSalt.MatchString(d.Salt) {
		return nil, newErr(ErrValidation, "salt must be 32..128 lowercase hex characters")
	}
	return &d, nil
}

// canonical returns the exact bytes stored in the collection (and therefore hashed by Fabric).
func canonical(d *SettlementDetails) ([]byte, error) {
	b, err := json.Marshal(d)
	if err != nil {
		return nil, newErr(ErrInternal, "marshal failed")
	}
	return b, nil
}
