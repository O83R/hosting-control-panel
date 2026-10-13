package identity

import "testing"

func TestRoleAssignmentScope(t *testing.T) {
	valid := []RoleAssignment{
		{UserID: "u1", RoleCode: "platform_admin", Scope: ScopePlatform},
		{UserID: "u2", RoleCode: "tenant_admin", Scope: ScopeTenant, TenantID: "t1"},
	}
	for _, tc := range valid {
		if err := tc.Validate(); err != nil {
			t.Fatalf("valid assignment rejected: %v", err)
		}
	}

	invalid := []RoleAssignment{
		{UserID: "", RoleCode: "tenant_admin", Scope: ScopeTenant, TenantID: "t1"},
		{UserID: "u1", RoleCode: "", Scope: ScopePlatform},
		{UserID: "u1", RoleCode: "platform_admin", Scope: ScopePlatform, TenantID: "t1"},
		{UserID: "u1", RoleCode: "tenant_admin", Scope: ScopeTenant},
		{UserID: "u1", RoleCode: "tenant_admin", Scope: Scope("unknown"), TenantID: "t1"},
	}
	for i, tc := range invalid {
		if err := tc.Validate(); err == nil {
			t.Fatalf("invalid assignment %d accepted", i)
		}
	}
}

func TestTenantContext(t *testing.T) {
	if err := (TenantContext{Scope: ScopePlatform}).Validate(); err != nil {
		t.Fatal(err)
	}
	if err := (TenantContext{Scope: ScopeTenant, TenantID: "t1"}).Validate(); err != nil {
		t.Fatal(err)
	}
	if err := (TenantContext{Scope: ScopeTenant}).Validate(); err == nil {
		t.Fatal("tenant context without tenant id accepted")
	}
	if err := (TenantContext{Scope: ScopePlatform, TenantID: "t1"}).Validate(); err == nil {
		t.Fatal("platform context with tenant id accepted")
	}
}

func TestIdentityStatuses(t *testing.T) {
	if !UserActive.Valid() || !UserSuspended.Valid() || !UserDisabled.Valid() {
		t.Fatal("expected user statuses to be valid")
	}
	if UserStatus("deleted").Valid() {
		t.Fatal("unexpected user status accepted")
	}
	if !MembershipActive.Valid() || !MembershipSuspended.Valid() {
		t.Fatal("expected membership statuses to be valid")
	}
}
