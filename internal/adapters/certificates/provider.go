package certificates

import (
	"errors"
	"strings"
)

type ChallengeType string

const (
	ChallengeDNS01  ChallengeType = "dns-01"
	ChallengeHTTP01 ChallengeType = "http-01"
)

func (c ChallengeType) Valid() bool {
	return c == ChallengeDNS01 || c == ChallengeHTTP01
}

type OrderIntent struct {
	Provider      string
	Domain        string
	ChallengeType ChallengeType
	ContactRef    string
	KeyRef        string
}

type ACME struct{}

func (ACME) PlanOrder(domain string, challenge ChallengeType, contactRef, keyRef string) (OrderIntent, error) {
	if strings.TrimSpace(domain) == "" {
		return OrderIntent{}, errors.New("domain is required")
	}
	if !challenge.Valid() {
		return OrderIntent{}, errors.New("acme challenge type is invalid")
	}
	if strings.TrimSpace(contactRef) == "" || strings.TrimSpace(keyRef) == "" {
		return OrderIntent{}, errors.New("acme contact and key references are required")
	}
	return OrderIntent{
		Provider:      "acme",
		Domain:        domain,
		ChallengeType: challenge,
		ContactRef:    contactRef,
		KeyRef:        keyRef,
	}, nil
}
