package chaincode

import (
	"fmt"
	"regexp"
	"strconv"
	"unicode"
	"unicode/utf8"
)

// Error codes returned to clients. Messages never echo internal state beyond what is needed.
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

// Compiled once; regexp.Regexp is safe for concurrent use and never mutated.
var (
	reOrderID     = regexp.MustCompile(`^PO-[A-Z0-9-]{4,32}$`)
	reAmount      = regexp.MustCompile(`^[1-9][0-9]{0,18}$`)
	rePurposeCode = regexp.MustCompile(`^[0-9]{3}$`)
	reReasonCode  = regexp.MustCompile(`^[A-Z0-9_]{2,32}$`)
)

// OWASP SC04:2025 — input validation: strict ID format (no wildcard/selector characters).
func validateID(id string) error {
	if !reOrderID.MatchString(id) {
		return newErr(ErrValidation, "id must match ^PO-[A-Z0-9-]{4,32}$")
	}
	return nil
}

// parseAmount accepts only canonical positive decimal integers in minor units.
// OWASP SC08:2025 — integer overflow: regexp rejects sign, exponent, spaces and leading zeros;
// strconv.ParseInt rejects values above int64; MaxAmount bounds the business range. No float.
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

// OWASP SC04:2025 — input validation: ISO 4217 whitelist.
func validateCurrency(c string) error {
	switch c {
	case "KZT", "USD", "EUR", "RUB", "CNY":
		return nil
	}
	return newErr(ErrValidation, "currency is not supported")
}

// OWASP SC04:2025 — input validation: KNP (payment purpose code) is exactly 3 digits.
func validatePurposeCode(p string) error {
	if !rePurposeCode.MatchString(p) {
		return newErr(ErrValidation, "purposeCode must be 3 digits")
	}
	return nil
}

// OWASP SC04:2025 / SC10:2025 — bounded free text, valid UTF-8, no control characters.
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

// OWASP SC04:2025 — reason codes are machine-readable identifiers only.
func validateReasonCode(c string) error {
	if !reReasonCode.MatchString(c) {
		return newErr(ErrValidation, "reasonCode must match ^[A-Z0-9_]{2,32}$")
	}
	return nil
}

// OWASP SC10:2025 — denial of service: bounded page size.
func validatePageSize(n int32) error {
	if n < 1 || n > MaxPageSize {
		return newErr(ErrValidation, "pageSize must be in range 1..%d", MaxPageSize)
	}
	return nil
}
