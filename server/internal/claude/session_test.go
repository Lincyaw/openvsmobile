package claude

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

func TestParseUserMessageString(t *testing.T) {
	line := `{"type":"user","content":"hello world"}`
	msg, err := parseMessage([]byte(line))
	if err != nil {
		t.Fatal(err)
	}
	if msg.Type != "user" {
		t.Fatalf("expected type user, got %s", msg.Type)
	}
	if len(msg.ContentBlocks) != 1 {
		t.Fatalf("expected 1 block, got %d", len(msg.ContentBlocks))
	}
	if msg.ContentBlocks[0].Text != "hello world" {
		t.Fatalf("expected 'hello world', got %q", msg.ContentBlocks[0].Text)
	}
}

func TestParseAssistantMessageWithBlocks(t *testing.T) {
	line := `{"type":"assistant","content":[{"type":"text","text":"response here"},{"type":"thinking","thinking":"internal thoughts","signature":"sig123"}]}`
	msg, err := parseMessage([]byte(line))
	if err != nil {
		t.Fatal(err)
	}
	if msg.Type != "assistant" {
		t.Fatalf("expected assistant, got %s", msg.Type)
	}
	if len(msg.ContentBlocks) != 2 {
		t.Fatalf("expected 2 blocks, got %d", len(msg.ContentBlocks))
	}
	if msg.ContentBlocks[0].Type != "text" || msg.ContentBlocks[0].Text != "response here" {
		t.Fatal("text block mismatch")
	}
	if msg.ContentBlocks[1].Type != "thinking" || msg.ContentBlocks[1].Thinking != "internal thoughts" {
		t.Fatal("thinking block mismatch")
	}
}

func TestParseToolUseWithFileAnnotation(t *testing.T) {
	line := `{"type":"assistant","content":[{"type":"tool_use","id":"toolu_123","name":"Edit","input":{"file_path":"/src/main.go","old_string":"foo","new_string":"bar"}}]}`
	msg, err := parseMessage([]byte(line))
	if err != nil {
		t.Fatal(err)
	}
	if len(msg.ContentBlocks) != 1 {
		t.Fatalf("expected 1 block, got %d", len(msg.ContentBlocks))
	}
	block := msg.ContentBlocks[0]
	if block.Type != "tool_use" {
		t.Fatalf("expected tool_use, got %s", block.Type)
	}
	if block.ToolUse == nil {
		t.Fatal("tool_use is nil")
	}
	if block.ToolUse.Name != "Edit" {
		t.Fatalf("expected Edit, got %s", block.ToolUse.Name)
	}
	if block.FileAnnotation == nil {
		t.Fatal("file annotation is nil")
	}
	if block.FileAnnotation.FilePath != "/src/main.go" {
		t.Fatalf("expected /src/main.go, got %s", block.FileAnnotation.FilePath)
	}
	if block.FileAnnotation.OldString != "foo" {
		t.Fatalf("expected 'foo', got %q", block.FileAnnotation.OldString)
	}
	if block.FileAnnotation.NewString != "bar" {
		t.Fatalf("expected 'bar', got %q", block.FileAnnotation.NewString)
	}
}

func TestParseToolUseWrite(t *testing.T) {
	line := `{"type":"assistant","content":[{"type":"tool_use","id":"toolu_456","name":"Write","input":{"file_path":"/tmp/test.txt","content":"hello"}}]}`
	msg, err := parseMessage([]byte(line))
	if err != nil {
		t.Fatal(err)
	}
	block := msg.ContentBlocks[0]
	if block.FileAnnotation == nil || block.FileAnnotation.FilePath != "/tmp/test.txt" {
		t.Fatal("Write annotation mismatch")
	}
	if block.FileAnnotation.Content != "hello" {
		t.Fatal("Write content mismatch")
	}
}

