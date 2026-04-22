package vscode

import (
	"context"
	"encoding/base64"
	"fmt"
	"sync"

	"github.com/Lincyaw/vscode-mobile/server/internal/terminal"
)

const terminalChannelName = "openvsmobile/terminal"

type terminalAttachDocument struct {
	Session terminal.Session `json:"session"`
	Backlog string           `json:"backlog,omitempty"`
}

type terminalLifecycleEnvelope struct {
	Type    string           `json:"type"`
	Session terminal.Session `json:"session"`
}

type terminalStreamEnvelope struct {
	Type    string           `json:"type"`
	Data    string           `json:"data,omitempty"`
	Session terminal.Session `json:"session,omitempty"`
}

type TerminalService struct {
	client      *Client
	bridge      *BridgeManager
	channelName string

	mu          sync.RWMutex
	subscribers map[chan terminal.Event]struct{}
	stop        func()
}

func NewTerminalService(client *Client, bridge *BridgeManager) *TerminalService {
	return &TerminalService{
		client:      client,
		bridge:      bridge,
		channelName: terminalChannelName,
		subscribers: make(map[chan terminal.Event]struct{}),
	}
}

func (s *TerminalService) Start(ctx context.Context) error {
	if s == nil {
		return nil
	}
	if s.client == nil || s.client.IPC() == nil {
		return nil
	}
	channel := s.client.IPC().GetChannel(s.channelName)
	events, dispose, err := channel.Listen("sessionChanged", nil)
	if err != nil {
		return newBridgeError("terminal_subscription_failed", "failed to subscribe to bridge terminal updates", err)
	}
	s.mu.Lock()
	s.stop = dispose
	s.mu.Unlock()

	go func() {
		defer dispose()
		for {
			select {
			case <-ctx.Done():
				return
			case raw, ok := <-events:
				if !ok {
					return
				}
				envelope, err := decodeTerminalLifecycleEnvelope(raw)
				if err != nil {
					continue
				}
				s.broadcast(envelope)
			}
		}
	}()
	return nil
}

func (s *TerminalService) Close() {
	if s == nil {
		return
	}
	s.mu.Lock()
	stop := s.stop
	s.stop = nil
	s.mu.Unlock()
	if stop != nil {
		stop()
	}
}

func (s *TerminalService) List() ([]terminal.Session, error) {
	channel, err := s.ipcChannel()
	if err != nil {
		return nil, err
	}
	raw, err := channel.Call("list", nil)
	if err != nil {
		return nil, newBridgeError("terminal_command_failed", "failed to list bridge terminal sessions", err)
	}
	var sessions []terminal.Session
	if err := decodeJSON(raw, &sessions); err != nil {
		return nil, newBridgeError("terminal_command_failed", "failed to decode bridge terminal sessions", err)
	}
	if sessions == nil {
		sessions = []terminal.Session{}
	}
	return sessions, nil
}

func (s *TerminalService) CreateSession(opts terminal.CreateOptions) (terminal.Session, error) {
	payload := map[string]any{
		"name":    opts.Name,
		"cwd":     opts.WorkDir,
		"profile": opts.Profile,
		"rows":    opts.Rows,
		"cols":    opts.Cols,
	}
	return s.callSession("create", payload)
}

func (s *TerminalService) AttachSession(id string) (terminal.Session, []byte, error) {
	channel, err := s.ipcChannel()
	if err != nil {
		return terminal.Session{}, nil, err
	}
	raw, err := channel.Call("attach", map[string]any{"id": id})
	if err != nil {
		return terminal.Session{}, nil, newBridgeError("terminal_command_failed", "failed to attach to bridge terminal session", err)
	}
	doc, err := decodeTerminalAttachDocument(raw)
	if err != nil {
		return terminal.Session{}, nil, newBridgeError("terminal_command_failed", "failed to decode bridge terminal attachment", err)
	}
	var backlog []byte
	if doc.Backlog != "" {
		backlog, err = base64.StdEncoding.DecodeString(doc.Backlog)
		if err != nil {
			return terminal.Session{}, nil, newBridgeError("terminal_command_failed", "failed to decode bridge terminal backlog", err)
		}
	}
	return doc.Session, backlog, nil
}

func (s *TerminalService) Attach(id string) (*terminal.Attachment, terminal.Session, error) {
	session, backlog, err := s.AttachSession(id)
	if err != nil {
		return nil, terminal.Session{}, err
	}
	channel, err := s.ipcChannel()
	if err != nil {
		return nil, terminal.Session{}, err
	}
	events, dispose, err := channel.Listen("stream", map[string]any{"id": id})
	if err != nil {
		return nil, terminal.Session{}, newBridgeError("terminal_subscription_failed", "failed to subscribe to bridge terminal stream", err)
	}
	output := make(chan []byte, 64)
	go func() {
		defer close(output)
		defer dispose()
		for raw := range events {
			envelope, err := decodeTerminalStreamEnvelope(raw)
			if err != nil {
				continue
			}
			switch envelope.Type {
			case "output":
				if envelope.Data == "" {
					continue
				}
				chunk, err := base64.StdEncoding.DecodeString(envelope.Data)
				if err != nil {
					continue
				}
				output <- chunk
			case "exit", "closed":
				return
			}
		}
	}()
	return terminal.NewAttachment(backlog, output, dispose), session, nil
}

