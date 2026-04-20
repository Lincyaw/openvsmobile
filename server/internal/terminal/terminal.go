package terminal

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"sync"
	"sync/atomic"

	"github.com/creack/pty"
)

const (
	StateRunning = "running"
	StateExited  = "exited"

	maxBacklogBytes = 64 * 1024
)

// Session is the stable terminal metadata exposed to API consumers.
type Session struct {
	ID               string         `json:"id"`
	Name             string         `json:"name"`
	Cwd              string         `json:"cwd"`
	Profile          string         `json:"profile"`
	State            string         `json:"state"`
	ExitCode         *int           `json:"exitCode,omitempty"`
	Rows             uint16         `json:"rows,omitempty"`
	Cols             uint16         `json:"cols,omitempty"`
	ShellIntegration map[string]any `json:"shellIntegration,omitempty"`
}

// Event is a lifecycle update emitted by the session manager.
type Event struct {
	Type    string
	Session Session
}

// CreateOptions configures new session creation.
type CreateOptions struct {
	ID      string
	Name    string
	Shell   string
	WorkDir string
	Profile string
	Rows    uint16
	Cols    uint16
}

// Attachment streams session output to a websocket client.
type Attachment struct {
	backlog []byte
	output  <-chan []byte
	closeFn func()
}

func (a *Attachment) Backlog() []byte {
	if a == nil || len(a.backlog) == 0 {
		return nil
	}
	return append([]byte(nil), a.backlog...)
}

func (a *Attachment) Output() <-chan []byte {
	if a == nil {
		return nil
	}
	return a.output
}

func (a *Attachment) Close() {
	if a != nil && a.closeFn != nil {
		a.closeFn()
	}
}

// Terminal represents a single PTY-backed shell session.
type Terminal struct {
	ID   string
	ptmx *os.File
	cmd  *exec.Cmd
	done chan struct{}

	mu               sync.RWMutex
	name             string
	cwd              string
	profile          string
	state            string
	exitCode         *int
	rows             uint16
	cols             uint16
	waitErr          error
	closeRequested   bool
	backlog          []byte
	subscribers      map[chan []byte]struct{}
	legacyReaderOnce sync.Once
	legacyReader     <-chan []byte
	legacyDetach     func()
	legacyBuf        bytes.Buffer
}

// Read reads output bytes from a subscription-backed compatibility stream.
func (t *Terminal) Read(buf []byte) (int, error) {
	t.legacyReaderOnce.Do(func() {
		attachment := t.attach()
		t.legacyReader = attachment.Output()
		t.legacyDetach = attachment.Close
		if backlog := attachment.Backlog(); len(backlog) > 0 {
			_, _ = t.legacyBuf.Write(backlog)
		}
	})

	for {
		if t.legacyBuf.Len() > 0 {
			return t.legacyBuf.Read(buf)
		}

		ch := t.legacyReader
		if ch == nil {
			return 0, io.EOF
		}
		chunk, ok := <-ch
		if !ok {
			if t.legacyDetach != nil {
				t.legacyDetach()
				t.legacyDetach = nil
			}
			t.legacyReader = nil
			return 0, io.EOF
		}
		if len(chunk) == 0 {
			continue
		}
		_, _ = t.legacyBuf.Write(chunk)
	}
}

// Write writes raw bytes to the PTY (user input).
func (t *Terminal) Write(data []byte) (int, error) {
	return t.ptmx.Write(data)
}

// Wait blocks until the shell process exits.
func (t *Terminal) Wait() error {
	<-t.done
	t.mu.RLock()
	defer t.mu.RUnlock()
	return t.waitErr
}

// Done returns a channel that closes when the terminal process exits.
func (t *Terminal) Done() <-chan struct{} {
	return t.done
}

// Snapshot returns the current terminal metadata.
func (t *Terminal) Snapshot() Session {
	t.mu.RLock()
	defer t.mu.RUnlock()
	return Session{
		ID:       t.ID,
		Name:     t.name,
		Cwd:      t.cwd,
		Profile:  t.profile,
		State:    t.state,
		ExitCode: cloneIntPointer(t.exitCode),
		Rows:     t.rows,
		Cols:     t.cols,
	}
}

