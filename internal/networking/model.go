package networking

import (
	"errors"
	"net"
	"strings"
)

type DomainStatus string

const (
	DomainPending  DomainStatus = "pending"
	DomainActive   DomainStatus = "active"
	DomainDisabled DomainStatus = "disabled"
)

func (s DomainStatus) Valid() bool {
	switch s {
	case DomainPending, DomainActive, DomainDisabled:
		return true
	default:
		return false
	}
}

type VerificationStatus string

const (
	VerificationUnverified VerificationStatus = "unverified"
	VerificationPending    VerificationStatus = "pending"
	VerificationVerified   VerificationStatus = "verified"
	VerificationFailed     VerificationStatus = "failed"
)

func (s VerificationStatus) Valid() bool {
	switch s {
	case VerificationUnverified, VerificationPending, VerificationVerified, VerificationFailed:
		return true
	default:
		return false
	}
}

func CanTransitionVerification(from, to VerificationStatus) bool {
	if !from.Valid() || !to.Valid() || from == to {
		return false
	}
	switch from {
	case VerificationUnverified:
		return to == VerificationPending
	case VerificationPending:
		return to == VerificationVerified || to == VerificationFailed
	case VerificationFailed:
		return to == VerificationPending
	default:
		return false
	}
}

func CanTransitionDomain(from, to DomainStatus) bool {
	if !from.Valid() || !to.Valid() || from == to {
		return false
	}
	switch from {
	case DomainPending:
		return to == DomainActive || to == DomainDisabled
	case DomainActive:
		return to == DomainDisabled
	case DomainDisabled:
		return to == DomainActive
	default:
		return false
	}
}

type DNSMode string

const (
	DNSExternal DNSMode = "external"
	DNSManaged  DNSMode = "managed"
)

func (m DNSMode) Valid() bool {
	return m == DNSExternal || m == DNSManaged
}

type SSLMode string

const (
	SSLOff       SSLMode = "off"
	SSLAutomatic SSLMode = "automatic"
	SSLManual    SSLMode = "manual"
)

func (m SSLMode) Valid() bool {
	switch m {
	case SSLOff, SSLAutomatic, SSLManual:
		return true
	default:
		return false
	}
}

type Domain struct {
	ID                 string
	TenantID           string
	SiteID             string
	FQDN               string
	Status             DomainStatus
	VerificationStatus VerificationStatus
	DNSMode            DNSMode
	SSLMode            SSLMode
	Version            int64
}

func (d Domain) Validate() error {
	if strings.TrimSpace(d.ID) == "" ||
		strings.TrimSpace(d.TenantID) == "" ||
		strings.TrimSpace(d.SiteID) == "" {
		return errors.New("domain identity fields are required")
	}
	if err := validateFQDN(d.FQDN); err != nil {
		return err
	}
	if !d.Status.Valid() || !d.VerificationStatus.Valid() || !d.DNSMode.Valid() || !d.SSLMode.Valid() {
		return errors.New("domain mode or status is invalid")
	}
	if d.Status == DomainActive && d.VerificationStatus != VerificationVerified {
		return errors.New("active domain must be verified")
	}
	if d.Version < 1 {
		return errors.New("domain version must be positive")
	}
	return nil
}

func validateFQDN(value string) error {
	if value == "" || value != strings.ToLower(value) || len(value) > 253 || !strings.Contains(value, ".") {
		return errors.New("fqdn must be canonical lowercase hostname")
	}
	if strings.HasSuffix(value, ".") || strings.ContainsAny(value, "/:@?# \t\r\n") {
		return errors.New("fqdn contains invalid characters")
	}
	labels := strings.Split(value, ".")
	for _, label := range labels {
		if len(label) < 1 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return errors.New("fqdn label is invalid")
		}
		for _, r := range label {
			if (r < 'a' || r > 'z') && (r < '0' || r > '9') && r != '-' {
				return errors.New("fqdn label is invalid")
			}
		}
	}
	return nil
}

type ProxyRouteStatus string

const (
	ProxyPending  ProxyRouteStatus = "pending"
	ProxyActive   ProxyRouteStatus = "active"
	ProxyDisabled ProxyRouteStatus = "disabled"
)

func (s ProxyRouteStatus) Valid() bool {
	switch s {
	case ProxyPending, ProxyActive, ProxyDisabled:
		return true
	default:
		return false
	}
}

func CanTransitionProxyRoute(from, to ProxyRouteStatus) bool {
	if !from.Valid() || !to.Valid() || from == to {
		return false
	}
	switch from {
	case ProxyPending:
		return to == ProxyActive || to == ProxyDisabled
	case ProxyActive:
		return to == ProxyDisabled
	case ProxyDisabled:
		return to == ProxyActive
	default:
		return false
	}
}

type ProxyRoute struct {
	ID           string
	TenantID     string
	DomainID     string
	PathPrefix   string
	TargetScheme string
	TargetHost   string
	TargetPort   int
	Status       ProxyRouteStatus
	Version      int64
}

func (r ProxyRoute) Validate() error {
	if strings.TrimSpace(r.ID) == "" ||
		strings.TrimSpace(r.TenantID) == "" ||
		strings.TrimSpace(r.DomainID) == "" {
		return errors.New("proxy route identity fields are required")
	}
	if !strings.HasPrefix(r.PathPrefix, "/") ||
		strings.ContainsAny(r.PathPrefix, "?#\r\n") {
		return errors.New("proxy path prefix is invalid")
	}
	if r.TargetScheme != "http" && r.TargetScheme != "https" {
		return errors.New("proxy target scheme is invalid")
	}
	if strings.TrimSpace(r.TargetHost) == "" ||
		strings.Contains(r.TargetHost, "://") ||
		strings.ContainsAny(r.TargetHost, "/?# \t\r\n") {
		return errors.New("proxy target host is invalid")
	}
	if ip := net.ParseIP(strings.Trim(r.TargetHost, "[]")); ip == nil {
		for _, label := range strings.Split(r.TargetHost, ".") {
			if label == "" {
				return errors.New("proxy target host is invalid")
			}
		}
	}
	if r.TargetPort < 1 || r.TargetPort > 65535 {
		return errors.New("proxy target port is invalid")
	}
	if !r.Status.Valid() {
		return errors.New("proxy route status is invalid")
	}
	if r.Version < 1 {
		return errors.New("proxy route version must be positive")
	}
	return nil
}
