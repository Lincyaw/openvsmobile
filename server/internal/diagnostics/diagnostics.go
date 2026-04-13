package diagnostics

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Severity levels for diagnostics.
const (
	SeverityError   = "error"
	SeverityWarning = "warning"
	SeverityInfo    = "info"
	SeverityHint    = "hint"
)

// Diagnostic represents a single diagnostic finding.
type Diagnostic struct {
	FilePath string `json:"filePath"`
	Line     int    `json:"line"`
	Column   int    `json:"column"`
	Severity string `json:"severity"`
	Message  string `json:"message"`
	Source   string `json:"source"`
}

// Runner runs language-specific diagnostic commands and parses results.
type Runner struct {
	timeout time.Duration
}

// NewRunner creates a Runner with the given timeout per command.
func NewRunner(timeout time.Duration) *Runner {
	return &Runner{timeout: timeout}
}

// RunForFile detects the language of the file and runs appropriate diagnostics.
func (r *Runner) RunForFile(filePath, workDir string) ([]Diagnostic, error) {
	ext := strings.ToLower(filepath.Ext(filePath))
	switch ext {
	case ".go":
		return r.runGoVet(workDir)
	case ".dart":
		return r.runDartAnalyze(workDir)
	case ".js", ".jsx", ".ts", ".tsx":
		return r.runESLint(filePath, workDir)
	case ".py":
		return r.runPylint(filePath, workDir)
	default:
		return nil, nil
	}
}

// RunForDirectory runs diagnostics for the entire project directory.
func (r *Runner) RunForDirectory(workDir string) ([]Diagnostic, error) {
	var all []Diagnostic

	// Try Go diagnostics.
	if goResults, err := r.runGoVet(workDir); err == nil {
		all = append(all, goResults...)
	}

	// Try Dart diagnostics.
	if dartResults, err := r.runDartAnalyze(workDir); err == nil {
		all = append(all, dartResults...)
	}

	return all, nil
}

func (r *Runner) runCommand(workDir, name string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), r.timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir = workDir

	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	// We don't check error here because linters return non-zero on findings.
	_ = cmd.Run()

	// Prefer stdout, fall back to stderr.
	if stdout.Len() > 0 {
		return stdout.Bytes(), nil
	}
	return stderr.Bytes(), nil
}

// go vet output format: file.go:line:col: message
var goVetRegex = regexp.MustCompile(`^(.+\.go):(\d+):(\d+):\s*(.+)$`)

func (r *Runner) runGoVet(workDir string) ([]Diagnostic, error) {
	output, err := r.runCommand(workDir, "go", "vet", "./...")
	if err != nil {
		return nil, err
	}
	return parseLineBasedOutput(output, goVetRegex, SeverityWarning, "go vet"), nil
}

// dart analyze output format: severity - message - path:line:col - (rule_name)
var dartAnalyzeRegex = regexp.MustCompile(`^\s*(error|warning|info)\s*-\s*(.+?)\s*-\s*(.+?):(\d+):(\d+)\s*-`)

func (r *Runner) runDartAnalyze(workDir string) ([]Diagnostic, error) {
	output, err := r.runCommand(workDir, "dart", "analyze", "--no-fatal-infos", "--no-fatal-warnings")
	if err != nil {
		return nil, err
	}
	return parseDartOutput(output), nil
}

func (r *Runner) runESLint(filePath, workDir string) ([]Diagnostic, error) {
	output, err := r.runCommand(workDir, "npx", "eslint", "--format", "unix", filePath)
	if err != nil {
		return nil, err
	}
	return parseESLintUnixOutput(output, filePath), nil
}

// pylint output: file:line:col: code: message
var pylintRegex = regexp.MustCompile(`^(.+?):(\d+):(\d+):\s*(\w\d+):\s*(.+)$`)

func (r *Runner) runPylint(filePath, workDir string) ([]Diagnostic, error) {
	output, err := r.runCommand(workDir, "python3", "-m", "pylint", "--output-format=text", "--score=no", filePath)
	if err != nil {
		return nil, err
	}
	return parsePylintOutput(output), nil
}