func TestParseToolUseRead(t *testing.T) {
	line := `{"type":"assistant","content":[{"type":"tool_use","id":"toolu_789","name":"Read","input":{"file_path":"/tmp/test.txt","offset":10,"limit":20}}]}`
	msg, err := parseMessage([]byte(line))
	if err != nil {
		t.Fatal(err)
	}
	block := msg.ContentBlocks[0]
	if block.FileAnnotation == nil || block.FileAnnotation.FilePath != "/tmp/test.txt" {
		t.Fatal("Read annotation mismatch")
	}
	if block.FileAnnotation.Offset != 10 || block.FileAnnotation.Limit != 20 {
		t.Fatal("Read offset/limit mismatch")
	}
}

func TestParseToolUseBash(t *testing.T) {
	line := `{"type":"assistant","content":[{"type":"tool_use","id":"toolu_abc","name":"Bash","input":{"command":"ls -la","description":"list files"}}]}`
	msg, err := parseMessage([]byte(line))
	if err != nil {
		t.Fatal(err)
	}
	block := msg.ContentBlocks[0]
	if block.FileAnnotation == nil || block.FileAnnotation.Command != "ls -la" {
		t.Fatal("Bash annotation mismatch")
	}
}

func TestParseToolResult(t *testing.T) {
	line := `{"type":"user","content":[{"type":"tool_result","tool_use_id":"toolu_123","content":"output text","is_error":false}]}`
	msg, err := parseMessage([]byte(line))
	if err != nil {
		t.Fatal(err)
	}
	if len(msg.ContentBlocks) != 1 {
		t.Fatalf("expected 1 block, got %d", len(msg.ContentBlocks))
	}
	block := msg.ContentBlocks[0]
	if block.Type != "tool_result" {
		t.Fatalf("expected tool_result, got %s", block.Type)
	}
	if block.ToolResult == nil {
		t.Fatal("tool_result is nil")
	}
	if block.ToolResult.ToolUseID != "toolu_123" {
		t.Fatalf("expected toolu_123, got %s", block.ToolResult.ToolUseID)
	}
}

func TestParseSystemMessage(t *testing.T) {
	line := `{"type":"system","subtype":"turn_end","stopReason":"end_turn","durationMs":1234}`
	msg, err := parseMessage([]byte(line))
	if err != nil {
		t.Fatal(err)
	}
	if msg.Type != "system" {
		t.Fatalf("expected system, got %s", msg.Type)
	}
	if msg.Subtype != "turn_end" {
		t.Fatalf("expected turn_end, got %s", msg.Subtype)
	}
	if msg.DurationMs != 1234 {
		t.Fatalf("expected 1234, got %d", msg.DurationMs)
	}
}

func TestParseFileHistorySnapshot(t *testing.T) {
	line := `{"type":"file-history-snapshot","messageId":"msg123","snapshot":{"trackedFileBackups":{}}}`
	msg, err := parseMessage([]byte(line))
	if err != nil {
		t.Fatal(err)
	}
	if msg.Type != "file-history-snapshot" {
		t.Fatalf("expected file-history-snapshot, got %s", msg.Type)
	}
	if msg.MessageID != "msg123" {
		t.Fatalf("expected msg123, got %s", msg.MessageID)
	}
}

func TestExtractAgentID(t *testing.T) {
	tests := []struct {
		input    string
		expected string
	}{
		{"agentId: abc123", "abc123"},
		{"some prefix agentId: xyz789 suffix", "xyz789"},
		{"no agent id here", ""},
		{"agentId:   spaced", "spaced"},
	}
	for _, tc := range tests {
		got := ExtractAgentID(tc.input)
		if got != tc.expected {
			t.Errorf("ExtractAgentID(%q) = %q, want %q", tc.input, got, tc.expected)
		}
	}
}

