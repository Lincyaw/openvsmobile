package claude

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
)

// SessionIndex manages the index of Claude sessions.
type SessionIndex struct {
	mu        sync.RWMutex
	claudeDir string
	sessions  []SessionMeta
}

// NewSessionIndex creates a new SessionIndex rooted at the given claude home directory.
func NewSessionIndex(claudeDir string) *SessionIndex {
	return &SessionIndex{
		claudeDir: claudeDir,
	}
}

// ScanSessions walks ~/.claude/sessions/ and ~/.claude/projects/ to build the session index.
func (idx *SessionIndex) ScanSessions() error {
	idx.mu.Lock()
	defer idx.mu.Unlock()

	idx.sessions = nil

	sessionsDir := filepath.Join(idx.claudeDir, "sessions")
	entries, err := os.ReadDir(sessionsDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("reading sessions dir: %w", err)
	}

	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		data, err := os.ReadFile(filepath.Join(sessionsDir, entry.Name()))
		if err != nil {
			continue
		}
		var meta SessionMeta
		if err := json.Unmarshal(data, &meta); err != nil {
			continue
		}
		if meta.SessionID != "" {
			meta.Summary = idx.extractSummary(meta.SessionID)
			idx.sessions = append(idx.sessions, meta)
		}
	}

	return nil
}

// ListSessions returns all known sessions.
func (idx *SessionIndex) ListSessions() []SessionMeta {
	idx.mu.RLock()
	defer idx.mu.RUnlock()

	result := make([]SessionMeta, len(idx.sessions))
	copy(result, idx.sessions)
	return result
}

// SearchSessions returns sessions matching the query string.
// Matches against cwd (project path) and entrypoint, case-insensitive.
// If workspaceRoot is non-empty, absolute/path-like values are matched against
// the exact cleaned workspace root. Bare names fall back to the legacy
// project-name filter for compatibility with older callers and tests.
func (idx *SessionIndex) SearchSessions(query, workspaceRoot string) []SessionMeta {
	idx.mu.RLock()
	defer idx.mu.RUnlock()

	query = strings.ToLower(query)
	normalizedRoot := normalizeWorkspaceRoot(workspaceRoot)

	result := make([]SessionMeta, 0)
	for _, s := range idx.sessions {
		cwdLower := strings.ToLower(s.Cwd)
		entryLower := strings.ToLower(s.Entrypoint)

		if !matchesWorkspaceRoot(s.Cwd, normalizedRoot) {
			continue
		}

		if query != "" {
			if !strings.Contains(cwdLower, query) && !strings.Contains(entryLower, query) {
				continue
			}
		}

		result = append(result, s)
	}
	return result
}

func normalizeWorkspaceRoot(path string) string {
	if path == "" {
		return ""
	}
	cleaned := filepath.Clean(strings.TrimSpace(path))
	if cleaned == "." {
		return ""
	}
	return cleaned
}

func matchesWorkspaceRoot(cwd, workspaceRoot string) bool {
	if workspaceRoot == "" {
		return true
	}

	if strings.Contains(workspaceRoot, "/") {
		return normalizeWorkspaceRoot(cwd) == workspaceRoot
	}

	parts := strings.Split(normalizeWorkspaceRoot(cwd), "/")
	if len(parts) == 0 {
		return false
	}
	last := parts[len(parts)-1]
	if last == "" && len(parts) > 1 {
		last = parts[len(parts)-2]
	}
	return strings.EqualFold(last, workspaceRoot)
}

// GetMessages parses the JSONL file for the given session and returns structured messages.
// It searches across all project directories for the session's JSONL file.
func (idx *SessionIndex) GetMessages(sessionID string) ([]Message, error) {
	jsonlPath, err := idx.findSessionJSONL(sessionID)
	if err != nil {
		return nil, err
	}
	return parseJSONLFile(jsonlPath)
}

// GetSubagentMessages parses a subagent's JSONL file.
func (idx *SessionIndex) GetSubagentMessages(sessionID, agentID string) ([]Message, error) {
	sessionDir, err := idx.findSessionDir(sessionID)
	if err != nil {
		return nil, err
	}
	agentPath := filepath.Join(sessionDir, "subagents", fmt.Sprintf("agent-%s.jsonl", agentID))
	return parseJSONLFile(agentPath)
}

