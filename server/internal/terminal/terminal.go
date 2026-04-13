package terminal

import (
	"fmt"
	"os"
	"os/exec"
	"sync"

	"github.com/creack/pty"
)

// Terminal represents a single PTY-backed shell session.
type Terminal struct {
	ID   string
	ptmx *os.File
	cmd  *exec.Cmd
	rows uint16
	cols uint16
	done chan struct{}
}

// Read reads raw bytes from the PTY.
func (t *Terminal) Read(buf []byte) (int, error) {
	return t.ptmx.Read(buf)
}

// Write writes raw bytes to the PTY (user input).
func (t *Terminal) Write(data []byte) (int, error) {
	return t.ptmx.Write(data)
}

// Wait blocks until the shell process exits.
func (t *Terminal) Wait() error {
	return t.cmd.Wait()
}

// Done returns a channel that closes when the terminal process exits.
func (t *Terminal) Done() <-chan struct{} {
	return t.done
}

// Manager manages multiple terminal sessions.
type Manager struct {
	mu        sync.Mutex
	terminals map[string]*Terminal
}

// NewManager creates a new terminal Manager.
func NewManager() *Manager {
	return &Manager{
		terminals: make(map[string]*Terminal),
	}
}

// Create spawns a new shell in a PTY and registers it under the given id.
func (m *Manager) Create(id string, shell string, workDir string, rows, cols uint16) (*Terminal, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if _, exists := m.terminals[id]; exists {
		return nil, fmt.Errorf("terminal %q already exists", id)
	}

	if shell == "" {
		shell = "/bin/bash"
	}

	cmd := exec.Command(shell)
	cmd.Dir = workDir
	cmd.Env = append(os.Environ(), "TERM=xterm-256color")

	winSize := &pty.Winsize{Rows: rows, Cols: cols}
	ptmx, err := pty.StartWithSize(cmd, winSize)
	if err != nil {
		return nil, fmt.Errorf("failed to start pty: %w", err)
	}

	t := &Terminal{
		ID:   id,
		ptmx: ptmx,
		cmd:  cmd,
		rows: rows,
		cols: cols,
		done: make(chan struct{}),
	}

	// Monitor process exit in a background goroutine.
	go func() {
		_ = cmd.Wait()
		close(t.done)
	}()

	m.terminals[id] = t
	return t, nil
}

// Get returns the terminal with the given id, if it exists.
func (m *Manager) Get(id string) (*Terminal, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	t, ok := m.terminals[id]
	return t, ok
}

// Resize changes the PTY window size for the given terminal.
func (m *Manager) Resize(id string, rows, cols uint16) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	t, ok := m.terminals[id]
	if !ok {
		return fmt.Errorf("terminal %q not found", id)
	}

	if err := pty.Setsize(t.ptmx, &pty.Winsize{Rows: rows, Cols: cols}); err != nil {
		return fmt.Errorf("failed to resize: %w", err)
	}
	t.rows = rows
	t.cols = cols
	return nil
}

// Close terminates the terminal with the given id.
func (m *Manager) Close(id string) error {
	m.mu.Lock()
	t, ok := m.terminals[id]
	if !ok {
		m.mu.Unlock()
		return fmt.Errorf("terminal %q not found", id)
	}
	delete(m.terminals, id)
	m.mu.Unlock()

	// Kill the process and close the PTY.
	if t.cmd.Process != nil {
		_ = t.cmd.Process.Kill()
	}
	return t.ptmx.Close()
}

// CloseAll terminates all managed terminals.
func (m *Manager) CloseAll() {
	m.mu.Lock()
	ids := make([]string, 0, len(m.terminals))
	for id := range m.terminals {
		ids = append(ids, id)
	}
	m.mu.Unlock()

	for _, id := range ids {
		_ = m.Close(id)
	}
}