func parseLineBasedOutput(data []byte, re *regexp.Regexp, defaultSeverity, source string) []Diagnostic {
	var results []Diagnostic
	scanner := bufio.NewScanner(bytes.NewReader(data))
	for scanner.Scan() {
		line := scanner.Text()
		matches := re.FindStringSubmatch(line)
		if matches == nil {
			continue
		}
		lineNum, _ := strconv.Atoi(matches[2])
		colNum, _ := strconv.Atoi(matches[3])
		results = append(results, Diagnostic{
			FilePath: matches[1],
			Line:     lineNum,
			Column:   colNum,
			Severity: defaultSeverity,
			Message:  strings.TrimSpace(matches[4]),
			Source:   source,
		})
	}
	return results
}

func parseDartOutput(data []byte) []Diagnostic {
	var results []Diagnostic
	scanner := bufio.NewScanner(bytes.NewReader(data))
	for scanner.Scan() {
		line := scanner.Text()
		matches := dartAnalyzeRegex.FindStringSubmatch(line)
		if matches == nil {
			continue
		}
		severity := matches[1]
		message := strings.TrimSpace(matches[2])
		filePath := matches[3]
		lineNum, _ := strconv.Atoi(matches[4])
		colNum, _ := strconv.Atoi(matches[5])
		results = append(results, Diagnostic{
			FilePath: filePath,
			Line:     lineNum,
			Column:   colNum,
			Severity: normalizeSeverity(severity),
			Message:  message,
			Source:   "dart analyze",
		})
	}
	return results
}

// eslint --format unix: filepath:line:col: message [severity/rule]
var eslintUnixRegex = regexp.MustCompile(`^(.+?):(\d+):(\d+):\s*(.+?)\s*\[(Error|Warning)/`)

func parseESLintUnixOutput(data []byte, defaultFile string) []Diagnostic {
	var results []Diagnostic
	scanner := bufio.NewScanner(bytes.NewReader(data))
	for scanner.Scan() {
		line := scanner.Text()
		matches := eslintUnixRegex.FindStringSubmatch(line)
		if matches == nil {
			continue
		}
		lineNum, _ := strconv.Atoi(matches[2])
		colNum, _ := strconv.Atoi(matches[3])
		severity := strings.ToLower(matches[5])
		results = append(results, Diagnostic{
			FilePath: matches[1],
			Line:     lineNum,
			Column:   colNum,
			Severity: normalizeSeverity(severity),
			Message:  strings.TrimSpace(matches[4]),
			Source:   "eslint",
		})
	}
	return results
}

func parsePylintOutput(data []byte) []Diagnostic {
	var results []Diagnostic
	scanner := bufio.NewScanner(bytes.NewReader(data))
	for scanner.Scan() {
		line := scanner.Text()
		matches := pylintRegex.FindStringSubmatch(line)
		if matches == nil {
			continue
		}
		lineNum, _ := strconv.Atoi(matches[2])
		colNum, _ := strconv.Atoi(matches[3])
		code := matches[4]
		message := strings.TrimSpace(matches[5])
		severity := pylintCodeToSeverity(code)
		results = append(results, Diagnostic{
			FilePath: matches[1],
			Line:     lineNum,
			Column:   colNum,
			Severity: severity,
			Message:  fmt.Sprintf("%s: %s", code, message),
			Source:   "pylint",
		})
	}
	return results
}

func normalizeSeverity(s string) string {
	switch strings.ToLower(s) {
	case "error":
		return SeverityError
	case "warning", "warn":
		return SeverityWarning
	case "info", "information":
		return SeverityInfo
	default:
		return SeverityHint
	}
}

func pylintCodeToSeverity(code string) string {
	if len(code) == 0 {
		return SeverityWarning
	}
	switch code[0] {
	case 'E', 'F': // Error, Fatal
		return SeverityError
	case 'W': // Warning
		return SeverityWarning
	case 'C', 'R': // Convention, Refactor
		return SeverityInfo
	default:
		return SeverityHint
	}
}