// GetSubagentMeta loads the metadata for a subagent.
func (idx *SessionIndex) GetSubagentMeta(sessionID, agentID string) (*SubagentMeta, error) {
	sessionDir, err := idx.findSessionDir(sessionID)
	if err != nil {
		return nil, err
	}
	metaPath := filepath.Join(sessionDir, "subagents", fmt.Sprintf("agent-%s.meta.json", agentID))
	data, err := os.ReadFile(metaPath)
	if err != nil {
		return nil, fmt.Errorf("reading subagent meta: %w", err)
	}
	var meta SubagentMeta
	if err := json.Unmarshal(data, &meta); err != nil {
		return nil, fmt.Errorf("parsing subagent meta: %w", err)
	}
	return &meta, nil
}

// extractSummary peeks at the JSONL file for a session and returns the first
// user message text, truncated to 120 characters. It reads at most 10 lines
// for efficiency.
func (idx *SessionIndex) extractSummary(sessionID string) string {
	jsonlPath, err := idx.findSessionJSONL(sessionID)
	if err != nil {
		return ""
	}

	f, err := os.Open(jsonlPath)
	if err != nil {
		return ""
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 0, 64*1024), 10*1024*1024)

	const maxLines = 10
	for i := 0; i < maxLines && scanner.Scan(); i++ {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}

		var typeHolder struct {
			Type string `json:"type"`
		}
		if json.Unmarshal(line, &typeHolder) != nil {
			continue
		}
		if typeHolder.Type != "user" && typeHolder.Type != "human" {
			continue
		}

		text := extractFirstTextFromContent(line)
		if text == "" {
			continue
		}

		// Truncate to 120 characters.
		if len([]rune(text)) > 120 {
			text = string([]rune(text)[:120]) + "..."
		}
		return text
	}

	return ""
}

// parseMessageContent unmarshals message content that is either a plain string
// or an array of content blocks. It returns the string form and block list.
func parseMessageContent(content json.RawMessage) (string, []ContentBlock, error) {
	if len(content) > 0 && content[0] == '"' {
		var s string
		if err := json.Unmarshal(content, &s); err != nil {
			return "", nil, err
		}
		return s, []ContentBlock{{Type: "text", Text: s}}, nil
	}

	var blocks []json.RawMessage
	if err := json.Unmarshal(content, &blocks); err != nil {
		return "", nil, err
	}

	var result []ContentBlock
	for _, blockData := range blocks {
		block, err := parseContentBlock(blockData)
		if err != nil {
			continue
		}
		result = append(result, block)
	}

	return "", result, nil
}

// extractFirstTextFromContent extracts the first text content from a user/human message line.
func extractFirstTextFromContent(data []byte) string {
	var raw struct {
		Message struct {
			Content json.RawMessage `json:"content"`
		} `json:"message"`
	}
	if json.Unmarshal(data, &raw) != nil || raw.Message.Content == nil {
		return ""
	}

	_, blocks, err := parseMessageContent(raw.Message.Content)
	if err == nil {
		for _, b := range blocks {
			if b.Type == "text" && strings.TrimSpace(b.Text) != "" {
				return strings.TrimSpace(b.Text)
			}
		}
	}

	// Fallback: try plain string extraction directly.
	var s string
	if json.Unmarshal(raw.Message.Content, &s) == nil {
		return strings.TrimSpace(s)
	}

	return ""
}

// GetSessionCwd returns the working directory for a given session ID.
func (idx *SessionIndex) GetSessionCwd(sessionID string) (string, error) {
	idx.mu.RLock()
	defer idx.mu.RUnlock()
	for _, s := range idx.sessions {
		if s.SessionID == sessionID {
			return s.Cwd, nil
		}
	}
	return "", fmt.Errorf("session not found: %w", fs.ErrNotExist)
}

