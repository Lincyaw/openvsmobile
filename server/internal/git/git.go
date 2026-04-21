package git

import (
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
)

// Git provides methods to run git commands via os/exec.
type Git struct {
	workDir string
}

// StatusEntry represents a single file's git status.
type StatusEntry struct {
	Path     string `json:"path"`
	Status   string `json:"status"` // "modified", "added", "deleted", "renamed", "untracked"
	Staged   bool   `json:"staged"`
	WorkTree string `json:"workTree"` // Single-char status code
	Index    string `json:"index"`    // Single-char status code
}

// LogEntry represents a single git log entry.
type LogEntry struct {
	Hash    string `json:"hash"`
	Author  string `json:"author"`
	Date    string `json:"date"`
	Message string `json:"message"`
}

// BranchInfo contains current branch and list of all branches.
type BranchInfo struct {
	Current  string   `json:"current"`
	Branches []string `json:"branches"`
}

// NewGit creates a new Git instance with the given default working directory.
func NewGit(workDir string) *Git {
	return &Git{workDir: workDir}
}

// resolveDir returns path if non-empty, otherwise the default workDir.
func (g *Git) resolveDir(path string) string {
	if path != "" {
		return path
	}
	return g.workDir
}

// run executes a git command and returns its stdout.
func (g *Git) run(args ...string) (string, error) {
	cmd := exec.Command("git", args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("git %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return string(out), nil
}

// mapStatusCode maps a single git status character to a human-readable string.
func mapStatusCode(c byte) string {
	switch c {
	case 'M':
		return "modified"
	case 'A':
		return "added"
	case 'D':
		return "deleted"
	case 'R':
		return "renamed"
	case '?':
		return "untracked"
	default:
		return "unknown"
	}
}

// Status runs `git status --porcelain=v1` and parses the output.
func (g *Git) Status(path string) ([]StatusEntry, error) {
	dir := g.resolveDir(path)
	out, err := g.run("-C", dir, "status", "--porcelain=v1")
	if err != nil {
		return nil, err
	}

	var entries []StatusEntry
	for _, line := range strings.Split(out, "\n") {
		if len(line) < 3 {
			continue
		}
		indexCode := line[0]
		workTreeCode := line[1]
		filePath := strings.TrimSpace(line[3:])

		// Determine the primary status and whether it is staged.
		var status string
		var staged bool
		if indexCode != ' ' && indexCode != '?' {
			status = mapStatusCode(indexCode)
			staged = true
		} else {
			status = mapStatusCode(workTreeCode)
			staged = false
		}

		entries = append(entries, StatusEntry{
			Path:     filePath,
			Status:   status,
			Staged:   staged,
			WorkTree: string(workTreeCode),
			Index:    string(indexCode),
		})
	}
	return entries, nil
}

// Diff runs `git diff` and returns the diff output as a string.
func (g *Git) Diff(path string, filePath string, staged bool) (string, error) {
	dir := g.resolveDir(path)
	args := []string{"-C", dir, "diff"}
	if staged {
		args = append(args, "--cached")
	}
	if filePath != "" {
		args = append(args, "--", filePath)
	}
	out, err := g.run(args...)
	if err != nil {
		return "", err
	}
	if strings.TrimSpace(out) != "" || filePath == "" || staged {
		return out, nil
	}
	return g.untrackedDiff(dir, filePath)
}

func (g *Git) untrackedDiff(dir, filePath string) (string, error) {
	status, err := g.run("-C", dir, "status", "--porcelain=v1", "--", filePath)
	if err != nil {
		return "", err
	}
	if !strings.HasPrefix(strings.TrimSpace(status), "?? ") {
		return "", nil
	}

	absolutePath := filePath
	if !strings.HasPrefix(filePath, dir) {
		absolutePath = dir + string(os.PathSeparator) + filePath
	}

	cmd := exec.Command("git", "-C", dir, "diff", "--no-index", "--", "/dev/null", absolutePath)
	out, err := cmd.CombinedOutput()
	if err == nil {
		return string(out), nil
	}
	if exitErr, ok := err.(*exec.ExitError); ok && exitErr.ExitCode() == 1 {
		return string(out), nil
	}
	return "", fmt.Errorf("git diff --no-index: %w: %s", err, strings.TrimSpace(string(out)))
}

// Log runs `git log` and parses the output into LogEntry slices.
func (g *Git) Log(path string, count int) ([]LogEntry, error) {
	dir := g.resolveDir(path)
	format := "%H%n%an%n%aI%n%s"
	out, err := g.run("-C", dir, "log", "--format="+format, "-n", strconv.Itoa(count))
	if err != nil {
		return nil, err
	}

	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) == 0 || (len(lines) == 1 && lines[0] == "") {
		return nil, nil
	}

	var entries []LogEntry
	for i := 0; i+3 < len(lines); i += 4 {
		entries = append(entries, LogEntry{
			Hash:    lines[i],
			Author:  lines[i+1],
			Date:    lines[i+2],
			Message: lines[i+3],
		})
	}
	return entries, nil
}

// BranchInfo runs `git branch` and parses the output.
func (g *Git) BranchInfo(path string) (*BranchInfo, error) {
	dir := g.resolveDir(path)
	out, err := g.run("-C", dir, "branch")
	if err != nil {
		return nil, err
	}

	info := &BranchInfo{}
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimRight(line, "\r")
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "* ") {
			branch := strings.TrimPrefix(line, "* ")
			info.Current = branch
			info.Branches = append(info.Branches, branch)
		} else {
			info.Branches = append(info.Branches, strings.TrimSpace(line))
		}
	}
	return info, nil
}

// Show runs `git show <ref>:<filePath>` and returns the file content.
func (g *Git) Show(path string, ref string, filePath string) (string, error) {
	dir := g.resolveDir(path)
	return g.run("-C", dir, "show", ref+":"+filePath)
}

// ShowCommit runs `git show <hash>` and returns the commit diff/output.
func (g *Git) ShowCommit(path string, hash string) (string, error) {
	dir := g.resolveDir(path)
	return g.run("-C", dir, "show", hash)
}

// Checkout runs `git checkout <branch>`.
func (g *Git) Checkout(path string, branch string) error {
	dir := g.resolveDir(path)
	_, err := g.run("-C", dir, "checkout", branch)
	return err
}

// Stage runs `git add <file>` to stage a file.
func (g *Git) Stage(path string, file string) error {
	dir := g.resolveDir(path)
	_, err := g.run("-C", dir, "add", file)
	return err
}

// Unstage runs `git reset HEAD -- <file>` to unstage a file.
func (g *Git) Unstage(path string, file string) error {
	dir := g.resolveDir(path)
	_, err := g.run("-C", dir, "reset", "HEAD", "--", file)
	return err
}

// Commit runs `git commit -m <message>`.
func (g *Git) Commit(path string, message string) error {
	if message == "" {
		return fmt.Errorf("commit message must not be empty")
	}
	dir := g.resolveDir(path)
	_, err := g.run("-C", dir, "commit", "-m", message)
	return err
}
