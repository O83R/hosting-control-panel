package networking

import "testing"

func TestDomainValidationAndTransitions(t *testing.T) {
	d := Domain{
		ID:                 "d1",
		TenantID:           "t1",
		SiteID:             "s1",
		FQDN:               "app.example.com",
		Status:             DomainPending,
		VerificationStatus: VerificationUnverified,
		DNSMode:            DNSExternal,
		SSLMode:            SSLAutomatic,
		Version:            1,
	}
	if err := d.Validate(); err != nil {
		t.Fatalf("valid domain rejected: %v", err)
	}

	d.FQDN = "App.Example.com"
	if err := d.Validate(); err == nil {
		t.Fatal("non-canonical fqdn accepted")
	}
	d.FQDN = "app.example.com"
	d.Status = DomainActive
	if err := d.Validate(); err == nil {
		t.Fatal("active unverified domain accepted")
	}
	d.VerificationStatus = VerificationVerified
	if err := d.Validate(); err != nil {
		t.Fatalf("active verified domain rejected: %v", err)
	}

	if !CanTransitionVerification(VerificationUnverified, VerificationPending) ||
		!CanTransitionVerification(VerificationPending, VerificationVerified) ||
		CanTransitionVerification(VerificationVerified, VerificationPending) {
		t.Fatal("verification transition contract mismatch")
	}
	if !CanTransitionDomain(DomainPending, DomainActive) ||
		!CanTransitionDomain(DomainDisabled, DomainActive) ||
		CanTransitionDomain(DomainActive, DomainPending) {
		t.Fatal("domain transition contract mismatch")
	}
}

func TestProxyRouteValidationAndTransitions(t *testing.T) {
	r := ProxyRoute{
		ID:           "r1",
		TenantID:     "t1",
		DomainID:     "d1",
		PathPrefix:   "/",
		TargetScheme: "http",
		TargetHost:   "backend",
		TargetPort:   8080,
		Status:       ProxyPending,
		Version:      1,
	}
	if err := r.Validate(); err != nil {
		t.Fatalf("valid route rejected: %v", err)
	}

	r.TargetHost = "http://backend"
	if err := r.Validate(); err == nil {
		t.Fatal("URL accepted as target host")
	}

	if !CanTransitionProxyRoute(ProxyPending, ProxyActive) ||
		!CanTransitionProxyRoute(ProxyDisabled, ProxyActive) ||
		CanTransitionProxyRoute(ProxyActive, ProxyPending) {
		t.Fatal("proxy transition contract mismatch")
	}
}
