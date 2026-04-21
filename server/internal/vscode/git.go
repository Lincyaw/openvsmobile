package vscode

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"path/filepath"
	"strings"
	"sync"
)

const gitChannelName = "openvsmobile/git"

// GitRepositoryDocument mirrors the VS Code Source Control repository state.
type GitRepositoryDocument struct {
	Path         string      `json:"path"`
	Branch       string      `json:"branch,omitempty"`
	Upstream     string      `json:"upstream,omitempty"`
	Ahead        int         `json:"ahead"`
	Behind       int         `json:"behind"`
	Remotes      []GitRemote `json:"remotes"`
	Staged       []GitChange `json:"staged"`
	Unstaged     []GitChange `json:"unstaged"`
	Untracked    []GitChange `json:"untracked"`
	Conflicts    []GitChange `json:"conflicts"`
	MergeChanges []GitChange `json:"mergeChanges"`
}

// GitDiffDocument represents the diff payload for a single file.
type GitDiffDocument struct {
	Path   string `json:"path"`
	Diff   string `json:"diff"`
	Staged bool   `json:"staged"`
}

// GitRemote describes a Git remote exposed through the bridge.
type GitRemote struct {
	Name       string   `json:"name"`
	FetchURL   string   `json:"fetchUrl,omitempty"`
	PushURL    string   `json:"pushUrl,omitempty"`
	IsReadOnly bool     `json:"isReadOnly,omitempty"`
	Branches   []string `json:"branches,omitempty"`
}

// GitMergeStatus captures merge-specific metadata without flattening it into a string.
type GitMergeStatus struct {
	Kind     string `json:"kind,omitempty"`
	Current  string `json:"current,omitempty"`
	Incoming string `json:"incoming,omitempty"`
}

// GitChange represents one file in a Source Control resource group.
type GitChange struct {
	Path              string          `json:"path"`
	OriginalPath      string          `json:"originalPath,omitempty"`
	Status            string          `json:"status,omitempty"`
	IndexStatus       string          `json:"indexStatus,omitempty"`
	WorkingTreeStatus string          `json:"workingTreeStatus,omitempty"`
	MergeStatus       *GitMergeStatus `json:"mergeStatus,omitempty"`
}

// GitService talks to the runtime bridge's Git adapter and republishes state changes.
type GitService struct {
	client      *Client
	bridge      *BridgeManager
	channelName string

	mu            sync.Mutex
	watchedPaths  map[string]struct{}
	watchStops    map[string]func()
	lifecycleStop func()
}

// NewGitService creates a bridge-backed Git repository service.
func NewGitService(client *Client, bridge *BridgeManager) *GitService {
	return &GitService{
		client:       client,
		bridge:       bridge,
		channelName:  gitChannelName,
		watchedPaths: make(map[string]struct{}),
		watchStops:   make(map[string]func()),
	}
}

// Start binds repository-change subscriptions to the bridge lifecycle.
func (s *GitService) Start(ctx context.Context) {
	if s == nil || s.bridge == nil {
		return
	}

	events, unsubscribe := s.bridge.Subscribe(false)
	s.mu.Lock()
	s.lifecycleStop = unsubscribe
	s.mu.Unlock()

	go func() {
		defer unsubscribe()
		defer s.disposeAllWatchers()
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
					s.resubscribeAll(ctx)
				}
			}
		}
	}()
}

func (s *GitService) Close() {
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
	s.disposeAllWatchers()
}

func (s *GitService) GetRepository(path string) (GitRepositoryDocument, error) {
	if err := s.ensureRepositoryWatch(context.Background(), path); err != nil {
		return GitRepositoryDocument{}, err
	}
	return s.fetchRepository(path)
}

func (s *GitService) Stage(path string, files []string) (GitRepositoryDocument, error) {
	return s.runCommandAndRefresh(path, "stage", map[string]any{"path": path, "files": files})
}

func (s *GitService) Unstage(path string, files []string) (GitRepositoryDocument, error) {
	return s.runCommandAndRefresh(path, "unstage", map[string]any{"path": path, "files": files})
}