func (s *TerminalService) Input(id string, data []byte) error {
	_, err := s.callSession("input", map[string]any{
		"id":   id,
		"data": string(data),
	})
	return err
}

func (s *TerminalService) ResizeSession(id string, rows, cols uint16) (terminal.Session, error) {
	return s.callSession("resize", map[string]any{
		"id":   id,
		"rows": rows,
		"cols": cols,
	})
}

func (s *TerminalService) Rename(id, name string) (terminal.Session, error) {
	return s.callSession("rename", map[string]any{
		"id":   id,
		"name": name,
	})
}

func (s *TerminalService) Split(parentID, name string) (terminal.Session, error) {
	payload := map[string]any{"parentId": parentID}
	if name != "" {
		payload["name"] = name
	}
	return s.callSession("split", payload)
}

func (s *TerminalService) CloseSession(id string) (terminal.Session, error) {
	return s.callSession("close", map[string]any{"id": id})
}

func (s *TerminalService) SubscribeEvents() (<-chan terminal.Event, func()) {
	ch := make(chan terminal.Event, 16)
	s.mu.Lock()
	s.subscribers[ch] = struct{}{}
	s.mu.Unlock()
	return ch, func() {
		s.mu.Lock()
		if _, ok := s.subscribers[ch]; ok {
			delete(s.subscribers, ch)
			close(ch)
		}
		s.mu.Unlock()
	}
}

func (s *TerminalService) callSession(command string, payload map[string]any) (terminal.Session, error) {
	channel, err := s.ipcChannel()
	if err != nil {
		return terminal.Session{}, err
	}
	raw, err := channel.Call(command, payload)
	if err != nil {
		return terminal.Session{}, newBridgeError("terminal_command_failed", fmt.Sprintf("terminal %s failed", command), err)
	}
	var session terminal.Session
	if err := decodeJSON(raw, &session); err != nil {
		return terminal.Session{}, newBridgeError("terminal_command_failed", "failed to decode bridge terminal session", err)
	}
	return session, nil
}

func (s *TerminalService) broadcast(envelope terminalLifecycleEnvelope) {
	event := terminal.Event{
		Type:    mapTerminalLifecycleType(envelope.Type),
		Session: envelope.Session,
	}
	s.mu.RLock()
	var dead []chan terminal.Event
	for subscriber := range s.subscribers {
		select {
		case subscriber <- event:
		default:
			dead = append(dead, subscriber)
		}
	}
	s.mu.RUnlock()
	if len(dead) == 0 {
		return
	}
	s.mu.Lock()
	for _, subscriber := range dead {
		if _, ok := s.subscribers[subscriber]; ok {
			delete(s.subscribers, subscriber)
			close(subscriber)
		}
	}
	s.mu.Unlock()
}

func (s *TerminalService) ipcChannel() (*IPCChannel, error) {
	if s.client == nil || s.client.IPC() == nil {
		return nil, newBridgeError("bridge_not_ready", "mobile runtime bridge is not ready", nil)
	}
	if s.bridge != nil {
		if err := s.bridge.RequireCapability("terminal"); err != nil {
			return nil, err
		}
	}
	return s.client.IPC().GetChannel(s.channelName), nil
}

func decodeTerminalAttachDocument(raw interface{}) (terminalAttachDocument, error) {
	var doc terminalAttachDocument
	if err := decodeJSON(raw, &doc); err != nil {
		return terminalAttachDocument{}, err
	}
	return doc, nil
}

func decodeTerminalLifecycleEnvelope(raw interface{}) (terminalLifecycleEnvelope, error) {
	var envelope terminalLifecycleEnvelope
	if err := decodeJSON(raw, &envelope); err != nil {
		return terminalLifecycleEnvelope{}, err
	}
	return envelope, nil
}

func decodeTerminalStreamEnvelope(raw interface{}) (terminalStreamEnvelope, error) {
	var envelope terminalStreamEnvelope
	if err := decodeJSON(raw, &envelope); err != nil {
		return terminalStreamEnvelope{}, err
	}
	return envelope, nil
}

func mapTerminalLifecycleType(raw string) string {
	switch raw {
	case "created":
		return "terminal/session.created"
	case "closed":
		return "terminal/session.closed"
	default:
		return "terminal/session.updated"
	}
}