func (t *Terminal) Rename(name string) {
	t.mu.Lock()
	t.name = name
	t.mu.Unlock()
}

func (t *Terminal) Resize(rows, cols uint16) error {
	if err := pty.Setsize(t.ptmx, &pty.Winsize{Rows: rows, Cols: cols}); err != nil {
		return fmt.Errorf("failed to resize: %w", err)
	}
	t.mu.Lock()
	t.rows = rows
	t.cols = cols
	t.mu.Unlock()
	return nil
}

func (t *Terminal) markClosing() {
	t.mu.Lock()
	t.closeRequested = true
	if t.state != StateExited {
		t.state = StateExited
	}
	t.mu.Unlock()
}

func (t *Terminal) recordOutput(chunk []byte) {
	if len(chunk) == 0 {
		return
	}

	t.mu.Lock()
	t.backlog = append(t.backlog, chunk...)
	if overflow := len(t.backlog) - maxBacklogBytes; overflow > 0 {
		t.backlog = append([]byte(nil), t.backlog[overflow:]...)
	}

	var dead []chan []byte
	for subscriber := range t.subscribers {
		payload := append([]byte(nil), chunk...)
		select {
		case subscriber <- payload:
		default:
			dead = append(dead, subscriber)
		}
	}
	for _, subscriber := range dead {
		delete(t.subscribers, subscriber)
		close(subscriber)
	}
	t.mu.Unlock()
}

func (t *Terminal) finish(waitErr error) {
	t.mu.Lock()
	t.waitErr = waitErr
	t.state = StateExited
	if code, ok := exitCodeFromError(waitErr); ok {
		t.exitCode = &code
	}
	for subscriber := range t.subscribers {
		close(subscriber)
	}
	t.subscribers = map[chan []byte]struct{}{}
	t.mu.Unlock()
	close(t.done)
}

func (t *Terminal) attach() *Attachment {
	t.mu.Lock()
	defer t.mu.Unlock()

	output := make(chan []byte, 32)
	t.subscribers[output] = struct{}{}
	backlog := append([]byte(nil), t.backlog...)

	if t.state == StateExited {
		close(output)
	}

	return &Attachment{
		backlog: backlog,
		output:  output,
		closeFn: func() {
			t.mu.Lock()
			if _, ok := t.subscribers[output]; ok {
				delete(t.subscribers, output)
				close(output)
			}
			t.mu.Unlock()
		},
	}
}

// Manager manages multiple terminal sessions.
type Manager struct {
	mu          sync.RWMutex
	terminals   map[string]*Terminal
	subscribers map[chan Event]struct{}
	sequence    atomic.Uint64
}

// NewManager creates a new terminal Manager.
func NewManager() *Manager {
	return &Manager{
		terminals:   make(map[string]*Terminal),
		subscribers: make(map[chan Event]struct{}),
	}
}

// Create preserves the legacy constructor used by older tests and callers.
func (m *Manager) Create(id string, shell string, workDir string, rows, cols uint16) (*Terminal, error) {
	return m.CreateSession(CreateOptions{
		ID:      id,
		Name:    id,
		Shell:   shell,
		WorkDir: workDir,
		Profile: shellProfile(shell),
		Rows:    rows,
		Cols:    cols,
	})
}

