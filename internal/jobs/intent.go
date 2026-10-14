// Package jobs defines fail-closed, non-executing job intents.
// Runtime dispatch, database writes, and provider calls are deliberately absent.
package jobs

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

var (
	ErrInvalidIntent = errors.New("invalid job intent")
	ErrUnsupported = errors.New("unsupported job action")
	ErrIdempotencyConflict = errors.New("idempotency key reused for different intent")
)

// Intent is an instruction proposal, not authorization or permission to execute.
type Intent struct {
	TenantID string
	Kind string
	ResourceType string
	ResourceID string
	RequestedBy string
	IdempotencyKey string
	Input json.RawMessage
}

// Plan is a safe, deterministic description for an isolated verifier.
type Plan struct {
	Intent Intent
	Fingerprint string
	Steps []string
}

// Prepare deliberately supports a read-only synthetic operation only.
// Mutating actions require separate RBAC, approval and worker contracts.
func Prepare(in Intent) (Plan, error) {
	if strings.TrimSpace(in.TenantID) == "" ||
		strings.TrimSpace(in.RequestedBy) == "" ||
		strings.TrimSpace(in.ResourceID) == "" ||
		strings.TrimSpace(in.IdempotencyKey) == "" ||
		len(in.IdempotencyKey) > 200 {
		return Plan{}, fmt.Errorf("%w: missing or oversized scope", ErrInvalidIntent)
	}
	if in.Kind != "agent.ping" {
		return Plan{}, ErrUnsupported
	}
	if in.ResourceType != "node" {
		return Plan{}, fmt.Errorf("%w: agent.ping requires node resource", ErrInvalidIntent)
	}

	if len(in.Input) != 0 {
		var object map[string]json.RawMessage
		if err := json.Unmarshal(in.Input, &object); err != nil || object == nil || len(object) != 0 {
			return Plan{}, fmt.Errorf("%w: agent.ping accepts only an empty JSON object", ErrInvalidIntent)
		}
	}
	in.Input = json.RawMessage(`{}`)
	// Hash tenant, actor, kind, resource and normalized input, not the
	// idempotency key itself. A reused key with different intent is rejected.
	canonical, err := json.Marshal(struct {
		TenantID string `json:"tenant_id"`
		RequestedBy string `json:"requested_by"`
		Kind string `json:"kind"`
		ResourceType string `json:"resource_type"`
		ResourceID string `json:"resource_id"`
		Input json.RawMessage `json:"input"`
	}{
		TenantID: in.TenantID,
		RequestedBy: in.RequestedBy,
		Kind: in.Kind,
		ResourceType: in.ResourceType,
		ResourceID: in.ResourceID,
		Input: in.Input,
	})
	if err != nil {
		return Plan{}, fmt.Errorf("%w: unable to canonicalize", ErrInvalidIntent)
	}
	digest := sha256.Sum256(canonical)
	return Plan{
		Intent: in,
		Fingerprint: hex.EncodeToString(digest[:]),
		Steps: []string{"preflight", "synthetic-agent-ping", "verify", "receipt"},
	}, nil
}

// ReplayDecision checks the fingerprint stored for an existing idempotency key.
// The database remains the authority for concurrent uniqueness.
func ReplayDecision(existingFingerprint, incomingFingerprint string) error {
	if len(existingFingerprint) != 64 || len(incomingFingerprint) != 64 {
		return ErrInvalidIntent
	}
	if existingFingerprint != incomingFingerprint {
		return ErrIdempotencyConflict
	}
	return nil
}
