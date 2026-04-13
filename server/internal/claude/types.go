package claude

import "encoding/json"

// SessionMeta holds metadata about a Claude session.
type SessionMeta struct {
	PID       int    `json:"pid"`
	SessionID string `json:"sessionId"`
	Cwd       string `json:"cwd"`
	StartedAt int64  `json:"startedAt"`
	Kind      string `json:"kind"`
	Entrypoint string `json:"entrypoint"`
}

// Message represents a parsed JSONL message from a session log.
type Message struct {
	Type    string         `json:"type"`
	Content json.RawMessage `json:"content,omitempty"`

	// Parsed content blocks (for assistant and user messages).
	ContentBlocks []ContentBlock `json:"contentBlocks,omitempty"`

	// For system messages.
	Subtype    string `json:"subtype,omitempty"`
	StopReason string `json:"stopReason,omitempty"`
	DurationMs int64  `json:"durationMs,omitempty"`

	// For file-history-snapshot.
	MessageID string          `json:"messageId,omitempty"`
	Snapshot  json.RawMessage `json:"snapshot,omitempty"`

	// Raw fields preserved for types we don't fully parse.
	Raw json.RawMessage `json:"-"`
}

// ContentBlock is a union type for message content blocks.
type ContentBlock struct {
	Type string `json:"type"`

	// For text blocks.
	Text string `json:"text,omitempty"`

	// For thinking blocks.
	Thinking  string `json:"thinking,omitempty"`
	Signature string `json:"signature,omitempty"`

	// For tool_use blocks.
	ToolUse *ToolUseBlock `json:"toolUse,omitempty"`

	// For tool_result blocks.
	ToolResult *ToolResultBlock `json:"toolResult,omitempty"`

	// File annotation extracted from tool_use.
	FileAnnotation *FileChangeAnnotation `json:"fileAnnotation,omitempty"`
}

// ToolUseBlock represents a tool_use content block.
type ToolUseBlock struct {
	ID    string          `json:"id"`
	Name  string          `json:"name"`
	Input json.RawMessage `json:"input"`
}

// ToolResultBlock represents a tool_result content block.
type ToolResultBlock struct {
	ToolUseID string          `json:"tool_use_id"`
	Content   json.RawMessage `json:"content"` // string or array
	IsError   bool            `json:"is_error"`
}

// FileChangeAnnotation contains file navigation info extracted from tool_use inputs.
type FileChangeAnnotation struct {
	FilePath  string `json:"filePath,omitempty"`
	OldString string `json:"oldString,omitempty"`
	NewString string `json:"newString,omitempty"`
	Content   string `json:"content,omitempty"`
	Command   string `json:"command,omitempty"`
	Offset    int    `json:"offset,omitempty"`
	Limit     int    `json:"limit,omitempty"`
}

// SubagentMeta holds metadata about a subagent.
type SubagentMeta struct {
	AgentType   string `json:"agentType"`
	Description string `json:"description"`
}

// DirEntry represents a file or directory entry for the FileSystem interface.
type DirEntry struct {
	Name  string `json:"name"`
	IsDir bool   `json:"isDir"`
	Size  int64  `json:"size"`
}

// FileStat represents file metadata.
type FileStat struct {
	Name  string `json:"name"`
	IsDir bool   `json:"isDir"`
	Size  int64  `json:"size"`
}

// StreamInput is the JSON sent to claude CLI stdin.
type StreamInput struct {
	Type    string `json:"type"`
	Content string `json:"content"`
}

// StreamOutput is the JSON received from claude CLI stdout.
type StreamOutput struct {
	Type       string          `json:"type"`
	Content    json.RawMessage `json:"content,omitempty"`
	StopReason string          `json:"stop_reason,omitempty"`
}
