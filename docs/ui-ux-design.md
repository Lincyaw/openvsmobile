# UI/UX Design: VSCode Mobile

## Design Principles

1. **Mobile-first** — thumb-friendly targets (48dp minimum), bottom navigation for primary actions
2. **Contextual** — reduce navigation depth; code and AI chat coexist
3. **Scannable** — syntax highlighting and visual hierarchy make code browsable at a glance
4. **Connected** — every AI message that references a file is tappable

## Navigation Structure

Bottom navigation bar with 5 tabs:

```
┌──────────────────────────────────────────┐
│                                          │
│             [Active View]                │
│                                          │
├────────┬────────┬─────┬──────┬──────────┤
│  📁    │  🔍    │ >_  │  💬  │   ⚙️     │
│ Files  │ Search │Term │ Chat │  More    │
└────────┴────────┴─────┴──────┴──────────┘
```

| Tab | View | Description |
|-----|------|-------------|
| Files | File Explorer | Project file tree + code viewer (scoped to workspace) |
| Search | Global Search | File name + content grep (scoped to workspace) |
| Terminal | Shell | PTY terminal with ANSI colors, lazy-connected on first view |
| Chat | AI Chat | Full-screen Claude conversation |
| More | Settings/Git | Git status, diff, settings |

## Screen Flows

### 1. Files Tab — File Explorer + Code Viewer

```
┌─────────────────────────────┐
│  ProjectName ▼  [refresh][+]│  ← Workspace picker (tap to switch)
├─────────────────────────────┤
│ 📁 src/                    │
│   📁 server/               │
│     📄 main.go             │
│     📄 handler.go          │
│   📁 client/               │
│ 📄 go.mod                  │
│ 📄 README.md               │
│                             │
│                             │
├──────┬──────┬────┬────┬────┤
│Files │Search│Term│Chat│More│
└──────┴──────┴────┴────┴────┘
```

**Tap a file → Code Viewer:**

```
┌─────────────────────────────┐
│ ←  main.go          [⋮]   │  ← Back to tree, overflow menu (edit/share)
├─────────────────────────────┤
│  1│ package main              │
│  2│                           │
│  3│ import (                  │
│  4│   "fmt"                   │
│  5│   "net/http"              │
│  6│ )                         │
│  7│                           │
│  8│ func main() {             │
│  9│   ██████████████          │  ← Selected region (highlighted)
│ 10│   ██████████████          │
│ 11│ }                         │
│                               │
├───────────────────────────────┤
│ [Ask AI]  [Edit]  [Copy]     │  ← Context toolbar (appears on selection)
├──────┬──────┬────┬────┬──────┤
│Files │Search│Term│Chat│ More │
└──────┴──────┴────┴────┴──────┘
```

**Interactions:**
- Long-press to enter selection mode
- Drag handles to select code region
- Context toolbar slides up on selection
- "Ask AI" opens bottom sheet chat with selected code as context
- "Edit" enters simple edit mode (cursor, keyboard, save button)
- Pinch-to-zoom for font size
- Horizontal scroll for long lines

### 2. Chat Tab — Full-Screen AI Chat

```
┌─────────────────────────────┐
│ ← Sessions   New Chat  [⋮] │
├─────────────────────────────┤
│ ┌───────────────────────┐   │
│ │ 🤖 Claude             │   │
│ │ I'll fix the auth     │   │
│ │ handler. Here's what  │   │
│ │ I changed:            │   │
│ │                       │   │
│ │ ┌─────────────────┐   │   │
│ │ │ ✏️ Edit          │   │   │  ← Tappable file-change card
│ │ │ server/auth.go   │   │   │
│ │ │ L42-L58          │   │   │
│ │ └─────────────────┘   │   │
│ │                       │   │
│ │ ┌─────────────────┐   │   │
│ │ │ 🖥️ Bash          │   │   │  ← Tappable command card
│ │ │ go test ./...    │   │   │
│ │ │ ✅ PASS          │   │   │
│ │ └─────────────────┘   │   │
│ └───────────────────────┘   │
│                             │
│ ┌───────────────────────┐   │
│ │ 👤 You                │   │
│ │ Can you also add      │   │
│ │ error logging?        │   │
│ └───────────────────────┘   │
│                             │
├─────────────────────────────┤
│ [📎] Type a message... [→] │  ← 📎 = attach code context
├──────┬──────┬────┬────┬────┤
│Files │Search│Term│Chat│More│
└──────┴──────┴────┴────┴────┘
```

**Message bubble types:**

| Block Type | Rendering |
|-----------|-----------|
| `text` | Markdown with code blocks, syntax highlighted |
| `thinking` | Collapsed "Thinking..." accordion (tap to expand) |
| `tool_use: Edit` | Diff card: file path, line range, tap → code viewer with diff |
| `tool_use: Write` | "Created file" card, tap → code viewer |
| `tool_use: Bash` | Command card with collapsible output, status icon (✅/❌) |
| `tool_use: Read` | "Read file" pill, tap → code viewer at offset |
| `tool_use: Agent` | Subagent card: description, type badge, tap → expand subagent conversation |
| `tool_use: Grep/Glob` | Search result card with match count |
| `tool_result` | Inline below the tool_use that triggered it |

**Session list (tap "Sessions" in header):**

```
┌─────────────────────────────┐
│ ←  Chat Sessions            │
├─────────────────────────────┤
│ 🟢 Current session          │
│    vscode-mobile • 2m ago   │
│                             │
│ ⬚ Fix auth handler          │
│   redteam-forge • 1h ago    │
│                             │
│ ⬚ Setup project structure   │
│   aoyskill • 3h ago         │
│                             │
│ ⬚ Research paper plotting   │
│   paperops • yesterday      │
└─────────────────────────────┘
```