// CreateSession spawns a new shell in a PTY and registers it as a managed session.
func (m *Manager) CreateSession(opts CreateOptions) (*Terminal, error) {
	m.mu.Lock()

	id := opts.ID
	if id == "" {
		id = fmt.Sprintf("term-%d", m.sequence.Add(1))
	}
	if _, exists := m.terminals[id]; exists {
		m.mu.Unlock()
		return nil, fmt.Errorf("terminal %q already exists", id)
	}

	shell := opts.Shell
	if shell == "" {
		shell = "/bin/bash"
	}

	cmd := exec.Command(shell)
	cmd.Dir = opts.WorkDir
	cmd.Env = append(os.Environ(), "TERM=xterm-256color")

	winSize := &pty.Winsize{Rows: opts.Rows, Cols: opts.Cols}
	ptmx, err := pty.StartWithSize(cmd, winSize)
	if err != nil {
		m.mu.Unlock()
		return nil, fmt.Errorf("failed to start pty: %w", err)
	}

	name := opts.Name
	if name == "" {
		name = id
	}
	profile := opts.Profile
	if profile == "" {
		profile = shellProfile(shell)
	}

	t := &Terminal{
		ID:          id,
		ptmx:        ptmx,
		cmd:         cmd,
		done:        make(chan struct{}),
		name:        name,
		cwd:         opts.WorkDir,
		profile:     profile,
		state:       StateRunning,
		rows:        opts.Rows,
		cols:        opts.Cols,
		subscribers: make(map[chan []byte]struct{}),
	}

	m.terminals[id] = t
	m.mu.Unlock()
	log.Printf("[Terminal] created session %s (profile=%s, workDir=%s, rows=%d, cols=%d)", id, profile, opts.WorkDir, opts.Rows, opts.Cols)

	go m.pumpOutput(t)
	go m.waitProcess(t)
	m.broadcast(Event{Type: "terminal/session.created", Session: t.Snapshot()})
	return t, nil
}

// List returns the current sessions.
func (m *Manager) List() []Session {
	m.mu.RLock()
	defer m.mu.RUnlock()

	sessions := make([]Session, 0, len(m.terminals))
	for _, terminal := range m.terminals {
		sessions = append(sessions, terminal.Snapshot())
	}
	return sessions
}

// Get returns the terminal with the given id, if it exists.
func (m *Manager) Get(id string) (*Terminal, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	t, ok := m.terminals[id]
	return t, ok
}

// Attach subscribes to the terminal output stream without affecting session lifetime.
func (m *Manager) Attach(id string) (*Attachment, error) {
	terminal, ok := m.Get(id)
	if !ok {
		return nil, fmt.Errorf("terminal %q not found", id)
	}
	return terminal.attach(), nil
}

// Rename updates the session display name.
func (m *Manager) Rename(id, name string) (Session, error) {
	terminal, ok := m.Get(id)
	if !ok {
		return Session{}, fmt.Errorf("terminal %q not found", id)
	}
	terminal.Rename(name)
	snapshot := terminal.Snapshot()
	m.broadcast(Event{Type: "terminal/session.updated", Session: snapshot})
	return snapshot, nil
}

// Resize changes the PTY window size for the given terminal.
func (m *Manager) Resize(id string, rows, cols uint16) error {
	terminal, ok := m.Get(id)
	if !ok {
		return fmt.Errorf("terminal %q not found", id)
	}
	if err := terminal.Resize(rows, cols); err != nil {
		return err
	}
	log.Printf("[Terminal] resized session %s to rows=%d, cols=%d", id, rows, cols)
	m.broadcast(Event{Type: "terminal/session.updated", Session: terminal.Snapshot()})
	return nil
}

// ResizeSession resizes a session and returns the updated metadata.
func (m *Manager) ResizeSession(id string, rows, cols uint16) (Session, error) {
	if err := m.Resize(id, rows, cols); err != nil {
		return Session{}, err
	}
	terminal, _ := m.Get(id)
	return terminal.Snapshot(), nil
}

// Split creates a sibling session inheriting the parent cwd/profile.
func (m *Manager) Split(parentID, name string) (Session, error) {
	parent, ok := m.Get(parentID)
	if !ok {
		return Session{}, fmt.Errorf("terminal %q not found", parentID)
	}
	parentSnapshot := parent.Snapshot()
	child, err := m.CreateSession(CreateOptions{
		Name:    firstNonEmpty(name, parentSnapshot.Name+" split"),
		Shell:   parentSnapshot.Profile,
		WorkDir: parentSnapshot.Cwd,
		Profile: parentSnapshot.Profile,
		Rows:    parentSnapshot.Rows,
		Cols:    parentSnapshot.Cols,
	})
	if err != nil {
		return Session{}, err
	}
	return child.Snapshot(), nil
}

