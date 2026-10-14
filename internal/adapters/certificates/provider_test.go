package certificates

import "testing"

func TestACMEPlanOrder(t *testing.T) {
	intent, err := (ACME{}).PlanOrder(
		"app.example.com",
		ChallengeDNS01,
		"secretref://acme/contact",
		"secretref://acme/key",
	)
	if err != nil {
		t.Fatal(err)
	}
	if intent.Provider != "acme" || intent.Domain != "app.example.com" || intent.ChallengeType != ChallengeDNS01 {
		t.Fatalf("unexpected order intent: %#v", intent)
	}

	if _, err := (ACME{}).PlanOrder("app.example.com", ChallengeType("tls-alpn-01"), "c", "k"); err == nil {
		t.Fatal("unsupported challenge accepted")
	}
}
