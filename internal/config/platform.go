package config

import (
	"errors"
	"os"
	"strconv"
	"strings"
)

// PlatformDatabase describes the future HCP platform-state PostgreSQL connection.
// The current production runtime does not enable this configuration yet.
type PlatformDatabase struct {
	Enabled bool
	URL     string
}

func PlatformDatabaseFromEnv() (PlatformDatabase, error) {
	var cfg PlatformDatabase

	rawEnabled := strings.TrimSpace(os.Getenv("HCP_PLATFORM_DB_ENABLED"))
	if rawEnabled != "" {
		v, err := strconv.ParseBool(rawEnabled)
		if err != nil {
			return cfg, errors.New("HCP_PLATFORM_DB_ENABLED must be a boolean")
		}
		cfg.Enabled = v
	}

	cfg.URL = strings.TrimSpace(os.Getenv("HCP_PLATFORM_DB_URL"))
	if cfg.Enabled && cfg.URL == "" {
		return cfg, errors.New("HCP_PLATFORM_DB_URL is required when platform database is enabled")
	}
	return cfg, nil
}
