package dns

import (
	"encoding/json"
	"errors"
	"net/url"
	"strings"
)

type Cloudflare struct{}

func (Cloudflare) Mode() Mode { return ModeManaged }

func (Cloudflare) PlanUpsert(binding Binding, record Record) (MutationPlan, error) {
	if err := validateBinding(binding); err != nil {
		return MutationPlan{}, err
	}
	if binding.ProviderType != "cloudflare" || binding.Mode != ModeManaged {
		return MutationPlan{}, errors.New("cloudflare binding is invalid")
	}
	if strings.TrimSpace(binding.ProviderZoneRef) == "" || strings.TrimSpace(binding.CredentialRef) == "" {
		return MutationPlan{}, errors.New("cloudflare zone and credential references are required")
	}
	if err := validateRecord(record); err != nil {
		return MutationPlan{}, err
	}
	if err := validateRecordZone(binding.ZoneName, record.Name); err != nil {
		return MutationPlan{}, err
	}

	payload, err := json.Marshal(map[string]any{
		"type":    record.Type,
		"name":    record.Name,
		"content": record.Content,
		"ttl":     record.TTL,
		"proxied": record.Proxied,
	})
	if err != nil {
		return MutationPlan{}, err
	}

	base := "/client/v4/zones/" + url.PathEscape(binding.ProviderZoneRef) + "/dns_records"
	if strings.TrimSpace(record.ProviderRecordRef) == "" {
		return MutationPlan{
			Provider: "cloudflare",
			Action:   "dns.record.create",
			Method:   "POST",
			Path:     base,
			Body:     payload,
		}, nil
	}
	return MutationPlan{
		Provider: "cloudflare",
		Action:   "dns.record.update",
		Method:   "PUT",
		Path:     base + "/" + url.PathEscape(record.ProviderRecordRef),
		Body:     payload,
	}, nil
}

func (Cloudflare) PlanDelete(binding Binding, record Record) (MutationPlan, error) {
	if err := validateBinding(binding); err != nil {
		return MutationPlan{}, err
	}
	if binding.ProviderType != "cloudflare" || binding.Mode != ModeManaged {
		return MutationPlan{}, errors.New("cloudflare binding is invalid")
	}
	if strings.TrimSpace(binding.ProviderZoneRef) == "" || strings.TrimSpace(binding.CredentialRef) == "" {
		return MutationPlan{}, errors.New("cloudflare zone and credential references are required")
	}
	if strings.TrimSpace(record.ProviderRecordRef) == "" {
		return MutationPlan{}, errors.New("provider record reference is required for delete")
	}
	if err := validateRecordZone(binding.ZoneName, record.Name); err != nil {
		return MutationPlan{}, err
	}
	return MutationPlan{
		Provider: "cloudflare",
		Action:   "dns.record.delete",
		Method:   "DELETE",
		Path: "/client/v4/zones/" + url.PathEscape(binding.ProviderZoneRef) +
			"/dns_records/" + url.PathEscape(record.ProviderRecordRef),
	}, nil
}

// validateRecordZone keeps planned provider mutations inside the configured zone.
// The executor must additionally authorize the provider record ID against the
// tenant-owned database record immediately before an actual provider request.
func validateRecordZone(zoneName, recordName string) error {
	zone := strings.TrimSpace(zoneName)
	name := strings.TrimSpace(recordName)
	if zone == "" || name == "" ||
		zone != strings.ToLower(zone) || name != strings.ToLower(name) ||
		strings.HasSuffix(zone, ".") || strings.HasSuffix(name, ".") ||
		strings.HasPrefix(name, ".") || strings.Contains(name, "..") ||
		(name != zone && !strings.HasSuffix(name, "."+zone)) {
		return errors.New("dns record name is outside the canonical provider zone")
	}
	return nil
}
