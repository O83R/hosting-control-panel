package jobs

import (
	"context"
	"errors"
	"testing"
)

func TestEnqueueRequiresTrustedTransaction(t *testing.T) {
	_, err := EnqueueTenantPing(context.Background(), nil,
		"11111111-1111-1111-1111-111111111111", validIntent())
	if !errors.Is(err, ErrMissingTransaction) {
		t.Fatalf("expected missing transaction error, got %v", err)
	}
}

func TestEnqueueIsRestrictedToVerifiedSyntheticIntent(t *testing.T) {
	in := validIntent()
	in.Kind = "dns.record.create"
	_, err := Prepare(in)
	if !errors.Is(err, ErrUnsupported) {
		t.Fatalf("mutating job must fail before database call: %v", err)
	}
}
