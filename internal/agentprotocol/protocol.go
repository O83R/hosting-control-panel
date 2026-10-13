package agentprotocol

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"strings"
	"time"
)

const (
	Version               = "1"
	HeaderProtocolVersion = "X-HCP-Protocol-Version"
	HeaderTimestamp       = "X-HCP-Timestamp"
	HeaderNonce           = "X-HCP-Nonce"
	HeaderSignature       = "X-HCP-Signature"
)

type Capability struct {
	Code    string `json:"code"`
	Version string `json:"version"`
	Mode    string `json:"mode"`
}

type ActionRequest struct {
	RequestID string          `json:"request_id"`
	JobID     string          `json:"job_id,omitempty"`
	Action    string          `json:"action"`
	Input     json.RawMessage `json:"input,omitempty"`
}

type ActionReceipt struct {
	RequestID   string          `json:"request_id"`
	Action      string          `json:"action"`
	Status      string          `json:"status"`
	StartedAt   time.Time       `json:"started_at"`
	CompletedAt time.Time       `json:"completed_at"`
	Output      json.RawMessage `json:"output,omitempty"`
	ErrorCode   string          `json:"error_code,omitempty"`
}

func BodyHash(body []byte) string {
	sum := sha256.Sum256(body)
	return hex.EncodeToString(sum[:])
}

func Canonical(timestamp, nonce, method, path string, body []byte) string {
	return strings.Join([]string{
		timestamp,
		nonce,
		strings.ToUpper(method),
		path,
		BodyHash(body),
	}, "\n")
}

func Sign(secret []byte, timestamp, nonce, method, path string, body []byte) string {
	mac := hmac.New(sha256.New, secret)
	_, _ = mac.Write([]byte(Canonical(timestamp, nonce, method, path, body)))
	return hex.EncodeToString(mac.Sum(nil))
}

func Verify(secret []byte, timestamp, nonce, method, path string, body []byte, signature string) bool {
	provided, err := hex.DecodeString(signature)
	if err != nil {
		return false
	}
	expectedHex := Sign(secret, timestamp, nonce, method, path, body)
	expected, err := hex.DecodeString(expectedHex)
	if err != nil {
		return false
	}
	return hmac.Equal(provided, expected)
}