func (s *GitService) Commit(path, message string) (GitRepositoryDocument, error) {
	return s.runCommandAndRefresh(path, "commit", map[string]any{"path": path, "message": message})
}

func (s *GitService) Checkout(path, ref string, create bool) (GitRepositoryDocument, error) {
	return s.runCommandAndRefresh(path, "checkout", map[string]any{"path": path, "ref": ref, "create": create})
}

func (s *GitService) Fetch(path, remote string) (GitRepositoryDocument, error) {
	payload := map[string]any{"path": path}
	if remote != "" {
		payload["remote"] = remote
	}
	return s.runCommandAndRefresh(path, "fetch", payload)
}

func (s *GitService) Pull(path, remote, branch string) (GitRepositoryDocument, error) {
	payload := map[string]any{"path": path}
	if remote != "" {
		payload["remote"] = remote
	}
	if branch != "" {
		payload["branch"] = branch
	}
	return s.runCommandAndRefresh(path, "pull", payload)
}

func (s *GitService) Push(path, remote, branch string, setUpstream bool) (GitRepositoryDocument, error) {
	payload := map[string]any{"path": path, "setUpstream": setUpstream}
	if remote != "" {
		payload["remote"] = remote
	}
	if branch != "" {
		payload["branch"] = branch
	}
	return s.runCommandAndRefresh(path, "push", payload)
}

func (s *GitService) Discard(path string, files []string) (GitRepositoryDocument, error) {
	return s.runCommandAndRefresh(path, "discard", map[string]any{"path": path, "files": files})
}

func (s *GitService) Diff(path, file string, staged bool) (GitDiffDocument, error) {
	if err := s.ensureRepositoryWatch(context.Background(), path); err != nil {
		return GitDiffDocument{}, err
	}
	channel, err := s.ipcChannel()
	if err != nil {
		return GitDiffDocument{}, err
	}
	response, err := channel.Call("diff", map[string]any{
		"path":   path,
		"file":   file,
		"staged": staged,
	})
	if err != nil {
		return GitDiffDocument{}, newBridgeError("git_command_failed", "git diff failed", err)
	}
	diff, err := decodeDiffDocument(response)
	if err != nil {
		return GitDiffDocument{}, newBridgeError("git_command_failed", "failed to decode bridge git diff", err)
	}
	if diff.Path == "" {
		diff.Path = file
	}
	diff.Staged = staged
	return diff, nil
}

func (s *GitService) Stash(path, message string, includeUntracked bool) (GitRepositoryDocument, error) {
	payload := map[string]any{"path": path, "includeUntracked": includeUntracked}
	if message != "" {
		payload["message"] = message
	}
	return s.runCommandAndRefresh(path, "stash", payload)
}

func (s *GitService) StashApply(path, stash string, pop bool) (GitRepositoryDocument, error) {
	payload := map[string]any{"path": path, "pop": pop}
	if stash != "" {
		payload["stash"] = stash
	}
	return s.runCommandAndRefresh(path, "stash/apply", payload)
}

func (s *GitService) runCommandAndRefresh(path, command string, payload map[string]any) (GitRepositoryDocument, error) {
	if err := s.ensureRepositoryWatch(context.Background(), path); err != nil {
		return GitRepositoryDocument{}, err
	}
	channel, err := s.ipcChannel()
	if err != nil {
		return GitRepositoryDocument{}, err
	}
	response, err := channel.Call(command, payload)
	if err != nil {
		return GitRepositoryDocument{}, newBridgeError("git_command_failed", fmt.Sprintf("git %s failed", command), err)
	}
	if repo, decodeErr := decodeRepositoryDocument(response); decodeErr == nil {
		repo.Path = path
		s.publishRepositoryChanged(repo)
		return repo, nil
	}
	repo, err := s.fetchRepository(path)
	if err != nil {
		return GitRepositoryDocument{}, err
	}
	s.publishRepositoryChanged(repo)
	return repo, nil
}

