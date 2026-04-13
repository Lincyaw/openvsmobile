package api

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// sanitizePath validates and cleans a user-supplied path to prevent path traversal
// and command injection attacks. It resolves the path to an absolute path, cleans it,
// and rejects paths containing ".." components. If checkDir is true, it also verifies
// that the path exists and is a directory.
func sanitizePath(raw string, checkDir bool) (string, error) {
	if raw == "" {
		return "", fmt.Errorf("path must not be empty")
	}

	abs, err := filepath.Abs(raw)
	if err != nil {
		return "", fmt.Errorf("invalid path: %w", err)
	}

	cleaned := filepath.Clean(abs)

	// Reject any path that still contains ".." after cleaning.
	// This guards against edge cases in path resolution.
	for _, part := range strings.Split(cleaned, string(filepath.Separator)) {
		if part == ".." {
			return "", fmt.Errorf("path must not contain '..' components")
		}
	}

	if checkDir {
		info, err := os.Stat(cleaned)
		if err != nil {
			return "", fmt.Errorf("path does not exist: %w", err)
		}
		if !info.IsDir() {
			return "", fmt.Errorf("path is not a directory: %s", cleaned)
		}
	}

	return cleaned, nil
}

// sanitizeRelativePath validates that a path is relative and does not escape the
// given base directory via ".." components. It returns the cleaned relative path.
func sanitizeRelativePath(raw string, baseDir string) (string, error) {
	if raw == "" {
		return "", nil // Empty relative path is allowed (means "use baseDir itself").
	}

	// Reject absolute paths.
	if filepath.IsAbs(raw) {
		return "", fmt.Errorf("path must be relative, got absolute: %s", raw)
	}

	cleaned := filepath.Clean(raw)

	// Reject paths that escape the base directory.
	if strings.HasPrefix(cleaned, "..") {
		return "", fmt.Errorf("path must not escape base directory via '..'")
	}

	return cleaned, nil
}