// findSessionJSONL searches for the session JSONL file across project directories.
func (idx *SessionIndex) findSessionJSONL(sessionID string) (string, error) {
	projectsDir := filepath.Join(idx.claudeDir, "projects")
	projectEntries, err := os.ReadDir(projectsDir)
	if err != nil {
		return "", fmt.Errorf("reading projects dir: %w", err)
	}

	filename := sessionID + ".jsonl"
	for _, entry := range projectEntries {
		if !entry.IsDir() {
			continue
		}
		candidate := filepath.Join(projectsDir, entry.Name(), filename)
		if _, err := os.Stat(candidate); err == nil {
			return candidate, nil
		}
	}

	return "", fmt.Errorf("session JSONL not found for %s: %w", sessionID, fs.ErrNotExist)
}

// findSessionDir finds the directory associated with a session (for subagent access).
func (idx *SessionIndex) findSessionDir(sessionID string) (string, error) {
	projectsDir := filepath.Join(idx.claudeDir, "projects")
	projectEntries, err := os.ReadDir(projectsDir)
	if err != nil {
		return "", fmt.Errorf("reading projects dir: %w", err)
	}

	for _, entry := range projectEntries {
		if !entry.IsDir() {
			continue
		}
		candidate := filepath.Join(projectsDir, entry.Name(), sessionID)
		if info, err := os.Stat(candidate); err == nil && info.IsDir() {
			return candidate, nil
		}
	}

	return "", fmt.Errorf("session dir not found for %s: %w", sessionID, fs.ErrNotExist)
}

// parseJSONLFile reads and parses a JSONL file into structured messages.
func parseJSONLFile(path string) ([]Message, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("opening JSONL file: %w", err)
	}
	defer f.Close()

	messages := make([]Message, 0)
	scanner := bufio.NewScanner(f)
	// Increase buffer size for large lines.
	scanner.Buffer(make([]byte, 0, 64*1024), 10*1024*1024)

	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		msg, err := parseMessage(line)
		if err != nil {
			// Skip unparseable lines.
			continue
		}
		messages = append(messages, msg)
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("scanning JSONL: %w", err)
	}
	return messages, nil
}

// parseMessage parses a single JSON line into a Message.
func parseMessage(data []byte) (Message, error) {
	var msg Message
	msg.Raw = make([]byte, len(data))
	copy(msg.Raw, data)

	// First, get the type field.
	var typeHolder struct {
		Type string `json:"type"`
	}
	if err := json.Unmarshal(data, &typeHolder); err != nil {
		return msg, err
	}
	msg.Type = typeHolder.Type

	switch msg.Type {
	case "user", "assistant":
		if err := parseContentMessage(data, &msg); err != nil {
			return msg, err
		}
	case "system":
		var sys struct {
			Subtype    string `json:"subtype"`
			StopReason string `json:"stopReason"`
			DurationMs int64  `json:"durationMs"`
		}
		if err := json.Unmarshal(data, &sys); err == nil {
			msg.Subtype = sys.Subtype
			msg.StopReason = sys.StopReason
			msg.DurationMs = sys.DurationMs
		}
	case "file-history-snapshot":
		var fhs struct {
			MessageID string          `json:"messageId"`
			Snapshot  json.RawMessage `json:"snapshot"`
		}
		if err := json.Unmarshal(data, &fhs); err == nil {
			msg.MessageID = fhs.MessageID
			msg.Snapshot = fhs.Snapshot
		}
	}

	return msg, nil
}