func TestExtractAgentIDFromResult(t *testing.T) {
	// String content.
	tr := &ToolResultBlock{
		Content: json.RawMessage(`"agentId: agent42"`),
	}
	got := ExtractAgentIDFromResult(tr)
	if got != "agent42" {
		t.Fatalf("expected agent42, got %s", got)
	}

	// Array content.
	tr2 := &ToolResultBlock{
		Content: json.RawMessage(`[{"type":"text","text":"result agentId: agent99 done"}]`),
	}
	got2 := ExtractAgentIDFromResult(tr2)
	if got2 != "agent99" {
		t.Fatalf("expected agent99, got %s", got2)
	}

	// Nil.
	got3 := ExtractAgentIDFromResult(nil)
	if got3 != "" {
		t.Fatalf("expected empty, got %s", got3)
	}
}

func TestScanAndListSessions(t *testing.T) {
	// Create temp directory structure.
	tmpDir := t.TempDir()
	sessionsDir := filepath.Join(tmpDir, "sessions")
	if err := os.MkdirAll(sessionsDir, 0755); err != nil {
		t.Fatal(err)
	}

	// Write session files.
	meta1 := SessionMeta{
		PID:       1234,
		SessionID: "sess-001",
		Cwd:       "/home/test",
		StartedAt: 1700000000000,
		Kind:      "interactive",
		Entrypoint: "cli",
	}
	data1, _ := json.Marshal(meta1)
	os.WriteFile(filepath.Join(sessionsDir, "1234.json"), data1, 0644)

	meta2 := SessionMeta{
		PID:       5678,
		SessionID: "sess-002",
		Cwd:       "/home/test2",
		StartedAt: 1700000001000,
		Kind:      "interactive",
		Entrypoint: "cli",
	}
	data2, _ := json.Marshal(meta2)
	os.WriteFile(filepath.Join(sessionsDir, "5678.json"), data2, 0644)

	idx := NewSessionIndex(tmpDir)
	if err := idx.ScanSessions(); err != nil {
		t.Fatal(err)
	}

	sessions := idx.ListSessions()
	if len(sessions) != 2 {
		t.Fatalf("expected 2 sessions, got %d", len(sessions))
	}
}

func TestGetMessages(t *testing.T) {
	tmpDir := t.TempDir()
	projectDir := filepath.Join(tmpDir, "projects", "test-project")
	if err := os.MkdirAll(projectDir, 0755); err != nil {
		t.Fatal(err)
	}

	// Create JSONL file.
	lines := []string{
		`{"type":"user","content":"hello"}`,
		`{"type":"assistant","content":[{"type":"text","text":"hi there"}]}`,
		`{"type":"system","subtype":"turn_end","stopReason":"end_turn","durationMs":500}`,
	}
	content := ""
	for _, l := range lines {
		content += l + "\n"
	}
	os.WriteFile(filepath.Join(projectDir, "sess-abc.jsonl"), []byte(content), 0644)

	idx := NewSessionIndex(tmpDir)
	messages, err := idx.GetMessages("sess-abc")
	if err != nil {
		t.Fatal(err)
	}
	if len(messages) != 3 {
		t.Fatalf("expected 3 messages, got %d", len(messages))
	}
	if messages[0].Type != "user" {
		t.Fatalf("expected user, got %s", messages[0].Type)
	}
	if messages[1].Type != "assistant" {
		t.Fatalf("expected assistant, got %s", messages[1].Type)
	}
	if messages[2].Type != "system" {
		t.Fatalf("expected system, got %s", messages[2].Type)
	}
}

