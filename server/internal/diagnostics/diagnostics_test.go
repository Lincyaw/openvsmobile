package diagnostics

import (
	"testing"
)

func TestParseGoVetOutput(t *testing.T) {
	output := []byte(`# mypackage
./main.go:10:5: unreachable code
./handler.go:25:12: printf: non-constant format string
`)
	results := parseLineBasedOutput(output, goVetRegex, SeverityWarning, "go vet")
	if len(results) != 2 {
		t.Fatalf("expected 2 diagnostics, got %d", len(results))
	}
	if results[0].FilePath != "./main.go" {
		t.Fatalf("expected ./main.go, got %s", results[0].FilePath)
	}
	if results[0].Line != 10 || results[0].Column != 5 {
		t.Fatalf("expected line 10 col 5, got %d:%d", results[0].Line, results[0].Column)
	}
	if results[0].Message != "unreachable code" {
		t.Fatalf("expected 'unreachable code', got %q", results[0].Message)
	}
	if results[0].Severity != SeverityWarning {
		t.Fatalf("expected warning, got %s", results[0].Severity)
	}
}

func TestParseDartAnalyzeOutput(t *testing.T) {
	output := []byte(`Analyzing app...

   error - The argument type 'String' can't be assigned to the parameter type 'int' - lib/main.dart:15:10 - (argument_type_not_assignable)
   warning - Unused import - lib/utils.dart:3:8 - (unused_import)
   info - Prefer const constructors - lib/app.dart:12:5 - (prefer_const_constructors)

3 issues found.
`)
	results := parseDartOutput(output)
	if len(results) != 3 {
		t.Fatalf("expected 3 diagnostics, got %d", len(results))
	}
	if results[0].Severity != SeverityError {
		t.Fatalf("expected error, got %s", results[0].Severity)
	}
	if results[0].FilePath != "lib/main.dart" {
		t.Fatalf("expected lib/main.dart, got %s", results[0].FilePath)
	}
	if results[0].Line != 15 || results[0].Column != 10 {
		t.Fatalf("expected 15:10, got %d:%d", results[0].Line, results[0].Column)
	}
	if results[1].Severity != SeverityWarning {
		t.Fatalf("expected warning, got %s", results[1].Severity)
	}
	if results[2].Severity != SeverityInfo {
		t.Fatalf("expected info, got %s", results[2].Severity)
	}
}

func TestParseESLintUnixOutput(t *testing.T) {
	output := []byte(`/home/user/src/app.tsx:10:5: 'foo' is assigned a value but never used. [Warning/no-unused-vars]
/home/user/src/app.tsx:25:1: Missing return type on function. [Error/explicit-function-return-type]
`)
	results := parseESLintUnixOutput(output, "/home/user/src/app.tsx")
	if len(results) != 2 {
		t.Fatalf("expected 2 diagnostics, got %d", len(results))
	}
	if results[0].Severity != SeverityWarning {
		t.Fatalf("expected warning, got %s", results[0].Severity)
	}
	if results[1].Severity != SeverityError {
		t.Fatalf("expected error, got %s", results[1].Severity)
	}
	if results[0].Line != 10 || results[0].Column != 5 {
		t.Fatalf("expected 10:5, got %d:%d", results[0].Line, results[0].Column)
	}
}

func TestParsePylintOutput(t *testing.T) {
	output := []byte(`main.py:10:0: C0114: Missing module docstring (missing-module-docstring)
main.py:15:4: E1101: Instance of 'Foo' has no 'bar' member (no-member)
main.py:20:0: W0611: Unused import os (unused-import)
`)
	results := parsePylintOutput(output)
	if len(results) != 3 {
		t.Fatalf("expected 3 diagnostics, got %d", len(results))
	}
	if results[0].Severity != SeverityInfo {
		t.Fatalf("expected info for C code, got %s", results[0].Severity)
	}
	if results[1].Severity != SeverityError {
		t.Fatalf("expected error for E code, got %s", results[1].Severity)
	}
	if results[2].Severity != SeverityWarning {
		t.Fatalf("expected warning for W code, got %s", results[2].Severity)
	}
}

func TestNormalizeSeverity(t *testing.T) {
	tests := []struct {
		input    string
		expected string
	}{
		{"error", SeverityError},
		{"Error", SeverityError},
		{"warning", SeverityWarning},
		{"warn", SeverityWarning},
		{"info", SeverityInfo},
		{"information", SeverityInfo},
		{"hint", SeverityHint},
		{"unknown", SeverityHint},
	}
	for _, tc := range tests {
		got := normalizeSeverity(tc.input)
		if got != tc.expected {
			t.Errorf("normalizeSeverity(%q) = %q, want %q", tc.input, got, tc.expected)
		}
	}
}

func TestPylintCodeToSeverity(t *testing.T) {
	tests := []struct {
		code     string
		expected string
	}{
		{"E1101", SeverityError},
		{"F0001", SeverityError},
		{"W0611", SeverityWarning},
		{"C0114", SeverityInfo},
		{"R0903", SeverityInfo},
		{"", SeverityWarning},
	}
	for _, tc := range tests {
		got := pylintCodeToSeverity(tc.code)
		if got != tc.expected {
			t.Errorf("pylintCodeToSeverity(%q) = %q, want %q", tc.code, got, tc.expected)
		}
	}
}

func TestEmptyInput(t *testing.T) {
	// All parsers should handle empty input gracefully.
	if results := parseLineBasedOutput(nil, goVetRegex, SeverityWarning, "test"); len(results) != 0 {
		t.Fatalf("expected 0 for nil input, got %d", len(results))
	}
	if results := parseDartOutput(nil); len(results) != 0 {
		t.Fatalf("expected 0 for nil dart input, got %d", len(results))
	}
	if results := parseESLintUnixOutput(nil, "test.js"); len(results) != 0 {
		t.Fatalf("expected 0 for nil eslint input, got %d", len(results))
	}
	if results := parsePylintOutput(nil); len(results) != 0 {
		t.Fatalf("expected 0 for nil pylint input, got %d", len(results))
	}
}
