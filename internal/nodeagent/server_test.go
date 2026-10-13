package nodeagent

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"

	"hosting-control-panel/internal/agentprotocol"
)

func signedRequest(t *testing.T, secret []byte, now time.Time, method, path string, body []byte, nonce string) *http.Request {
	t.Helper()
	req := httptest.NewRequest(method, path, bytes.NewReader(body))
	ts := strconv.FormatInt(now.Unix(), 10)
	req.Header.Set(agentprotocol.HeaderProtocolVersion, agentprotocol.Version)
	req.Header.Set(agentprotocol.HeaderTimestamp, ts)
	req.Header.Set(agentprotocol.HeaderNonce, nonce)
	req.Header.Set(agentprotocol.HeaderSignature, agentprotocol.Sign(secret, ts, nonce, method, path, body))
	return req
}

func TestAuthenticatedCapabilitiesAndReplay(t *testing.T) {
	secret := []byte("0123456789abcdef0123456789abcdef")
	s, err := New(secret)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Unix(1700000000, 0).UTC()
	s.now = func() time.Time { return now }

	req := signedRequest(t, secret, now, http.MethodGet, "/v1/capabilities", nil, "nonce-capabilities-0001")
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}

	var payload struct {
		ProtocolVersion string                     `json:"protocol_version"`
		Capabilities    []agentprotocol.Capability `json:"capabilities"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload.ProtocolVersion != agentprotocol.Version || len(payload.Capabilities) != 1 || payload.Capabilities[0].Code != "agent.ping" {
		t.Fatalf("unexpected capabilities response: %#v", payload)
	}

	replay := httptest.NewRecorder()
	s.Handler().ServeHTTP(replay, req)
	if replay.Code != http.StatusConflict {
		t.Fatalf("expected replay rejection, got %d", replay.Code)
	}
}

func TestPingRequiresSignature(t *testing.T) {
	secret := []byte("0123456789abcdef0123456789abcdef")
	s, err := New(secret)
	if err != nil {
		t.Fatal(err)
	}

	body := []byte(`{"request_id":"r1","action":"agent.ping"}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/actions/agent.ping", bytes.NewReader(body))
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", rec.Code)
	}
}

func TestPingReceipt(t *testing.T) {
	secret := []byte("0123456789abcdef0123456789abcdef")
	s, err := New(secret)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Unix(1700000000, 0).UTC()
	s.now = func() time.Time { return now }

	body := []byte(`{"request_id":"r1","job_id":"j1","action":"agent.ping"}`)
	req := signedRequest(t, secret, now, http.MethodPost, "/v1/actions/agent.ping", body, "nonce-ping-request-0001")
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}

	var receipt agentprotocol.ActionReceipt
	if err := json.Unmarshal(rec.Body.Bytes(), &receipt); err != nil {
		t.Fatal(err)
	}
	if receipt.RequestID != "r1" || receipt.Action != "agent.ping" || receipt.Status != "succeeded" {
		t.Fatalf("unexpected receipt: %#v", receipt)
	}
}

func TestUnknownActionIsNotExposed(t *testing.T) {
	secret := []byte("0123456789abcdef0123456789abcdef")
	s, err := New(secret)
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/actions/shell.exec", bytes.NewReader(nil))
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", rec.Code)
	}
}
