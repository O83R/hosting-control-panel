package config

import "testing"

func TestPlatformDatabaseFromEnvDisabledByDefault(t *testing.T) {
	t.Setenv("HCP_PLATFORM_DB_ENABLED", "")
	t.Setenv("HCP_PLATFORM_DB_URL", "")
	cfg, err := PlatformDatabaseFromEnv()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Enabled || cfg.URL != "" {
		t.Fatalf("unexpected config: %#v", cfg)
	}
}

func TestPlatformDatabaseFromEnvEnabledRequiresURL(t *testing.T) {
	t.Setenv("HCP_PLATFORM_DB_ENABLED", "true")
	t.Setenv("HCP_PLATFORM_DB_URL", "")
	if _, err := PlatformDatabaseFromEnv(); err == nil {
		t.Fatal("expected missing URL error")
	}
}

func TestPlatformDatabaseFromEnvEnabled(t *testing.T) {
	t.Setenv("HCP_PLATFORM_DB_ENABLED", "true")
	t.Setenv("HCP_PLATFORM_DB_URL", "postgres://hcp.invalid/hcp")
	cfg, err := PlatformDatabaseFromEnv()
	if err != nil {
		t.Fatal(err)
	}
	if !cfg.Enabled || cfg.URL != "postgres://hcp.invalid/hcp" {
		t.Fatalf("unexpected config: %#v", cfg)
	}
}

func TestPlatformDatabaseFromEnvRejectsInvalidBoolean(t *testing.T) {
	t.Setenv("HCP_PLATFORM_DB_ENABLED", "sometimes")
	if _, err := PlatformDatabaseFromEnv(); err == nil {
		t.Fatal("expected invalid boolean error")
	}
}
