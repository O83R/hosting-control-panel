package hosting

import "testing"

func TestSiteTransitions(t *testing.T) {
	allowed := [][2]SiteStatus{
		{SitePending, SiteActive},
		{SitePending, SiteDisabled},
		{SiteActive, SiteSuspended},
		{SiteActive, SiteDisabled},
		{SiteSuspended, SiteActive},
		{SiteSuspended, SiteDisabled},
	}
	for _, pair := range allowed {
		if !CanTransitionSite(pair[0], pair[1]) {
			t.Fatalf("expected site transition %q -> %q", pair[0], pair[1])
		}
	}
	if CanTransitionSite(SiteDisabled, SiteActive) {
		t.Fatal("disabled site was allowed to reactivate")
	}
}

func TestSiteValidation(t *testing.T) {
	site := Site{
		ID:          "s1",
		TenantID:    "t1",
		AccountID:   "a1",
		Key:         "portal-app",
		DisplayName: "Portal",
		Kind:        SiteContainerized,
		Origin:      SiteManaged,
		Status:      SitePending,
		Version:     1,
	}
	if err := site.Validate(); err != nil {
		t.Fatalf("valid site rejected: %v", err)
	}

	site.Origin = SiteAdopted
	if err := site.Validate(); err == nil {
		t.Fatal("adopted site without source reference accepted")
	}
	site.SourceRef = "project:portal"
	if err := site.Validate(); err != nil {
		t.Fatalf("valid adopted site rejected: %v", err)
	}
}

func TestAdoptionTransitionsAndValidation(t *testing.T) {
	if !CanTransitionAdoption(AdoptionDetected, AdoptionReviewed) ||
		!CanTransitionAdoption(AdoptionReviewed, AdoptionAdopted) {
		t.Fatal("expected adoption transitions rejected")
	}
	if CanTransitionAdoption(AdoptionAdopted, AdoptionReviewed) {
		t.Fatal("terminal adoption transitioned backwards")
	}

	candidate := AdoptionCandidate{
		ID:          "c1",
		TenantID:    "t1",
		NodeID:      "n1",
		ExternalRef: "compose:portal",
		DisplayName: "Portal",
		RuntimeKind: SiteContainerized,
		Fingerprint: "sha256:example",
		Status:      AdoptionDetected,
	}
	if err := candidate.Validate(); err != nil {
		t.Fatalf("valid candidate rejected: %v", err)
	}

	candidate.Status = AdoptionAdopted
	if err := candidate.Validate(); err == nil {
		t.Fatal("adopted candidate without site id accepted")
	}
}
