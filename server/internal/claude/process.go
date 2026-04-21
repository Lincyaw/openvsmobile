package claude

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os/exec"
	"sync"
	"time"

	"github.com/google/uuid"
)

const (
	defaultClaudeBin = "claude"
	shutdownTimeout  = 5 * time.Second
)

// ProcessManager manages Claude CLI processes.
type ProcessManager struct {
	mu         sync.RWMutex
	claudeBin  string
	workingDir string
	active     map[string]*Conversation
	shutdownCh chan struct{}
}

// NewProcessManager creates a new ProcessManager.
func NewProcessManager(claudeBin, workingDir string) *ProcessManager {
	if claudeBin == "" {
		claudeBin = defaultClaudeBin
	}
	return &ProcessManager{
		claudeBin:  claudeBin,
		workingDir: workingDir,
		active:     make(map[string]*Conversation),
		shutdownCh: make(chan struct{}),
	}
}

// Conversation represents a running Claude CLI process.
type Conversation struct {
	ID     string
	cmd    *exec.Cmd
	stdin  io.WriteCloser
	stdout io.ReadCloser
	Output chan StreamOutput
	done   chan struct{}
	cancel context.CancelFunc
	mu     sync.Mutex
	closed bool
}

// StartConversation spawns a new Claude CLI process.
func (pm *ProcessManager) StartConversation(workingDir string) (*Conversation, error) {
	if workingDir == "" {
		workingDir = pm.workingDir
	}

	ctx, cancel := context.WithCancel(context.Background())
	args := []string{"-p", "--verbose", "--output-format", "stream-json", "--input-format", "stream-json"}

	cmd := exec.CommandContext(ctx, pm.claudeBin, args...)
	cmd.Dir = workingDir

	stdin, err := cmd.StdinPipe()
	if err != nil {
		cancel()
		return nil, fmt.Errorf("creating stdin pipe: %w", err)
	}

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		cancel()
		return nil, fmt.Errorf("creating stdout pipe: %w", err)
	}

	if err := cmd.Start(); err != nil {
		cancel()
		return nil, fmt.Errorf("starting claude process: %w", err)
	}

	conv := &Conversation{
		ID:     uuid.New().String(),
		cmd:    cmd,
		stdin:  stdin,
		stdout: stdout,
		Output: make(chan StreamOutput, 1000),
		done:   make(chan struct{}),
		cancel: cancel,
	}

	go conv.readOutput()

	pm.mu.Lock()
	pm.active[conv.ID] = conv
	pm.mu.Unlock()

	log.Printf("[Claude] started conversation %s in %s", conv.ID, workingDir)
	return conv, nil
}

// ResumeConversation resumes an existing Claude session.
func (pm *ProcessManager) ResumeConversation(sessionID string) (*Conversation, error) {
	return pm.ResumeConversationInDir(sessionID, "")
}

// ResumeConversationInDir resumes an existing Claude session in a specific workspace.
func (pm *ProcessManager) ResumeConversationInDir(sessionID, workingDir string) (*Conversation, error) {
	ctx, cancel := context.WithCancel(context.Background())
	args := []string{"-p", "--verbose", "-r", sessionID, "--output-format", "stream-json", "--input-format", "stream-json"}

	cmd := exec.CommandContext(ctx, pm.claudeBin, args...)
	if workingDir == "" {
		workingDir = pm.workingDir
	}
	cmd.Dir = workingDir

	stdin, err := cmd.StdinPipe()
	if err != nil {
		cancel()
		return nil, fmt.Errorf("creating stdin pipe: %w", err)
	}

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		cancel()
		return nil, fmt.Errorf("creating stdout pipe: %w", err)
	}

	if err := cmd.Start(); err != nil {
		cancel()
		return nil, fmt.Errorf("starting claude process: %w", err)
	}

	conv := &Conversation{
		ID:     sessionID,
		cmd:    cmd,
		stdin:  stdin,
		stdout: stdout,
		Output: make(chan StreamOutput, 100),
		done:   make(chan struct{}),
		cancel: cancel,
	}

	go conv.readOutput()

	pm.mu.Lock()
	pm.active[conv.ID] = conv
	pm.mu.Unlock()

	log.Printf("[Claude] resumed conversation %s in %s", conv.ID, workingDir)
	return conv, nil
}