func (s *GitService) fetchRepository(path string) (GitRepositoryDocument, error) {
	channel, err := s.ipcChannel()
	if err != nil {
		return GitRepositoryDocument{}, err
	}
	response, err := channel.Call("repository", map[string]any{"path": path})
	if err != nil {
		return GitRepositoryDocument{}, newBridgeError("git_repository_unavailable", "failed to fetch bridge git repository", err)
	}
	repo, err := decodeRepositoryDocument(response)
	if err != nil {
		return GitRepositoryDocument{}, newBridgeError("git_repository_unavailable", "failed to decode bridge git repository", err)
	}
	if repo.Path == "" {
		repo.Path = path
	}
	return repo, nil
}

func (s *GitService) ensureRepositoryWatch(ctx context.Context, path string) error {
	s.mu.Lock()
	if _, ok := s.watchedPaths[path]; ok {
		s.mu.Unlock()
		return nil
	}
	s.watchedPaths[path] = struct{}{}
	s.mu.Unlock()
	return s.subscribeRepository(ctx, path)
}

func (s *GitService) resubscribeAll(ctx context.Context) {
	s.mu.Lock()
	paths := make([]string, 0, len(s.watchedPaths))
	for path := range s.watchedPaths {
		paths = append(paths, path)
	}
	watchStops := s.watchStops
	s.watchStops = make(map[string]func(), len(paths))
	s.mu.Unlock()

	for _, stop := range watchStops {
		stop()
	}
	for _, path := range paths {
		_ = s.subscribeRepository(ctx, path)
	}
}

func (s *GitService) disposeAllWatchers() {
	s.mu.Lock()
	watchStops := s.watchStops
	s.watchStops = make(map[string]func())
	s.mu.Unlock()

	for _, stop := range watchStops {
		stop()
	}
}

func (s *GitService) subscribeRepository(ctx context.Context, path string) error {
	channel, err := s.ipcChannel()
	if err != nil {
		return err
	}
	events, dispose, err := channel.Listen("repositoryChanged", map[string]any{"path": path})
	if err != nil {
		return newBridgeError("git_subscription_failed", "failed to subscribe to bridge git repository updates", err)
	}

	s.mu.Lock()
	if oldDispose, ok := s.watchStops[path]; ok {
		oldDispose()
	}
	s.watchStops[path] = dispose
	s.mu.Unlock()

	go func(repoPath string, eventCh <-chan interface{}, stop func()) {
		defer func() {
			s.mu.Lock()
			if currentStop, ok := s.watchStops[repoPath]; ok && fmt.Sprintf("%p", currentStop) == fmt.Sprintf("%p", stop) {
				delete(s.watchStops, repoPath)
			}
			s.mu.Unlock()
		}()
		for {
			select {
			case <-ctx.Done():
				stop()
				return
			case raw, ok := <-eventCh:
				if !ok {
					return
				}
				repo, err := s.decodeRepositoryEvent(repoPath, raw)
				if err != nil {
					continue
				}
				s.publishRepositoryChanged(repo)
			}
		}
	}(path, events, dispose)

	return nil
}

func (s *GitService) decodeRepositoryEvent(path string, raw interface{}) (GitRepositoryDocument, error) {
	if repo, err := decodeRepositoryDocument(raw); err == nil {
		if repo.Path == "" {
			repo.Path = path
		}
		return repo, nil
	}
	if payload, ok := toObjectMap(raw); ok {
		if repositoryRaw, ok := payload["repository"]; ok {
			if repo, err := decodeRepositoryDocument(repositoryRaw); err == nil {
				if repo.Path == "" {
					repo.Path = path
				}
				return repo, nil
			}
		}
		if changedPath, ok := payload["path"].(string); ok && changedPath != "" && changedPath != path {
			path = changedPath
		}
	}
	return s.fetchRepository(path)
}

func (s *GitService) publishRepositoryChanged(repo GitRepositoryDocument) {
	if s.bridge == nil {
		return
	}
	s.bridge.Publish(BridgeEvent{
		Type:    "bridge/git/repositoryChanged",
		Payload: repo,
	})
}

func (s *GitService) ipcChannel() (*IPCChannel, error) {
	if s.client == nil || s.client.IPC() == nil {
		return nil, newBridgeError("bridge_not_ready", "mobile runtime bridge is not ready", nil)
	}
	if s.bridge != nil {
		if err := s.bridge.RequireCapability("git"); err != nil {
			return nil, err
		}
	}
	return s.client.IPC().GetChannel(s.channelName), nil
}

