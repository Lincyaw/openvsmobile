package vscode

import (
	"context"
	"fmt"
	"sync"
)

const workspaceChannelName = "openvsmobile/workspace"

// WorkspaceFolderDocument describes one active workspace folder from the runtime.
type WorkspaceFolderDocument struct {
	URI   string `json:"uri,omitempty"`
	Path  string `json:"path"`
	Name  string `json:"name,omitempty"`
	Index int    `json:"index,omitempty"`
}

// WorkspaceSymbolDocument is the runtime-backed workspace symbol entry.
type WorkspaceSymbolDocument struct {
	Name          string        `json:"name"`
	ContainerName string        `json:"containerName,omitempty"`
	Kind          int           `json:"kind"`
	Tags          []int         `json:"tags,omitempty"`
	URI           string        `json:"uri,omitempty"`
	Path          string        `json:"path,omitempty"`
	Range         DocumentRange `json:"range"`
}

// WorkspaceSearchResultDocument mirrors the existing content-search payload shape.
type WorkspaceSearchResultDocument struct {
	File        string `json:"file"`
	Line        int    `json:"line"`
	Column      int    `json:"column,omitempty"`
	Content     string `json:"content"`
	LinesBefore string `json:"linesBefore,omitempty"`
	LinesAfter  string `json:"linesAfter,omitempty"`
}

// WorkspaceFileResultDocument mirrors the existing file-search payload shape.
type WorkspaceFileResultDocument struct {
	Path  string `json:"path"`
	Name  string `json:"name"`
	IsDir bool   `json:"isDir"`
}

// WorkspaceProblemDocument is the bridge-backed problems panel item.
type WorkspaceProblemDocument struct {
	URI      string        `json:"uri,omitempty"`
	Path     string        `json:"path,omitempty"`
	Range    DocumentRange `json:"range"`
	Severity any           `json:"severity,omitempty"`
	Code     any           `json:"code,omitempty"`
	Source   string        `json:"source,omitempty"`
	Message  string        `json:"message"`
	Tags     []int         `json:"tags,omitempty"`
}

// WorkspaceChangedEnvelope is published over the unified bridge event stream.
type WorkspaceChangedEnvelope struct {
	Type           string                    `json:"type"`
	WorkbenchState string                    `json:"workbenchState,omitempty"`
	Folders        []WorkspaceFolderDocument `json:"folders"`
	Added          []WorkspaceFolderDocument `json:"added,omitempty"`
	Removed        []WorkspaceFolderDocument `json:"removed,omitempty"`
	Changed        []WorkspaceFolderDocument `json:"changed,omitempty"`
}

// WorkspaceQuery bundles the shared workspace bridge request fields.
type WorkspaceQuery struct {
	Query   string `json:"query,omitempty"`
	WorkDir string `json:"workDir,omitempty"`
	Max     int    `json:"max,omitempty"`
}

// WorkspaceService talks to the runtime bridge workspace adapter.
type WorkspaceService struct {
	client      *Client
	bridge      *BridgeManager
	channelName string

	mu            sync.Mutex
	workspaceStop func()
	lifecycleStop func()
}

// NewWorkspaceService creates a bridge-backed workspace service.
func NewWorkspaceService(client *Client, bridge *BridgeManager) *WorkspaceService {
	return &WorkspaceService{
		client:      client,
		bridge:      bridge,
		channelName: workspaceChannelName,
	}
}

// Start binds workspace-change subscriptions to the bridge lifecycle.
func (s *WorkspaceService) Start(ctx context.Context) {
	if s == nil || s.bridge == nil {
		return
	}

	events, unsubscribe := s.bridge.Subscribe(false)
	s.mu.Lock()
	s.lifecycleStop = unsubscribe
	s.mu.Unlock()

	go func() {
		defer unsubscribe()
		defer s.disposeWorkspaceWatcher()
		for {
			select {
			case <-ctx.Done():
				return
			case event, ok := <-events:
				if !ok {
					return
				}
				switch event.Type {
				case "bridge/ready", "bridge/restarted":
					_ = s.subscribeWorkspaceChanges(ctx)
				}
			}
		}
	}()
}

func (s *WorkspaceService) Close() {
	if s == nil {
		return
	}
	s.mu.Lock()
	stop := s.lifecycleStop
	s.lifecycleStop = nil
	s.mu.Unlock()
	if stop != nil {
		stop()
	}
	s.disposeWorkspaceWatcher()
}

func (s *WorkspaceService) Folders() ([]WorkspaceFolderDocument, error) {
	channel, err := s.ipcChannel()
	if err != nil {
		return nil, err
	}
	raw, err := channel.Call("folders", nil)
	if err != nil {
		return nil, newBridgeError("workspace_command_failed", "failed to list workspace folders", err)
	}
	var folders []WorkspaceFolderDocument
	if err := decodeJSON(raw, &folders); err != nil {
		return nil, newBridgeError("workspace_command_failed", "failed to decode workspace folders", err)
	}
	if folders == nil {
		folders = []WorkspaceFolderDocument{}
	}
	return folders, nil
}