// Send sends a user message to the Claude CLI process.
func (c *Conversation) Send(message string) error {
	return c.SendWithContext(message, nil)
}

// SendWithContext sends a user message plus lightweight editor context.
func (c *Conversation) SendWithContext(message string, chatContext *ConversationContext) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.closed {
		return fmt.Errorf("conversation is closed")
	}

	input := StreamInput{
		Type: "user",
		Message: StreamInputMessage{
			Role:    "user",
			Content: formatMessageWithContext(message, chatContext),
		},
	}
	data, err := json.Marshal(input)
	if err != nil {
		return fmt.Errorf("marshaling input: %w", err)
	}
	data = append(data, '\n')

	if _, err := c.stdin.Write(data); err != nil {
		return fmt.Errorf("writing to stdin: %w", err)
	}
	return nil
}

func formatMessageWithContext(message string, chatContext *ConversationContext) string {
	if chatContext == nil {
		return message
	}

	contextJSON, err := json.Marshal(chatContext)
	if err != nil {
		return message
	}

	return fmt.Sprintf(
		"[mobile_editor_context]\n%s\n[/mobile_editor_context]\n\n%s",
		contextJSON,
		message,
	)
}

// Close gracefully shuts down the conversation.
func (c *Conversation) Close() error {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return nil
	}
	c.closed = true
	c.mu.Unlock()

	// Close stdin to signal EOF.
	c.stdin.Close()

	// Wait for process to exit with timeout.
	done := make(chan error, 1)
	go func() {
		done <- c.cmd.Wait()
	}()

	select {
	case <-done:
		// Process exited gracefully.
	case <-time.After(shutdownTimeout):
		// Force kill.
		c.cancel()
		<-done
	}

	// Wait for output reader to finish.
	<-c.done
	log.Printf("[Claude] closed conversation %s", c.ID)
	return nil
}

// Done returns a channel that is closed when the conversation ends.
func (c *Conversation) Done() <-chan struct{} {
	return c.done
}

// readOutput reads stdout from the Claude process and sends parsed output to the channel.
func (c *Conversation) readOutput() {
	defer close(c.done)
	defer close(c.Output)

	scanner := bufio.NewScanner(c.stdout)
	scanner.Buffer(make([]byte, 0, 64*1024), 10*1024*1024)

	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		var output StreamOutput
		if err := json.Unmarshal(line, &output); err != nil {
			continue
		}
		select {
		case c.Output <- output:
		default:
			log.Printf("warning: output channel full for conversation %s, dropping message of type %q", c.ID, output.Type)
		}
	}
}

// Shutdown gracefully shuts down all active conversations.
func (pm *ProcessManager) Shutdown() {
	pm.mu.Lock()
	conversations := make([]*Conversation, 0, len(pm.active))
	for _, conv := range pm.active {
		conversations = append(conversations, conv)
	}
	pm.active = make(map[string]*Conversation)
	pm.mu.Unlock()

	log.Printf("[Claude] shutting down %d conversation(s)", len(conversations))
	var wg sync.WaitGroup
	for _, conv := range conversations {
		wg.Add(1)
		go func(c *Conversation) {
			defer wg.Done()
			c.Close()
		}(conv)
	}
	wg.Wait()
}

// RemoveConversation removes a conversation from the active set.
func (pm *ProcessManager) RemoveConversation(id string) {
	pm.mu.Lock()
	defer pm.mu.Unlock()
	delete(pm.active, id)
}

// GetConversation retrieves an active conversation by ID.
func (pm *ProcessManager) GetConversation(id string) (*Conversation, bool) {
	pm.mu.RLock()
	defer pm.mu.RUnlock()
	conv, ok := pm.active[id]
	return conv, ok
}