func decodeRepositoryDocument(raw interface{}) (GitRepositoryDocument, error) {
	type repositoryAlias struct {
		Path          string           `json:"path"`
		RootPath      string           `json:"rootPath"`
		Branch        string           `json:"branch"`
		CurrentBranch string           `json:"currentBranch"`
		Upstream      string           `json:"upstream"`
		Ahead         int              `json:"ahead"`
		AheadCount    int              `json:"aheadCount"`
		Behind        int              `json:"behind"`
		BehindCount   int              `json:"behindCount"`
		Remotes       []GitRemote      `json:"remotes"`
		Staged        []GitChange      `json:"staged"`
		Unstaged      []GitChange      `json:"unstaged"`
		Untracked     []GitChange      `json:"untracked"`
		Conflicts     []GitChange      `json:"conflicts"`
		MergeChanges  []GitChange      `json:"mergeChanges"`
		Changes       []GitChange      `json:"changes"`
		Repository    *repositoryAlias `json:"repository"`
		Head          *struct {
			Name     string `json:"name"`
			Upstream string `json:"upstream"`
			Ahead    int    `json:"ahead"`
			Behind   int    `json:"behind"`
		} `json:"head"`
	}

	var alias repositoryAlias
	if err := decodeJSON(raw, &alias); err != nil {
		return GitRepositoryDocument{}, err
	}
	if alias.Repository != nil {
		alias = *alias.Repository
	}

	repo := GitRepositoryDocument{
		Path:         firstNonEmpty(alias.Path, alias.RootPath),
		Branch:       firstNonEmpty(alias.Branch, alias.CurrentBranch),
		Upstream:     alias.Upstream,
		Ahead:        alias.Ahead,
		Behind:       alias.Behind,
		Remotes:      alias.Remotes,
		Staged:       normalizeChanges(alias.Staged),
		Unstaged:     normalizeChanges(alias.Unstaged),
		Untracked:    normalizeChanges(alias.Untracked),
		Conflicts:    normalizeChanges(alias.Conflicts),
		MergeChanges: normalizeChanges(alias.MergeChanges),
	}
	if repo.Ahead == 0 {
		repo.Ahead = alias.AheadCount
	}
	if repo.Behind == 0 {
		repo.Behind = alias.BehindCount
	}
	if alias.Head != nil {
		repo.Branch = firstNonEmpty(repo.Branch, alias.Head.Name)
		repo.Upstream = firstNonEmpty(repo.Upstream, alias.Head.Upstream)
		if repo.Ahead == 0 {
			repo.Ahead = alias.Head.Ahead
		}
		if repo.Behind == 0 {
			repo.Behind = alias.Head.Behind
		}
	}

	if len(repo.Staged)+len(repo.Unstaged)+len(repo.Untracked)+len(repo.Conflicts)+len(repo.MergeChanges) == 0 && len(alias.Changes) > 0 {
		repo.Staged, repo.Unstaged, repo.Untracked, repo.Conflicts, repo.MergeChanges = classifyChanges(alias.Changes)
	}

	if repo.Remotes == nil {
		repo.Remotes = []GitRemote{}
	}
	repo.Staged = emptyChanges(repo.Staged)
	repo.Unstaged = emptyChanges(repo.Unstaged)
	repo.Untracked = emptyChanges(repo.Untracked)
	repo.Conflicts = emptyChanges(repo.Conflicts)
	repo.MergeChanges = emptyChanges(repo.MergeChanges)
	return repo, nil
}

func classifyChanges(changes []GitChange) ([]GitChange, []GitChange, []GitChange, []GitChange, []GitChange) {
	staged := make([]GitChange, 0)
	unstaged := make([]GitChange, 0)
	untracked := make([]GitChange, 0)
	conflicts := make([]GitChange, 0)
	mergeChanges := make([]GitChange, 0)

	for _, change := range normalizeChanges(changes) {
		switch {
		case isConflictChange(change):
			conflicts = append(conflicts, change)
		case isUntrackedChange(change):
			untracked = append(untracked, change)
		case isMergeChange(change):
			mergeChanges = append(mergeChanges, change)
		case change.IndexStatus != "" && change.IndexStatus != " " && change.IndexStatus != "?":
			staged = append(staged, change)
		default:
			unstaged = append(unstaged, change)
		}
	}

	return staged, unstaged, untracked, conflicts, mergeChanges
}

