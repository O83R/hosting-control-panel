package platform

import (
	"errors"
	"regexp"
	"strings"
)

var tenantSlugPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$`)

type Tenant struct {
	ID          string
	Slug        string
	DisplayName string
	Status      TenantStatus
}

func (t Tenant) Validate() error {
	if strings.TrimSpace(t.ID) == "" {
		return errors.New("tenant id is required")
	}
	if !tenantSlugPattern.MatchString(t.Slug) {
		return errors.New("tenant slug is invalid")
	}
	if strings.TrimSpace(t.DisplayName) == "" {
		return errors.New("tenant display name is required")
	}
	if !t.Status.Valid() {
		return errors.New("tenant status is invalid")
	}
	return nil
}

type Node struct {
	ID            string
	Name          string
	Status        NodeStatus
	AgentEndpoint string
	AgentVersion  string
}

func (n Node) Validate() error {
	if strings.TrimSpace(n.ID) == "" {
		return errors.New("node id is required")
	}
	if strings.TrimSpace(n.Name) == "" {
		return errors.New("node name is required")
	}
	if !n.Status.Valid() {
		return errors.New("node status is invalid")
	}
	return nil
}

type Job struct {
	ID             string
	TenantID       string
	Kind           string
	Status         JobStatus
	ResourceType   string
	ResourceID     string
	IdempotencyKey string
	RequestedBy    string
	Version        int64
}

func (j Job) Validate() error {
	if strings.TrimSpace(j.ID) == "" {
		return errors.New("job id is required")
	}
	if strings.TrimSpace(j.Kind) == "" {
		return errors.New("job kind is required")
	}
	if !j.Status.Valid() {
		return errors.New("job status is invalid")
	}
	if strings.TrimSpace(j.RequestedBy) == "" {
		return errors.New("job requested_by is required")
	}
	if len(j.IdempotencyKey) > 200 {
		return errors.New("job idempotency key is too long")
	}
	if (j.ResourceType == "") != (j.ResourceID == "") {
		return errors.New("job resource type and id must be set together")
	}
	if j.Version < 1 {
		return errors.New("job version must be positive")
	}
	return nil
}
