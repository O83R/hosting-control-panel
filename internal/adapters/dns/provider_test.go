package dns

import (
	"errors"
	"strings"
	"testing"
)

func TestCloudflarePlansWithoutSecrets(t *testing.T) {
	binding := Binding{
		ProviderType:    "cloudflare",
		ZoneName:        "example.com",
		ProviderZoneRef: "zone-123",
		CredentialRef:   "secretref://cloudflare/tenant-1",
		Mode:            ModeManaged,
	}
	record := Record{
		Type:    "A",
		Name:    "app.example.com",
		Content: "192.0.2.10",
		TTL:     300,
	}

	plan, err := (Cloudflare{}).PlanUpsert(binding, record)
	if err != nil {
		t.Fatal(err)
	}
	if plan.Method != "POST" || plan.Action != "dns.record.create" {
		t.Fatalf("unexpected create plan: %#v", plan)
	}
	if strings.Contains(string(plan.Body), binding.CredentialRef) {
		t.Fatal("credential reference leaked into provider payload")
	}

	record.ProviderRecordRef = "record-456"
	plan, err = (Cloudflare{}).PlanUpsert(binding, record)
	if err != nil {
		t.Fatal(err)
	}
	if plan.Method != "PUT" || !strings.HasSuffix(plan.Path, "/record-456") {
		t.Fatalf("unexpected update plan: %#v", plan)
	}
}

func TestCloudflareRejectsOutOfZonePlans(t *testing.T) {
	binding := Binding{
		ProviderType:    "cloudflare",
		Mode:            ModeManaged,
		ZoneName:        "example.com",
		ProviderZoneRef: "zone-123",
		CredentialRef:   "secretref://cloudflare/tenant-1",
	}
	for _, name := range []string{"example.net", "app.example.net", "example.com.evil.test", "fooexample.com", "sub..example.com", "APP.EXAMPLE.COM"} {
		record := Record{ProviderRecordRef: "record-456", Type: "A", Name: name, Content: "192.0.2.10", TTL: 300}
		if _, err := (Cloudflare{}).PlanUpsert(binding, record); err == nil {
			t.Errorf("upsert unexpectedly allowed record %q outside canonical zone", name)
		}
		if _, err := (Cloudflare{}).PlanDelete(binding, record); err == nil {
			t.Errorf("delete unexpectedly allowed record %q outside canonical zone", name)
		}
	}
	for _, name := range []string{"example.com", "app.example.com", "_acme-challenge.example.com"} {
		record := Record{Type: "TXT", Name: name, Content: "challenge", TTL: 300}
		if _, err := (Cloudflare{}).PlanUpsert(binding, record); err != nil {
			t.Errorf("valid in-zone record %q rejected: %v", name, err)
		}
	}
}

func TestExternalProviderIsReadOnly(t *testing.T) {
	_, err := (ExternalReadOnly{}).PlanUpsert(Binding{}, Record{})
	if !errors.Is(err, ErrReadOnly) {
		t.Fatalf("expected read-only error, got %v", err)
	}
	_, err = (ExternalReadOnly{}).PlanDelete(Binding{}, Record{})
	if !errors.Is(err, ErrReadOnly) {
		t.Fatalf("expected read-only error, got %v", err)
	}
}