### 3. Contextual AI Chat (from code selection)

When user taps "Ask AI" in code viewer, a bottom sheet slides up:

```
┌─────────────────────────────┐
│ ←  main.go                  │
├─────────────────────────────┤
│  8│ func main() {           │
│  9│ ██████████████          │  (selected, dimmed)
│ 10│ ██████████████          │
│ 11│ }                       │
├─────────────────────────────┤  ← Draggable sheet divider
│ 📄 main.go:9-10             │  ← Context badge
│                             │
│ 🤖 Claude                   │
│ This code has a potential   │
│ race condition because...   │
│                             │
├─────────────────────────────┤
│ [📎] Type a message... [→] │
└─────────────────────────────┘
```

- Bottom sheet is draggable (expand to full screen / collapse)
- Context badge shows which file:lines are included
- Can add more code selections via 📎 button
- "Expand to full chat" button to move to Chat tab

### 4. Terminal Tab

```
┌─────────────────────────────┐
│ Terminal          [refresh]  │
├─────────────────────────────┤
│ $ ssh user@server            │
│ user@server:~$ ls            │
│ Documents  Downloads  src    │
│ user@server:~$ █             │
│                              │
│                              │
│                              │
├─────────────────────────────┤
│ $ [Enter command...]    [→] │
├──────┬──────┬────┬────┬────┤
│Files │Search│Term│Chat│More│
└──────┴──────┴────┴────┴────┘
```

- PTY-backed shell session via WebSocket
- ANSI color rendering (SGR 8/16/256 colors, bold/italic/underline)
- Adaptive terminal sizing based on screen dimensions
- CR/LF handling: CRLF collapsed to single newline, standalone CR overwrites line
- Lazy connection: WebSocket/PTY only created when Terminal tab is first viewed
- Reconnect button in app bar

### 5. More Tab — Git & Settings

```
┌─────────────────────────────┐
│ More                        │
├─────────────────────────────┤
│                             │
│ Git Status               [>]│  ← View changes, log, branches
│                             │
│ Settings                 [>]│  ← Server URL, auth token
│                             │
│ About                    [>]│  ← App info
│                             │
├──────┬──────┬────┬────┬────┤
│Files │Search│Term│Chat│More│
└──────┴──────┴────┴────┴────┘
```

### 5. Diff Viewer

```
┌─────────────────────────────┐
│ ←  server/auth.go    [⇄]  │  ← Toggle unified/split
├─────────────────────────────┤
│  40│   // unchanged          │
│  41│   // unchanged          │
│- 42│   if err != nil {       │  ← Red background
│- 43│     return err          │
│+ 42│   if err != nil {       │  ← Green background
│+ 43│     log.Error(err)      │
│+ 44│     return fmt.Errorf(  │
│+ 45│       "auth: %w", err)  │
│  44│   }                     │
│                              │
├──────┬──────┬────┬────┬─────┤
│Files │Search│Term│Chat│More │
└──────┴──────┴────┴────┴─────┘
```

## Widget Component Library

### Core Widgets

| Widget | Description | Used In |
|--------|-------------|---------|
| `FileTreeView` | Expandable directory tree with file icons | Files tab |
| `CodeViewer` | Syntax-highlighted code with selection support | Code view |
| `CodeEditor` | Simple text editor (extends CodeViewer with cursor + keyboard) | Edit mode |
| `DiffViewer` | Unified/split diff with syntax highlighting | Diff view, AI chat cards |
| `ChatBubble` | Message bubble with markdown rendering | Chat view |
| `ToolUseCard` | Tappable card for tool invocations (Edit/Bash/Read/Agent) | Chat view |
| `SubagentCard` | Expandable card showing subagent type, description, conversation | Chat view |
| `SessionListTile` | Session preview with project name, time, summary | Session list |
| `ContextBadge` | File:line reference pill | Contextual chat |
| `SelectionToolbar` | Floating toolbar on code selection | Code view |
| `AnsiText` | ANSI escape code renderer (SGR colors + styles) | Terminal |
| `ThinkingBlock` | Collapsible thinking block accordion | Chat view |

### Navigation Patterns

| Action | Gesture |
|--------|---------|
| Open file | Tap in file tree |
| Select code | Long-press + drag handles |
| Ask AI about selection | Tap "Ask AI" in selection toolbar |
| View file change from AI | Tap ToolUseCard in chat |
| Expand subagent | Tap SubagentCard |
| Toggle edit mode | Tap "Edit" button or pencil icon |
| Switch workspace | Tap workspace name in Files tab → picker with recent list + path input |
| View diff | Tap modified file in Git section |

## Color & Typography

- **Theme**: Follow system dark/light mode, Material Design 3
- **Code font**: JetBrains Mono or Fira Code (monospace)
- **UI font**: System default (Roboto on Android)
- **Syntax colors**: VS Code Dark+ / Light+ theme mappings
- **Diff colors**: Red (#FF4444) for deletions, Green (#44BB44) for additions

## State Management

- **Provider** for reactive state
- Key state objects:
  - `WorkspaceProvider` — current workspace path, recent list (persisted)
  - `FileProvider` — file tree nodes, scoped to workspace
  - `EditorProvider` — open files, selections, edit mode
  - `SearchProvider` — search results (file name + content), scoped to workspace
  - `ChatProvider` — WebSocket connection, conversation messages, streaming state
  - `GitProvider` — branch, status, diff, stage/unstage/commit
  - `SettingsService` — server URL, auth token (persisted)
