package platform

import "testing"

func TestTenantValidation(t *testing.T) {
	valid := Tenant{
		ID:          "11111111-1111-1111-1111-111111111111",
		Slug:        "acme-hosting",
		DisplayName: "ACME Hosting",
		Status:      TenantActive,
	}
	if err := valid.Validate(); err != nil {
		t.Fatalf("valid tenant rejected: %v", err)
	}

	cases := []Tenant{
		{ID: "", Slug: "acme-hosting", DisplayName: "ACME", Status: TenantActive},
		{ID: "id", Slug: "Bad_Slug", DisplayName: "ACME", Status: TenantActive},
		{ID: "id", Slug: "acme-hosting", DisplayName: " ", Status: TenantActive},
		{ID: "id", Slug: "acme-hosting", DisplayName: "ACME", Status: TenantStatus("deleted")},
	}
	for i, tc := range cases {
		if err := tc.Validate(); err == nil {
			t.Fatalf("invalid tenant case %d was accepted", i)
		}
	}
}

func TestNodeValidation(t *testing.T) {
	valid := Node{
		ID:     "22222222-2222-2222-2222-222222222222",
		Name:   "apps-prod-01",
		Status: NodeOnline,
	}
	if err := valid.Validate(); err != nil {
		t.Fatalf("valid node rejected: %v", err)
	}

	if err := (Node{ID: "id", Name: "", Status: NodeOnline}).Validate(); err == nil {
		t.Fatal("node without name was accepted")
	}
	if err := (Node{ID: "id", Name: "node", Status: NodeStatus("lost")}).Validate(); err == nil {
		t.Fatal("node with invalid status was accepted")
	}
}

func TestJobValidation(t *testing.T) {
	valid := Job{
		ID:             "33333333-3333-3333-3333-333333333333",
		Kind:           "node.inspect",
		Status:         JobQueued,
		ResourceType:   "node",
		ResourceID:     "22222222-2222-2222-2222-222222222222",
		IdempotencyKey: "request-1",
		RequestedBy:    "ci",
		Version:        1,
	}
	if err := valid.Validate(); err != nil {
		t.Fatalf("valid job rejected: %v", err)
	}

	bad := valid
	bad.ResourceID = ""
	if err := bad.Validate(); err == nil {
		t.Fatal("half-specified resource scope was accepted")
	}

	bad = valid
	bad.Version = 0
	if err := bad.Validate(); err == nil {
		t.Fatal("non-positive job version was accepted")
	}
}