func TestGetSubagentMessages(t *testing.T) {
	tmpDir := t.TempDir()
	sessionDir := filepath.Join(tmpDir, "projects", "test-project", "sess-abc", "subagents")
	if err := os.MkdirAll(sessionDir, 0755); err != nil {
		t.Fatal(err)
	}

	// Create subagent JSONL.
	agentContent := `{"type":"user","content":"do something"}
{"type":"assistant","content":[{"type":"text","text":"done"}]}
`
	os.WriteFile(filepath.Join(sessionDir, "agent-42.jsonl"), []byte(agentContent), 0644)

	// Create subagent meta.
	meta := SubagentMeta{AgentType: "research", Description: "Research agent"}
	metaData, _ := json.Marshal(meta)
	os.WriteFile(filepath.Join(sessionDir, "agent-42.meta.json"), metaData, 0644)

	idx := NewSessionIndex(tmpDir)

	messages, err := idx.GetSubagentMessages("sess-abc", "42")
	if err != nil {
		t.Fatal(err)
	}
	if len(messages) != 2 {
		t.Fatalf("expected 2 messages, got %d", len(messages))
	}

	agentMeta, err := idx.GetSubagentMeta("sess-abc", "42")
	if err != nil {
		t.Fatal(err)
	}
	if agentMeta.AgentType != "research" {
		t.Fatalf("expected research, got %s", agentMeta.AgentType)
	}
}

func TestSearchSessions(t *testing.T) {
	tmpDir := t.TempDir()
	sessionsDir := filepath.Join(tmpDir, "sessions")
	if err := os.MkdirAll(sessionsDir, 0755); err != nil {
		t.Fatal(err)
	}

	sessions := []SessionMeta{
		{PID: 1, SessionID: "s1", Cwd: "/home/user/projectA", StartedAt: 1700000000000, Entrypoint: "cli"},
		{PID: 2, SessionID: "s2", Cwd: "/home/user/projectB", StartedAt: 1700000001000, Entrypoint: "api"},
		{PID: 3, SessionID: "s3", Cwd: "/home/user/projectA", StartedAt: 1700000002000, Entrypoint: "cli"},
	}
	for _, s := range sessions {
		data, _ := json.Marshal(s)
		os.WriteFile(filepath.Join(sessionsDir, fmt.Sprintf("%d.json", s.PID)), data, 0644)
	}

	idx := NewSessionIndex(tmpDir)
	if err := idx.ScanSessions(); err != nil {
		t.Fatal(err)
	}

	// Search by query.
	results := idx.SearchSessions("projecta", "")
	if len(results) != 2 {
		t.Fatalf("expected 2 results for 'projecta', got %d", len(results))
	}

	// Search by project name.
	results = idx.SearchSessions("", "projectb")
	if len(results) != 1 {
		t.Fatalf("expected 1 result for project 'projectb', got %d", len(results))
	}

	// Search with no match.
	results = idx.SearchSessions("nonexistent", "")
	if len(results) != 0 {
		t.Fatalf("expected 0 results, got %d", len(results))
	}

	// Empty query returns all.
	results = idx.SearchSessions("", "")
	if len(results) != 3 {
		t.Fatalf("expected 3 results for empty search, got %d", len(results))
	}
}

func TestSubagentLinking(t *testing.T) {
	// Test the full subagent linking algorithm:
	// 1. Find tool_use with name "Agent" in parent session
	// 2. Find tool_result with matching tool_use_id containing agentId
	// 3. Extract agentId

	parentLines := []string{
		`{"type":"assistant","content":[{"type":"tool_use","id":"toolu_agent1","name":"Agent","input":{"description":"research task","prompt":"find info"}}]}`,
		`{"type":"user","content":[{"type":"tool_result","tool_use_id":"toolu_agent1","content":"Result from agent. agentId: agent-77","is_error":false}]}`,
	}

	var agentToolUseID string
	var agentID string

	for _, line := range parentLines {
		msg, err := parseMessage([]byte(line))
		if err != nil {
			t.Fatal(err)
		}
		for _, block := range msg.ContentBlocks {
			if block.ToolUse != nil && block.ToolUse.Name == "Agent" {
				agentToolUseID = block.ToolUse.ID
			}
			if block.ToolResult != nil && block.ToolResult.ToolUseID == agentToolUseID {
				agentID = ExtractAgentIDFromResult(block.ToolResult)
			}
		}
	}

	if agentID != "agent-77" {
		t.Fatalf("expected agent-77, got %s", agentID)
	}
}
