package jobs

import (
	"encoding/json"
	"errors"
	"testing"
)

func validIntent() Intent {
	return Intent{
		TenantID:       "tenant-a",
		Kind:           "agent.ping",
		ResourceType:   "node",
		ResourceID:     "node-1",
		RequestedBy:    "tester",
		IdempotencyKey: "once-only",
		Input:          json.RawMessage(`{}`),
	}
}

func TestPrepareDeterministicAndCanonical(t *testing.T) {
	a, err := Prepare(validIntent())
	if err != nil {
		t.Fatal(err)
	}
	in := validIntent()
	in.Input = nil
	b, err := Prepare(in)
	if err != nil {
		t.Fatal(err)
	}
	if a.Fingerprint != b.Fingerprint || len(a.Fingerprint) != 64 {
		t.Fatalf("fingerprint changed for equivalent intent")
	}
	if len(a.Steps) != 4 {
		t.Fatalf("unexpected steps: %v", a.Steps)
	}
	if err := ReplayDecision(a.Fingerprint, b.Fingerprint); err != nil {
		t.Fatal(err)
	}
}

func TestRejectsUnknownOrMutatingAction(t *testing.T) {
	for _, action := range []string{"", "shell.exec", "dns.record.create", "ssl.issue", "container.restart", "node.inspect"} {
		in := validIntent()
		in.Kind = action
		_, err := Prepare(in)
		if !errors.Is(err, ErrUnsupported) {
			t.Errorf("%q should be rejected: %v", action, err)
		}
	}
}

func TestRejectsUnexpectedInputAndMissingScope(t *testing.T) {
	for _, raw := range []string{`{"command":"whoami"}`, `{"enabled":true}`, `null`, `[]`, `bad`} {
		in := validIntent()
		in.Input = json.RawMessage(raw)
		if _, err := Prepare(in); !errors.Is(err, ErrInvalidIntent) {
			t.Errorf("input %q should be rejected: %v", raw, err)
		}
	}
	for _, mutate := range []func(*Intent){
		func(i *Intent) { i.TenantID = "" },
		func(i *Intent) { i.ResourceType = "service" },
		func(i *Intent) { i.ResourceID = "" },
		func(i *Intent) { i.RequestedBy = "" },
		func(i *Intent) { i.IdempotencyKey = "" },
		func(i *Intent) { i.IdempotencyKey = string(make([]byte, 201)) },
	} {
		in := validIntent()
		mutate(&in)
		if _, err := Prepare(in); err == nil {
			t.Fatalf("missing or invalid scope was accepted: %#v", in)
		}
	}
}

func TestConflictOnDifferentIntentForSameKey(t *testing.T) {
	a, _ := Prepare(validIntent())
	in := validIntent()
	in.ResourceID = "node-2"
	b, _ := Prepare(in)
	if !errors.Is(ReplayDecision(a.Fingerprint, b.Fingerprint), ErrIdempotencyConflict) {
		t.Fatal("different resource with same key did not conflict")
	}
	in = validIntent()
	in.TenantID = "tenant-b"
	c, _ := Prepare(in)
	if !errors.Is(ReplayDecision(a.Fingerprint, c.Fingerprint), ErrIdempotencyConflict) {
		t.Fatal("cross-tenant fingerprint collision was not detected")
	}
	if !errors.Is(ReplayDecision("bad", a.Fingerprint), ErrInvalidIntent) {
		t.Fatal("malformed persisted fingerprint was accepted")
	}
}
