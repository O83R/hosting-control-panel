package hosting

import (
	"errors"
	"strings"
)

type SiteKind string

const (
	SiteContainerized SiteKind = "containerized"
	SiteStatic        SiteKind = "static"
	SiteExternal      SiteKind = "external"
)

func (k SiteKind) Valid() bool {
	switch k {
	case SiteContainerized, SiteStatic, SiteExternal:
		return true
	default:
		return false
	}
}

type SiteOrigin string

const (
	SiteManaged SiteOrigin = "managed"
	SiteAdopted SiteOrigin = "adopted"
)

func (o SiteOrigin) Valid() bool {
	return o == SiteManaged || o == SiteAdopted
}

type SiteStatus string

const (
	SitePending   SiteStatus = "pending"
	SiteActive    SiteStatus = "active"
	SiteSuspended SiteStatus = "suspended"
	SiteDisabled  SiteStatus = "disabled"
)

func (s SiteStatus) Valid() bool {
	switch s {
	case SitePending, SiteActive, SiteSuspended, SiteDisabled:
		return true
	default:
		return false
	}
}

func CanTransitionSite(from, to SiteStatus) bool {
	if !from.Valid() || !to.Valid() || from == to {
		return false
	}
	switch from {
	case SitePending:
		return to == SiteActive || to == SiteDisabled
	case SiteActive:
		return to == SiteSuspended || to == SiteDisabled
	case SiteSuspended:
		return to == SiteActive || to == SiteDisabled
	default:
		return false
	}
}

type Site struct {
	ID          string
	TenantID    string
	AccountID   string
	NodeID      string
	Key         string
	DisplayName string
	Kind        SiteKind
	Origin      SiteOrigin
	Status      SiteStatus
	SourceRef   string
	Version     int64
}

func (s Site) Validate() error {
	if strings.TrimSpace(s.ID) == "" ||
		strings.TrimSpace(s.TenantID) == "" ||
		strings.TrimSpace(s.AccountID) == "" {
		return errors.New("site identity fields are required")
	}
	if !resourceCodePattern.MatchString(s.Key) {
		return errors.New("site key is invalid")
	}
	if strings.TrimSpace(s.DisplayName) == "" {
		return errors.New("site display name is required")
	}
	if !s.Kind.Valid() || !s.Origin.Valid() || !s.Status.Valid() {
		return errors.New("site type or status is invalid")
	}
	if s.Origin == SiteAdopted && strings.TrimSpace(s.SourceRef) == "" {
		return errors.New("adopted site requires source reference")
	}
	if s.Version < 1 {
		return errors.New("site version must be positive")
	}
	return nil
}

type AdoptionStatus string

const (
	AdoptionDetected AdoptionStatus = "detected"
	AdoptionReviewed AdoptionStatus = "reviewed"
	AdoptionAdopted  AdoptionStatus = "adopted"
	AdoptionRejected AdoptionStatus = "rejected"
)

func (s AdoptionStatus) Valid() bool {
	switch s {
	case AdoptionDetected, AdoptionReviewed, AdoptionAdopted, AdoptionRejected:
		return true
	default:
		return false
	}
}

func CanTransitionAdoption(from, to AdoptionStatus) bool {
	if !from.Valid() || !to.Valid() || from == to {
		return false
	}
	switch from {
	case AdoptionDetected:
		return to == AdoptionReviewed || to == AdoptionRejected
	case AdoptionReviewed:
		return to == AdoptionAdopted || to == AdoptionRejected
	default:
		return false
	}
}

type AdoptionCandidate struct {
	ID            string
	TenantID      string
	NodeID        string
	ExternalRef   string
	DisplayName   string
	RuntimeKind   SiteKind
	Fingerprint   string
	Status        AdoptionStatus
	AdoptedSiteID string
}

func (c AdoptionCandidate) Validate() error {
	if strings.TrimSpace(c.ID) == "" ||
		strings.TrimSpace(c.TenantID) == "" ||
		strings.TrimSpace(c.NodeID) == "" ||
		strings.TrimSpace(c.ExternalRef) == "" ||
		strings.TrimSpace(c.Fingerprint) == "" {
		return errors.New("adoption identity fields are required")
	}
	if strings.TrimSpace(c.DisplayName) == "" {
		return errors.New("adoption display name is required")
	}
	if !c.RuntimeKind.Valid() || !c.Status.Valid() {
		return errors.New("adoption type or status is invalid")
	}
	if c.Status == AdoptionAdopted && strings.TrimSpace(c.AdoptedSiteID) == "" {
		return errors.New("adopted candidate requires site id")
	}
	return nil
}