// Close terminates the session and removes it from the manager.
func (m *Manager) Close(id string) error {
	_, err := m.CloseSession(id)
	return err
}

// CloseSession terminates the session, removes it from the manager, and returns its final metadata.
func (m *Manager) CloseSession(id string) (Session, error) {
	m.mu.Lock()
	terminal, ok := m.terminals[id]
	if !ok {
		m.mu.Unlock()
		return Session{}, fmt.Errorf("terminal %q not found", id)
	}
	delete(m.terminals, id)
	m.mu.Unlock()

	terminal.markClosing()
	if terminal.cmd.Process != nil {
		_ = terminal.cmd.Process.Kill()
	}
	_ = terminal.ptmx.Close()
	snapshot := terminal.Snapshot()
	log.Printf("[Terminal] closed session %s", id)
	m.broadcast(Event{Type: "terminal/session.closed", Session: snapshot})
	return snapshot, nil
}

// SubscribeEvents registers for terminal lifecycle events.
func (m *Manager) SubscribeEvents() (<-chan Event, func()) {
	ch := make(chan Event, 16)

	m.mu.Lock()
	m.subscribers[ch] = struct{}{}
	m.mu.Unlock()

	return ch, func() {
		m.mu.Lock()
		if _, ok := m.subscribers[ch]; ok {
			delete(m.subscribers, ch)
			close(ch)
		}
		m.mu.Unlock()
	}
}

// CloseAll terminates all managed terminals.
func (m *Manager) CloseAll() {
	m.mu.RLock()
	ids := make([]string, 0, len(m.terminals))
	for id := range m.terminals {
		ids = append(ids, id)
	}
	m.mu.RUnlock()

	for _, id := range ids {
		_, _ = m.CloseSession(id)
	}
}

func (m *Manager) pumpOutput(terminal *Terminal) {
	buf := make([]byte, 4096)
	for {
		n, err := terminal.ptmx.Read(buf)
		if n > 0 {
			terminal.recordOutput(buf[:n])
		}
		if err != nil {
			if !errors.Is(err, io.EOF) {
				log.Printf("[Terminal] output pump closed for %s: %v", terminal.ID, err)
			}
			return
		}
	}
}

func (m *Manager) waitProcess(terminal *Terminal) {
	err := terminal.cmd.Wait()
	terminal.finish(err)
	if terminal.closeRequested {
		return
	}
	m.broadcast(Event{Type: "terminal/session.updated", Session: terminal.Snapshot()})
}

func (m *Manager) broadcast(event Event) {
	m.mu.RLock()
	var dead []chan Event
	for subscriber := range m.subscribers {
		select {
		case subscriber <- event:
		default:
			dead = append(dead, subscriber)
		}
	}
	m.mu.RUnlock()

	if len(dead) == 0 {
		return
	}

	m.mu.Lock()
	for _, subscriber := range dead {
		if _, ok := m.subscribers[subscriber]; ok {
			delete(m.subscribers, subscriber)
			close(subscriber)
		}
	}
	m.mu.Unlock()
}

func cloneIntPointer(value *int) *int {
	if value == nil {
		return nil
	}
	copy := *value
	return &copy
}

func exitCodeFromError(err error) (int, bool) {
	if err == nil {
		return 0, true
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		return exitErr.ExitCode(), true
	}
	return 0, false
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}

func shellProfile(shell string) string {
	switch shell {
	case "", "/bin/bash", "/usr/bin/bash", "bash":
		return "bash"
	case "/bin/zsh", "/usr/bin/zsh", "zsh":
		return "zsh"
	case "/bin/sh", "sh":
		return "sh"
	default:
		return shell
	}
}
