package hosting

import "testing"

func TestAccountTransitions(t *testing.T) {
	allowed := [][2]AccountStatus{
		{AccountPending, AccountActive},
		{AccountPending, AccountDisabled},
		{AccountActive, AccountSuspended},
		{AccountActive, AccountDisabled},
		{AccountSuspended, AccountActive},
		{AccountSuspended, AccountDisabled},
	}
	for _, pair := range allowed {
		if !CanTransitionAccount(pair[0], pair[1]) {
			t.Fatalf("expected transition %q -> %q", pair[0], pair[1])
		}
	}

	rejected := [][2]AccountStatus{
		{AccountPending, AccountSuspended},
		{AccountDisabled, AccountActive},
		{AccountActive, AccountPending},
		{AccountActive, AccountActive},
		{AccountStatus("bad"), AccountActive},
	}
	for _, pair := range rejected {
		if CanTransitionAccount(pair[0], pair[1]) {
			t.Fatalf("unexpected transition %q -> %q", pair[0], pair[1])
		}
	}
}

func TestPackageValidation(t *testing.T) {
	bandwidth := int64(2048)
	pkg := Package{
		ID:          "p1",
		TenantID:    "t1",
		Code:        "starter-01",
		DisplayName: "Starter",
		Status:      PackageActive,
		Limits: PackageLimits{
			MaxSites:     1,
			MaxDomains:   2,
			MaxDatabases: 1,
			StorageMB:    1024,
			BandwidthMB:  &bandwidth,
		},
	}
	if err := pkg.Validate(); err != nil {
		t.Fatalf("valid package rejected: %v", err)
	}

	pkg.Code = "BAD_CODE"
	if err := pkg.Validate(); err == nil {
		t.Fatal("invalid package code accepted")
	}
}

func TestAccountValidation(t *testing.T) {
	account := Account{
		ID:          "a1",
		TenantID:    "t1",
		PackageID:   "p1",
		OwnerUserID: "u1",
		Key:         "site-owner",
		DisplayName: "Site Owner",
		Status:      AccountPending,
		Version:     1,
	}
	if err := account.Validate(); err != nil {
		t.Fatalf("valid account rejected: %v", err)
	}

	account.Version = 0
	if err := account.Validate(); err == nil {
		t.Fatal("non-positive version accepted")
	}
}
