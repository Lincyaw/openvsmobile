package api

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// searchResult represents a single content search match.
type searchResult struct {
	File        string `json:"file"`
	Line        int    `json:"line"`
	Content     string `json:"content"`
	LinesBefore string `json:"linesBefore"`
	LinesAfter  string `json:"linesAfter"`
}

// skipDirs contains directory names to skip during search.
var skipDirs = map[string]bool{
	".git":             true,
	"node_modules":     true,
	"vendor":           true,
	".dart_tool":       true,
	"build":            true,
	".flutter-plugins": true,
	".idea":            true,
	"__pycache__":      true,
}

// maxFileSize is the maximum file size to scan (1MB).
const maxFileSize = 1 << 20

// isBinary checks whether data contains null bytes in the first 512 bytes,
// indicating a binary file.
func isBinary(data []byte) bool {
	limit := 512
	if len(data) < limit {
		limit = len(data)
	}
	for i := 0; i < limit; i++ {
		if data[i] == 0 {
			return true
		}
	}
	return false
}

// handleSearch handles GET /api/search?q=<pattern>&path=<dir>&max=50.
func (s *Server) handleSearch(w http.ResponseWriter, r *http.Request) {
	query := r.URL.Query().Get("q")
	if query == "" {
		http.Error(w, "missing q parameter", http.StatusBadRequest)
		return
	}

	rawPath := r.URL.Query().Get("path")
	if rawPath == "" {
		rawPath = "/"
	}
	searchPath, err := sanitizePath(rawPath, true)
	if err != nil {
		http.Error(w, "invalid path: "+err.Error(), http.StatusBadRequest)
		return
	}

	maxResults := 50
	if m := r.URL.Query().Get("max"); m != "" {
		if v, err := strconv.Atoi(m); err == nil && v > 0 {
			maxResults = v
		}
	}

	lowerQuery := strings.ToLower(query)
	var results []searchResult

	_ = filepath.WalkDir(searchPath, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return nil
		}

		// Skip excluded directories.
		if d.IsDir() {
			if skipDirs[d.Name()] {
				return filepath.SkipDir
			}
			return nil
		}

		// Check result limit.
		if len(results) >= maxResults {
			return filepath.SkipAll
		}

		// Skip large files.
		info, err := d.Info()
		if err != nil {
			return nil
		}
		if info.Size() > maxFileSize {
			return nil
		}

		data, err := os.ReadFile(path)
		if err != nil {
			return nil
		}

		// Skip binary files.
		if isBinary(data) {
			return nil
		}

		lines := strings.Split(string(data), "\n")
		for i, line := range lines {
			if strings.Contains(strings.ToLower(line), lowerQuery) {
				var before, after string
				if i > 0 {
					before = lines[i-1]
				}
				if i < len(lines)-1 {
					after = lines[i+1]
				}

				results = append(results, searchResult{
					File:        path,
					Line:        i + 1, // 1-based
					Content:     line,
					LinesBefore: before,
					LinesAfter:  after,
				})

				if len(results) >= maxResults {
					return filepath.SkipAll
				}
			}
		}

		return nil
	})

	if results == nil {
		results = []searchResult{}
	}

	log.Printf("[Search] query=%q path=%s results=%d", query, searchPath, len(results))
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(results)
}
