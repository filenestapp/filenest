package config

import (
	"fmt"
	"os"
	"strings"
)

const (
	defaultAddress         = "127.0.0.1:8080"
	defaultDataFile        = "data/releases.json"
	defaultOMPManifestFile = "data/omp-agent-manifest.json"
)

type Config struct {
	Address         string
	DataFile        string
	OMPManifestFile string
	AdminToken      string
	AllowedOrigins  []string
}

func Load() (Config, error) {
	cfg := Config{
		Address:         envOrDefault("FILENEST_UPDATE_ADDR", defaultAddress),
		DataFile:        envOrDefault("FILENEST_UPDATE_DATA_FILE", defaultDataFile),
		OMPManifestFile: envOrDefault("FILENEST_OMP_MANIFEST_FILE", defaultOMPManifestFile),
		AdminToken:      strings.TrimSpace(os.Getenv("FILENEST_UPDATE_ADMIN_TOKEN")),
	}

	if rawOrigins := strings.TrimSpace(os.Getenv("FILENEST_UPDATE_ALLOWED_ORIGINS")); rawOrigins != "" {
		for _, origin := range strings.Split(rawOrigins, ",") {
			origin = strings.TrimSpace(origin)
			if origin != "" {
				cfg.AllowedOrigins = append(cfg.AllowedOrigins, origin)
			}
		}
	}

	if cfg.Address == "" {
		return Config{}, fmt.Errorf("FILENEST_UPDATE_ADDR must not be empty")
	}
	if cfg.DataFile == "" {
		return Config{}, fmt.Errorf("FILENEST_UPDATE_DATA_FILE must not be empty")
	}
	if cfg.OMPManifestFile == "" {
		return Config{}, fmt.Errorf("FILENEST_OMP_MANIFEST_FILE must not be empty")
	}

	return cfg, nil
}

func envOrDefault(key, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(key)); value != "" {
		return value
	}
	return fallback
}
