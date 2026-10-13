package agentprotocol

import "testing"

func TestSignVerify(t *testing.T) {
	secret := []byte("0123456789abcdef0123456789abcdef")
	body := []byte(`{"request_id":"r1"}`)
	sig := Sign(secret, "1700000000", "nonce-0123456789", "POST", "/v1/actions/agent.ping", body)

	if !Verify(secret, "1700000000", "nonce-0123456789", "POST", "/v1/actions/agent.ping", body, sig) {
		t.Fatal("valid signature rejected")
	}
	if Verify(secret, "1700000000", "nonce-0123456789", "POST", "/v1/actions/agent.ping", []byte("{}"), sig) {
		t.Fatal("tampered body accepted")
	}
	if Verify(secret, "1700000000", "nonce-0123456789", "GET", "/v1/actions/agent.ping", body, sig) {
		t.Fatal("tampered method accepted")
	}
}

func TestBodyHashStable(t *testing.T) {
	got := BodyHash(nil)
	const want = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
	if got != want {
		t.Fatalf("unexpected empty body hash %q", got)
	}
}