func (s *WorkspaceService) Symbols(query WorkspaceQuery) ([]WorkspaceSymbolDocument, error) {
	return s.callSymbols("symbols", query, "failed to query workspace symbols")
}

func (s *WorkspaceService) SearchFiles(query WorkspaceQuery) ([]WorkspaceFileResultDocument, error) {
	channel, err := s.ipcChannel()
	if err != nil {
		return nil, err
	}
	raw, err := channel.Call("searchFiles", query)
	if err != nil {
		return nil, newBridgeError("workspace_command_failed", "failed to search workspace files", err)
	}
	var results []WorkspaceFileResultDocument
	if err := decodeJSON(raw, &results); err != nil {
		return nil, newBridgeError("workspace_command_failed", "failed to decode workspace file search results", err)
	}
	if results == nil {
		results = []WorkspaceFileResultDocument{}
	}
	return results, nil
}

func (s *WorkspaceService) SearchText(query WorkspaceQuery) ([]WorkspaceSearchResultDocument, error) {
	channel, err := s.ipcChannel()
	if err != nil {
		return nil, err
	}
	raw, err := channel.Call("searchText", query)
	if err != nil {
		return nil, newBridgeError("workspace_command_failed", "failed to search workspace contents", err)
	}
	var results []WorkspaceSearchResultDocument
	if err := decodeJSON(raw, &results); err != nil {
		return nil, newBridgeError("workspace_command_failed", "failed to decode workspace text search results", err)
	}
	if results == nil {
		results = []WorkspaceSearchResultDocument{}
	}
	return results, nil
}

func (s *WorkspaceService) Problems(query WorkspaceQuery) ([]WorkspaceProblemDocument, error) {
	channel, err := s.ipcChannel()
	if err != nil {
		return nil, err
	}
	raw, err := channel.Call("problems", query)
	if err != nil {
		return nil, newBridgeError("workspace_command_failed", "failed to load workspace problems", err)
	}
	var problems []WorkspaceProblemDocument
	if err := decodeJSON(raw, &problems); err != nil {
		return nil, newBridgeError("workspace_command_failed", "failed to decode workspace problems", err)
	}
	if problems == nil {
		problems = []WorkspaceProblemDocument{}
	}
	return problems, nil
}

func (s *WorkspaceService) callSymbols(command string, query WorkspaceQuery, message string) ([]WorkspaceSymbolDocument, error) {
	channel, err := s.ipcChannel()
	if err != nil {
		return nil, err
	}
	raw, err := channel.Call(command, query)
	if err != nil {
		return nil, newBridgeError("workspace_command_failed", message, err)
	}
	var symbols []WorkspaceSymbolDocument
	if err := decodeJSON(raw, &symbols); err != nil {
		return nil, newBridgeError("workspace_command_failed", "failed to decode workspace symbols", err)
	}
	if symbols == nil {
		symbols = []WorkspaceSymbolDocument{}
	}
	return symbols, nil
}

func (s *WorkspaceService) subscribeWorkspaceChanges(ctx context.Context) error {
	channel, err := s.ipcChannel()
	if err != nil {
		return err
	}
	events, dispose, err := channel.ListenContext(ctx, "workspaceChanged", map[string]any{})
	if err != nil {
		return newBridgeError("workspace_subscription_failed", "failed to subscribe to workspace updates", err)
	}

	s.mu.Lock()
	if old := s.workspaceStop; old != nil {
		old()
	}
	s.workspaceStop = dispose
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
				envelope, err := decodeWorkspaceChangedEnvelope(raw)
				if err != nil {
					continue
				}
				if envelope.Type == "" {
					envelope.Type = "foldersChanged"
				}
				if s.bridge != nil {
					s.bridge.Publish(BridgeEvent{Type: fmt.Sprintf("workspace/%s", envelope.Type), Payload: envelope})
				}
			}
		}
	}()

	return nil
}

func (s *WorkspaceService) disposeWorkspaceWatcher() {
	s.mu.Lock()
	stop := s.workspaceStop
	s.workspaceStop = nil
	s.mu.Unlock()
	if stop != nil {
		stop()
	}
}

func (s *WorkspaceService) ipcChannel() (*IPCChannel, error) {
	if s.client == nil || s.client.IPC() == nil {
		return nil, newBridgeError("bridge_not_ready", "mobile runtime bridge is not ready", nil)
	}
	if s.bridge != nil {
		if err := s.bridge.RequireCapability("workspace"); err != nil {
			return nil, err
		}
	}
	return s.client.IPC().GetChannel(s.channelName), nil
}

func decodeWorkspaceChangedEnvelope(raw interface{}) (WorkspaceChangedEnvelope, error) {
	var envelope WorkspaceChangedEnvelope
	if err := decodeJSON(raw, &envelope); err != nil {
		return WorkspaceChangedEnvelope{}, err
	}
	return envelope, nil
}
