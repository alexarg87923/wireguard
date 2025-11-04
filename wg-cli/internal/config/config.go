package config

import (
	"os"
	"path/filepath"

	"github.com/joho/godotenv"
)

var loaded bool

func Load() error {
	if loaded {
		return nil
	}

	wd, err := os.Getwd()
	if err != nil {
		return err
	}

	var envPath string
	for {
		potentialPath := filepath.Join(wd, ".env")
		if _, err := os.Stat(potentialPath); err == nil {
			envPath = potentialPath
			break
		}

		parent := filepath.Dir(wd)
		if parent == wd {
			break
		}
		wd = parent
	}

	if envPath == "" {
		loaded = true
		return nil
	}

	if err := godotenv.Load(envPath); err != nil {
		return err
	}

	loaded = true
	return nil
}

func Get(key, defaultValue string) string {
	if !loaded {
		_ = Load()
	}

	value := os.Getenv(key)
	if value == "" {
		return defaultValue
	}
	return value
}

func GetRequired(key string) (string, error) {
	if !loaded {
		if err := Load(); err != nil {
			return "", err
		}
	}

	value := os.Getenv(key)
	if value == "" {
		return "", &MissingEnvVarError{Key: key}
	}
	return value, nil
}

type MissingEnvVarError struct {
	Key string
}

func (e *MissingEnvVarError) Error() string {
	return "required environment variable not set: " + e.Key
}