func normalizeChanges(changes []GitChange) []GitChange {
	if len(changes) == 0 {
		return nil
	}
	out := make([]GitChange, 0, len(changes))
	for _, change := range changes {
		change.Path = normalizeChangePath(change.Path)
		change.OriginalPath = normalizeChangePath(change.OriginalPath)
		if change.Status == "" {
			change.Status = deriveStatus(change)
		}
		if change.MergeStatus == nil && isConflictChange(change) {
			change.MergeStatus = &GitMergeStatus{Kind: "conflict", Current: change.IndexStatus, Incoming: change.WorkingTreeStatus}
		}
		out = append(out, change)
	}
	return out
}

func emptyChanges(changes []GitChange) []GitChange {
	if changes == nil {
		return []GitChange{}
	}
	return changes
}

func deriveStatus(change GitChange) string {
	status := strings.ToLower(strings.TrimSpace(change.Status))
	if status != "" {
		return status
	}
	if isConflictChange(change) {
		return "conflict"
	}
	if isUntrackedChange(change) {
		return "untracked"
	}
	code := firstNonEmpty(strings.TrimSpace(change.IndexStatus), strings.TrimSpace(change.WorkingTreeStatus))
	switch code {
	case "M":
		return "modified"
	case "A":
		return "added"
	case "D":
		return "deleted"
	case "R":
		return "renamed"
	case "C":
		return "copied"
	default:
		return "unknown"
	}
}

func normalizeChangePath(raw string) string {
	if raw == "" {
		return ""
	}
	if parsed, err := url.Parse(raw); err == nil && parsed.Scheme == "file" {
		return filepath.Clean(parsed.Path)
	}
	return filepath.Clean(raw)
}

func isUntrackedChange(change GitChange) bool {
	status := strings.ToLower(strings.TrimSpace(change.Status))
	return status == "untracked" || change.IndexStatus == "?" || change.WorkingTreeStatus == "?"
}

func isConflictChange(change GitChange) bool {
	status := strings.ToLower(strings.TrimSpace(change.Status))
	if strings.Contains(status, "conflict") {
		return true
	}
	pair := strings.TrimSpace(change.IndexStatus) + strings.TrimSpace(change.WorkingTreeStatus)
	switch pair {
	case "DD", "AU", "UD", "UA", "DU", "AA", "UU":
		return true
	default:
		return change.IndexStatus == "U" || change.WorkingTreeStatus == "U"
	}
}

func isMergeChange(change GitChange) bool {
	if change.MergeStatus != nil {
		return true
	}
	status := strings.ToLower(strings.TrimSpace(change.Status))
	return strings.Contains(status, "merge")
}

func toObjectMap(raw interface{}) (map[string]any, bool) {
	obj, ok := raw.(map[string]any)
	if ok {
		return obj, true
	}
	obj2, ok := raw.(map[string]interface{})
	return obj2, ok
}

func decodeJSON(raw interface{}, dest interface{}) error {
	data, err := json.Marshal(raw)
	if err != nil {
		return err
	}
	return json.Unmarshal(data, dest)
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func decodeDiffDocument(raw interface{}) (GitDiffDocument, error) {
	switch value := raw.(type) {
	case string:
		return GitDiffDocument{Diff: value}, nil
	case map[string]any:
		if diff, ok := value["diff"].(string); ok {
			path, _ := value["path"].(string)
			staged, _ := value["staged"].(bool)
			return GitDiffDocument{
				Path:   path,
				Diff:   diff,
				Staged: staged,
			}, nil
		}
	}

	var doc GitDiffDocument
	if err := decodeJSON(raw, &doc); err != nil {
		return GitDiffDocument{}, err
	}
	return doc, nil
}