// parseContentMessage parses user/assistant messages with content blocks.
func parseContentMessage(data []byte, msg *Message) error {
	var raw struct {
		Message struct {
			Content json.RawMessage `json:"content"`
		} `json:"message"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}

	content := raw.Message.Content
	if content == nil {
		return nil
	}

	s, blocks, err := parseMessageContent(content)
	if err != nil {
		return err
	}
	if s != "" {
		msg.ContentBlocks = blocks
	} else {
		msg.ContentBlocks = blocks
	}
	msg.Content = content
	return nil
}

// parseContentBlock parses a single content block.
func parseContentBlock(data []byte) (ContentBlock, error) {
	var typeHolder struct {
		Type string `json:"type"`
	}
	if err := json.Unmarshal(data, &typeHolder); err != nil {
		return ContentBlock{}, err
	}

	block := ContentBlock{Type: typeHolder.Type}

	switch typeHolder.Type {
	case "text":
		var tb struct {
			Text string `json:"text"`
		}
		if err := json.Unmarshal(data, &tb); err != nil {
			return block, err
		}
		block.Text = tb.Text

	case "thinking":
		var tb struct {
			Thinking  string `json:"thinking"`
			Signature string `json:"signature"`
		}
		if err := json.Unmarshal(data, &tb); err != nil {
			return block, err
		}
		block.Thinking = tb.Thinking
		block.Signature = tb.Signature

	case "tool_use":
		var tu struct {
			ID    string          `json:"id"`
			Name  string          `json:"name"`
			Input json.RawMessage `json:"input"`
		}
		if err := json.Unmarshal(data, &tu); err != nil {
			return block, err
		}
		block.ToolUse = &ToolUseBlock{
			ID:    tu.ID,
			Name:  tu.Name,
			Input: tu.Input,
		}
		block.FileAnnotation = extractFileAnnotation(tu.Name, tu.Input)

	case "tool_result":
		var tr struct {
			ToolUseID string          `json:"tool_use_id"`
			Content   json.RawMessage `json:"content"`
			IsError   bool            `json:"is_error"`
		}
		if err := json.Unmarshal(data, &tr); err != nil {
			return block, err
		}
		block.ToolResult = &ToolResultBlock{
			ToolUseID: tr.ToolUseID,
			Content:   tr.Content,
			IsError:   tr.IsError,
		}
	}

	return block, nil
}

// extractFileAnnotation extracts file navigation info from tool_use inputs.
func extractFileAnnotation(toolName string, input json.RawMessage) *FileChangeAnnotation {
	if input == nil {
		return nil
	}

	switch toolName {
	case "Edit":
		var inp struct {
			FilePath  string `json:"file_path"`
			OldString string `json:"old_string"`
			NewString string `json:"new_string"`
		}
		if json.Unmarshal(input, &inp) == nil && inp.FilePath != "" {
			return &FileChangeAnnotation{
				FilePath:  inp.FilePath,
				OldString: inp.OldString,
				NewString: inp.NewString,
			}
		}

	case "Write":
		var inp struct {
			FilePath string `json:"file_path"`
			Content  string `json:"content"`
		}
		if json.Unmarshal(input, &inp) == nil && inp.FilePath != "" {
			return &FileChangeAnnotation{
				FilePath: inp.FilePath,
				Content:  inp.Content,
			}
		}

	case "Read":
		var inp struct {
			FilePath string `json:"file_path"`
			Offset   int    `json:"offset"`
			Limit    int    `json:"limit"`
		}
		if json.Unmarshal(input, &inp) == nil && inp.FilePath != "" {
			return &FileChangeAnnotation{
				FilePath: inp.FilePath,
				Offset:   inp.Offset,
				Limit:    inp.Limit,
			}
		}

	case "Bash":
		var inp struct {
			Command     string `json:"command"`
			Description string `json:"description"`
		}
		if json.Unmarshal(input, &inp) == nil && inp.Command != "" {
			return &FileChangeAnnotation{
				Command: inp.Command,
			}
		}

	case "Agent":
		// Agent tool_use doesn't have a file path but we can annotate it.
		return nil
	}

	return nil
}

// agentIDRegex matches "agentId: <id>" in tool_result content.
var agentIDRegex = regexp.MustCompile(`agentId:\s*(\S+)`)

// ExtractAgentID extracts the agentId from a tool_result content string.
func ExtractAgentID(content string) string {
	matches := agentIDRegex.FindStringSubmatch(content)
	if len(matches) >= 2 {
		return matches[1]
	}
	return ""
}

// ExtractAgentIDFromResult attempts to extract the agent ID from a ToolResultBlock.
func ExtractAgentIDFromResult(tr *ToolResultBlock) string {
	if tr == nil || tr.Content == nil {
		return ""
	}

	// Content can be a string or array of text blocks.
	var s string
	if json.Unmarshal(tr.Content, &s) == nil {
		return ExtractAgentID(s)
	}

	var blocks []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if json.Unmarshal(tr.Content, &blocks) == nil {
		for _, b := range blocks {
			if id := ExtractAgentID(b.Text); id != "" {
				return id
			}
		}
	}

	return ""
}
