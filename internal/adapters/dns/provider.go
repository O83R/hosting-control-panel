package dns

import (
	"encoding/json"
	"errors"
	"strings"
)

var ErrReadOnly = errors.New("dns provider is read only")

type Mode string

const (
	ModeManaged  Mode = "managed"
	ModeReadOnly Mode = "read_only"
)

type Binding struct {
	ProviderType    string
	ZoneName        string
	ProviderZoneRef string
	CredentialRef   string
	Mode            Mode
}

type Record struct {
	ProviderRecordRef string
	Type              string
	Name              string
	Content           string
	TTL               int
	Proxied           bool
}

type MutationPlan struct {
	Provider string
	Action   string
	Method   string
	Path     string
	Body     json.RawMessage
}

type Provider interface {
	Mode() Mode
	PlanUpsert(Binding, Record) (MutationPlan, error)
	PlanDelete(Binding, Record) (MutationPlan, error)
}

func validateBinding(binding Binding) error {
	if strings.TrimSpace(binding.ZoneName) == "" {
		return errors.New("zone name is required")
	}
	if binding.Mode != ModeManaged && binding.Mode != ModeReadOnly {
		return errors.New("dns provider mode is invalid")
	}
	return nil
}

func validateRecord(record Record) error {
	switch record.Type {
	case "A", "AAAA", "CNAME", "TXT", "MX", "CAA":
	default:
		return errors.New("dns record type is invalid")
	}
	if strings.TrimSpace(record.Name) == "" || strings.TrimSpace(record.Content) == "" {
		return errors.New("dns record name and content are required")
	}
	if record.TTL < 1 || record.TTL > 86400 {
		return errors.New("dns ttl is invalid")
	}
	return nil
}
