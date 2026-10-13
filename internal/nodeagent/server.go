package nodeagent

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"hosting-control-panel/internal/agentprotocol"
)

const maxActionBody = 64 << 10

var noncePattern = regexp.MustCompile(`^[A-Za-z0-9_-]{16,128}$`)

var (
	errAuthentication = errors.New("authentication failed")
	errReplay         = errors.New("replayed request")
)

type Server struct {
	secret       []byte
	now          func() time.Time
	allowedSkew  time.Duration
	mu           sync.Mutex
	seenNonces   map[string]time.Time
	capabilities []agentprotocol.Capability
}

func New(secret []byte) (*Server, error) {
	if len(secret) < 32 {
		return nil, errors.New("node agent secret must be at least 32 bytes")
	}
	return &Server{
		secret:      append([]byte(nil), secret...),
		now:         func() time.Time { return time.Now().UTC() },
		allowedSkew: 2 * time.Minute,
		seenNonces:  make(map[string]time.Time),
		capabilities: []agentprotocol.Capability{
			{Code: "agent.ping", Version: "1", Mode: "read_only"},
		},
	}, nil
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.handleHealth)
	mux.HandleFunc("GET /v1/capabilities", s.handleCapabilities)
	mux.HandleFunc("POST /v1/actions/agent.ping", s.handlePing)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		mux.ServeHTTP(w, r)
	})
}

func (s *Server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"status":           "ok",
		"protocol_version": agentprotocol.Version,
	})
}

func (s *Server) handleCapabilities(w http.ResponseWriter, r *http.Request) {
	if err := s.authorize(r, nil); err != nil {
		writeAuthError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"protocol_version": agentprotocol.Version,
		"capabilities":     s.capabilities,
	})
}

func (s *Server) handlePing(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxActionBody))
	if err != nil {
		writeJSON(w, http.StatusRequestEntityTooLarge, map[string]string{"error": "request body too large"})
		return
	}
	if err := s.authorize(r, body); err != nil {
		writeAuthError(w, err)
		return
	}

	var in agentprotocol.ActionRequest
	if err := json.Unmarshal(body, &in); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request"})
		return
	}
	if in.Action != "agent.ping" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "action mismatch"})
		return
	}
	if strings.TrimSpace(in.RequestID) == "" || len(in.RequestID) > 128 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request_id"})
		return
	}
	if len(in.JobID) > 128 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid job_id"})
		return
	}

	started := s.now()
	output, _ := json.Marshal(map[string]any{
		"pong":             true,
		"protocol_version": agentprotocol.Version,
	})
	receipt := agentprotocol.ActionReceipt{
		RequestID:   in.RequestID,
		Action:      in.Action,
		Status:      "succeeded",
		StartedAt:   started,
		CompletedAt: s.now(),
		Output:      output,
	}
	writeJSON(w, http.StatusOK, receipt)
}

func (s *Server) authorize(r *http.Request, body []byte) error {
	if r.Header.Get(agentprotocol.HeaderProtocolVersion) != agentprotocol.Version {
		return errAuthentication
	}

	rawTimestamp := r.Header.Get(agentprotocol.HeaderTimestamp)
	nonce := r.Header.Get(agentprotocol.HeaderNonce)
	signature := r.Header.Get(agentprotocol.HeaderSignature)
	if rawTimestamp == "" || !noncePattern.MatchString(nonce) || signature == "" {
		return errAuthentication
	}

	unixSeconds, err := strconv.ParseInt(rawTimestamp, 10, 64)
	if err != nil {
		return errAuthentication
	}
	requestTime := time.Unix(unixSeconds, 0).UTC()
	now := s.now()
	delta := now.Sub(requestTime)
	if delta < 0 {
		delta = -delta
	}
	if delta > s.allowedSkew {
		return errAuthentication
	}

	if !agentprotocol.Verify(
		s.secret,
		rawTimestamp,
		nonce,
		r.Method,
		r.URL.EscapedPath(),
		body,
		signature,
	) {
		return errAuthentication
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	for value, seenAt := range s.seenNonces {
		if now.Sub(seenAt) > 2*s.allowedSkew {
			delete(s.seenNonces, value)
		}
	}
	if _, exists := s.seenNonces[nonce]; exists {
		return errReplay
	}
	s.seenNonces[nonce] = now
	return nil
}

func writeAuthError(w http.ResponseWriter, err error) {
	if errors.Is(err, errReplay) {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "request replay rejected"})
		return
	}
	writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "authentication required"})
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}
