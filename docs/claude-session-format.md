# Claude Code Session Data Format

Reference document for the Go server's JSONL parser (REQ-005).

## File Layout

```
~/.claude/
├── sessions/
│   └── <pid>.json              # Session metadata (one per process)
└── projects/
    └── <project-slug>/
        ├── <session-id>.jsonl  # Main conversation log
        └── <session-id>/
            ├── subagents/
            │   ├── agent-<agentId>.jsonl      # Subagent conversation
            │   └── agent-<agentId>.meta.json  # Subagent metadata
            └── tool-results/
                └── <id>.txt    # Large tool outputs stored externally
```

## Session Metadata (`sessions/<pid>.json`)

```json
{
  "pid": 1208637,
  "sessionId": "4b3be69d-a69b-42d6-a118-ce0ab608071d",
  "cwd": "/home/user/project",
  "startedAt": 1776002924147,
  "kind": "interactive",
  "entrypoint": "cli"  // "cli" | "claude-vscode"
}
```

## JSONL Message Types

Each line in the JSONL is a JSON object with a `type` field.

### Common Fields (most message types)

| Field | Type | Description |
|-------|------|-------------|
| `type` | string | Message type discriminator |
| `uuid` | string | Unique message ID |
| `parentUuid` | string? | Previous message in conversation chain |
| `timestamp` | string | ISO 8601 |
| `sessionId` | string | Session UUID |
| `cwd` | string | Working directory at time of message |
| `gitBranch` | string | Git branch at time of message |
| `isSidechain` | bool | True for subagent messages |

### `user` — User input or tool result

```json
{
  "type": "user",
  "message": {
    "role": "user",
    "content": "string" | [<content-block>...]
  },
  "promptId": "uuid",              // Groups messages from same user prompt
  "isMeta": false,                 // True for system-generated user messages
  "isCompactSummary": false,       // True for context-compressed summaries
  "sourceToolUseID": "string",     // If this is a tool result for a specific tool_use
  "sourceToolAssistantUUID": "string",
  "toolUseResult": {               // Present for Skill tool results
    "success": true,
    "commandName": "skill-name"
  }
}
```

**Content blocks in user messages:**

- `{ "type": "text", "text": "..." }` — User text
- `{ "type": "tool_result", "tool_use_id": "...", "content": "..." | [...], "is_error": bool }` — Tool result

### `assistant` — Claude response

```json
{
  "type": "assistant",
  "message": {
    "role": "assistant",
    "content": [<content-block>...]
  },
  "requestId": "req_..."          // Anthropic API request ID
}
```

**Content blocks in assistant messages:**

- `{ "type": "text", "text": "..." }` — Response text (markdown)
- `{ "type": "thinking", "thinking": "...", "signature": "..." }` — Internal reasoning
- `{ "type": "tool_use", "id": "toolu_...", "name": "...", "input": {...}, "caller": {"type": "direct"} }` — Tool invocation

### `system` — System events

```json
{
  "type": "system",
  "subtype": "string",            // Event subtype
  "content": "string",
  "stopReason": "string",         // "end_turn", "tool_use", etc.
  "durationMs": 1234,
  "messageCount": 5,
  "hookCount": 0
}
```

### `file-history-snapshot` — File change tracking

```json
{
  "type": "file-history-snapshot",
  "messageId": "uuid",            // Links to the assistant message that caused changes
  "isSnapshotUpdate": false,
  "snapshot": {
    "messageId": "uuid",
    "timestamp": "ISO 8601",
    "trackedFileBackups": {
      "relative/path/to/file": "original-content-before-edit"
    }
  }
}
```

### `permission-mode` — Permission mode change

```json
{
  "type": "permission-mode",
  "permissionMode": "bypassPermissions",  // "default" | "acceptEdits" | "bypassPermissions" | ...
  "sessionId": "uuid"
}
```

### `attachment` — Hook output or file attachment

```json
{
  "type": "attachment",
  "attachment": {
    "type": "hook_success",
    "hookName": "SessionStart:startup",
    "content": "string"
  }
}
```

### `queue-operation` — Background task status

```json
{
  "type": "queue-operation",
  "operation": "string",
  "content": "string",
  "timestamp": "ISO 8601"
}
```

### `last-prompt` — Last user prompt (for resume)

```json
{
  "type": "last-prompt",
  "lastPrompt": "string",
  "sessionId": "uuid"
}
```

## Tool Types and Their Input Fields

| Tool | Input Fields | UI Relevance |
|------|-------------|--------------|
| `Edit` | `file_path`, `old_string`, `new_string`, `replace_all` | Show as diff card, link to file:line |
| `Write` | `file_path`, `content` | Show as "created file" card, link to file |
| `Bash` | `command`, `description` | Show command and output |
| `Read` | `file_path`, `offset`, `limit` | Show as "read file" reference |
| `Glob` | `pattern`, `path` | Show as file search |
| `Grep` | `pattern`, `path`, `output_mode` | Show as content search |
| `Agent` | `description`, `prompt`, `subagent_type`, `name` | Show as expandable subagent card |
| `Skill` | `skill`, `args` | Show as skill invocation |
| `TaskCreate` | `description`, `subject` | Show as task card |
| `TaskUpdate` | `taskId`, `status` | Show status change |

## Subagent Linking

### Parent → Subagent

1. Parent assistant message contains `tool_use` with `name: "Agent"`
2. Tool result returns: `"agentId: <agentId>"`
3. Subagent JSONL at: `<session-id>/subagents/agent-<agentId>.jsonl`
4. Subagent metadata at: `<session-id>/subagents/agent-<agentId>.meta.json`

### Subagent Metadata (`meta.json`)

```json
{
  "agentType": "Explore",              // "general-purpose" | "Explore" | "Plan" | ...
  "description": "Research something"   // Same as Agent tool_use input.description
}
```

### Subagent JSONL

Same format as main JSONL, with additional fields:
- `agentId`: the subagent's ID (matches directory name)
- `promptId`: links to the parent's user prompt
- `isSidechain`: always `true`

### Linking Algorithm

```
For each Agent tool_use in parent:
  1. tool_use.id → find matching tool_result
  2. Parse tool_result.content for "agentId: <id>"
  3. Load subagents/agent-<id>.jsonl for full conversation
  4. Load subagents/agent-<id>.meta.json for type + description
```

## Large Tool Results

When tool output exceeds a size threshold, it's stored externally:
- Content: `"Output too large (<size>). Full output saved to: <path>"`
- Path pattern: `<session-id>/tool-results/<id>.txt`
