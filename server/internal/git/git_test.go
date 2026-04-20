package git

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// setupTestRepo creates a temporary git repo with one committed file.
func setupTestRepo(t *testing.T) (string, func()) {
	t.Helper()
	dir, err := os.MkdirTemp("", "git-test-*")
	if err != nil {
		t.Fatalf("failed to create temp dir: %v", err)
	}
	cleanup := func() { os.RemoveAll(dir) }

	cmds := [][]string{
		{"git", "-C", dir, "init"},
		{"git", "-C", dir, "config", "user.email", "test@test.com"},
		{"git", "-C", dir, "config", "user.name", "Test User"},
	}
	for _, args := range cmds {
		if out, err := exec.Command(args[0], args[1:]...).CombinedOutput(); err != nil {
			cleanup()
			t.Fatalf("setup command %v failed: %v: %s", args, err, out)
		}
	}

	// Create and commit a file.
	testFile := filepath.Join(dir, "hello.txt")
	if err := os.WriteFile(testFile, []byte("hello world\n"), 0644); err != nil {
		cleanup()
		t.Fatalf("failed to write test file: %v", err)
	}
	for _, args := range [][]string{
		{"git", "-C", dir, "add", "hello.txt"},
		{"git", "-C", dir, "commit", "-m", "initial commit"},
	} {
		if out, err := exec.Command(args[0], args[1:]...).CombinedOutput(); err != nil {
			cleanup()
			t.Fatalf("setup command %v failed: %v: %s", args, err, out)
		}
	}

	return dir, cleanup
}

func TestStatusClean(t *testing.T) {
	dir, cleanup := setupTestRepo(t)
	defer cleanup()

	g := NewGit(dir)
	entries, err := g.Status(dir)
	if err != nil {
		t.Fatalf("Status failed: %v", err)
	}
	if len(entries) != 0 {
		t.Errorf("expected clean status, got %d entries: %+v", len(entries), entries)
	}
}

func TestStatusModified(t *testing.T) {
	dir, cleanup := setupTestRepo(t)
	defer cleanup()

	// Modify the file.
	if err := os.WriteFile(filepath.Join(dir, "hello.txt"), []byte("modified\n"), 0644); err != nil {
		t.Fatalf("failed to modify file: %v", err)
	}

	g := NewGit(dir)
	entries, err := g.Status(dir)
	if err != nil {
		t.Fatalf("Status failed: %v", err)
	}
	if len(entries) != 1 {
		t.Fatalf("expected 1 entry, got %d", len(entries))
	}
	if entries[0].Status != "modified" {
		t.Errorf("expected status 'modified', got %q", entries[0].Status)
	}
	if entries[0].Path != "hello.txt" {
		t.Errorf("expected path 'hello.txt', got %q", entries[0].Path)
	}
	if entries[0].Staged {
		t.Error("expected file to not be staged")
	}
}

func TestStatusUntracked(t *testing.T) {
	dir, cleanup := setupTestRepo(t)
	defer cleanup()

	// Create untracked file.
	if err := os.WriteFile(filepath.Join(dir, "new.txt"), []byte("new\n"), 0644); err != nil {
		t.Fatalf("failed to write file: %v", err)
	}

	g := NewGit(dir)
	entries, err := g.Status(dir)
	if err != nil {
		t.Fatalf("Status failed: %v", err)
	}
	if len(entries) != 1 {
		t.Fatalf("expected 1 entry, got %d", len(entries))
	}
	if entries[0].Status != "untracked" {
		t.Errorf("expected status 'untracked', got %q", entries[0].Status)
	}
}

func TestStatusStaged(t *testing.T) {
	dir, cleanup := setupTestRepo(t)
	defer cleanup()

	// Modify and stage.
	if err := os.WriteFile(filepath.Join(dir, "hello.txt"), []byte("staged change\n"), 0644); err != nil {
		t.Fatalf("failed to modify file: %v", err)
	}
	if out, err := exec.Command("git", "-C", dir, "add", "hello.txt").CombinedOutput(); err != nil {
		t.Fatalf("git add failed: %v: %s", err, out)
	}

	g := NewGit(dir)
	entries, err := g.Status(dir)
	if err != nil {
		t.Fatalf("Status failed: %v", err)
	}
	if len(entries) != 1 {
		t.Fatalf("expected 1 entry, got %d", len(entries))
	}
	if !entries[0].Staged {
		t.Error("expected file to be staged")
	}
	if entries[0].Status != "modified" {
		t.Errorf("expected status 'modified', got %q", entries[0].Status)
	}
}

func TestLog(t *testing.T) {
	dir, cleanup := setupTestRepo(t)
	defer cleanup()

	g := NewGit(dir)
	entries, err := g.Log(dir, 10)
	if err != nil {
		t.Fatalf("Log failed: %v", err)
	}
	if len(entries) != 1 {
		t.Fatalf("expected 1 log entry, got %d", len(entries))
	}
	if entries[0].Message != "initial commit" {
		t.Errorf("expected message 'initial commit', got %q", entries[0].Message)
	}
	if entries[0].Author != "Test User" {
		t.Errorf("expected author 'Test User', got %q", entries[0].Author)
	}
	if entries[0].Hash == "" {
		t.Error("expected non-empty hash")
	}
	if entries[0].Date == "" {
		t.Error("expected non-empty date")
	}
}

func TestBranchInfo(t *testing.T) {
	dir, cleanup := setupTestRepo(t)
	defer cleanup()

	g := NewGit(dir)
	info, err := g.BranchInfo(dir)
	if err != nil {
		t.Fatalf("BranchInfo failed: %v", err)
	}
	if info.Current == "" {
		t.Error("expected non-empty current branch")
	}
	if len(info.Branches) == 0 {
		t.Error("expected at least one branch")
	}
	// Current branch should be in the list.
	found := false
	for _, b := range info.Branches {
		if b == info.Current {
			found = true
			break
		}
	}
	if !found {
		t.Errorf("current branch %q not found in branches list %v", info.Current, info.Branches)
	}
}

func TestDiff(t *testing.T) {
	dir, cleanup := setupTestRepo(t)
	defer cleanup()

	// Modify file.
	if err := os.WriteFile(filepath.Join(dir, "hello.txt"), []byte("changed\n"), 0644); err != nil {
		t.Fatalf("failed to modify file: %v", err)
	}

	g := NewGit(dir)
	diff, err := g.Diff(dir, "hello.txt", false)
	if err != nil {
		t.Fatalf("Diff failed: %v", err)
	}
	if diff == "" {
		t.Error("expected non-empty diff")
	}
}

func TestShow(t *testing.T) {
	dir, cleanup := setupTestRepo(t)
	defer cleanup()

	g := NewGit(dir)
	content, err := g.Show(dir, "HEAD", "hello.txt")
	if err != nil {
		t.Fatalf("Show failed: %v", err)
	}
	if content != "hello world\n" {
		t.Errorf("expected 'hello world\\n', got %q", content)
	}
}




func gitRun(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v failed: %v: %s", args, err, out)
	}
	return strings.TrimSpace(string(out))
}

func setupRepoWithRemote(t *testing.T, remoteURL string) (string, string, func()) {
	t.Helper()
	dir, cleanup := setupTestRepo(t)
	if remoteURL != "" {
		gitRun(t, dir, "remote", "add", "origin", remoteURL)
	}
	nested := filepath.Join(dir, "nested", "workspace")
	if err := os.MkdirAll(nested, 0o755); err != nil {
		cleanup()
		t.Fatalf("failed to create nested workspace: %v", err)
	}
	return dir, nested, cleanup
}

func TestRepoRootFromNestedWorkspace(t *testing.T) {
	repoDir, nestedDir, cleanup := setupRepoWithRemote(t, "https://github.com/acme/rocket.git")
	defer cleanup()

	repoRoot, err := NewGit(repoDir).RepoRoot(nestedDir)
	if err != nil {
		t.Fatalf("RepoRoot() error = %v", err)
	}
	if repoRoot != repoDir {
		t.Fatalf("RepoRoot() = %q, want %q", repoRoot, repoDir)
	}
}

func TestCurrentRemotePreservesHTTPSRemote(t *testing.T) {
	repoDir, nestedDir, cleanup := setupRepoWithRemote(t, "https://github.com/acme/rocket.git")
	defer cleanup()

	remote, err := NewGit(repoDir).CurrentRemote(nestedDir)
	if err != nil {
		t.Fatalf("CurrentRemote() error = %v", err)
	}
	if remote.Name != "origin" || remote.URL != "https://github.com/acme/rocket.git" {
		t.Fatalf("remote = %#v", remote)
	}
}

func TestCurrentRemotePreservesSSHRemote(t *testing.T) {
	repoDir, nestedDir, cleanup := setupRepoWithRemote(t, "git@github.com:octocat/hello-world.git")
	defer cleanup()

	remote, err := NewGit(repoDir).CurrentRemote(nestedDir)
	if err != nil {
		t.Fatalf("CurrentRemote() error = %v", err)
	}
	if remote.Name != "origin" || remote.URL != "git@github.com:octocat/hello-world.git" {
		t.Fatalf("remote = %#v", remote)
	}
}

func TestCurrentRemoteReportsNoRemote(t *testing.T) {
	repoDir, nestedDir, cleanup := setupRepoWithRemote(t, "")
	defer cleanup()

	_, err := NewGit(repoDir).CurrentRemote(nestedDir)
	if err == nil {
		t.Fatal("CurrentRemote() error = nil, want no remotes configured error")
	}
	if err != ErrNoRemote {
		t.Fatalf("CurrentRemote() error = %v", err)
	}
}

func TestRepoRootReportsNotARepo(t *testing.T) {
	notRepo := t.TempDir()
	_, err := NewGit(notRepo).RepoRoot(notRepo)
	if err == nil {
		t.Fatal("RepoRoot() error = nil, want git repository error")
	}
	if err != ErrNotRepository {
		t.Fatalf("RepoRoot() error = %v", err)
	}
}

func TestRepoContextParsesGitHubHTTPSRemoteAndFindsRepoRoot(t *testing.T) {
	repoDir, nestedDir, cleanup := setupRepoWithRemote(t, "https://github.com/acme/rocket.git")
	defer cleanup()

	context, err := NewGit(repoDir).RepoContext(nestedDir)
	if err != nil {
		t.Fatalf("RepoContext() error = %v", err)
	}
	if context.GitHubHost != "github.com" || context.Owner != "acme" || context.Name != "rocket" {
		t.Fatalf("context = %#v", context)
	}
	if context.RepoRoot != repoDir {
		t.Fatalf("RepoRoot = %q, want %q", context.RepoRoot, repoDir)
	}
}

func TestRepoContextParsesGitHubSSHRemoteAndFindsRepoRoot(t *testing.T) {
	repoDir, nestedDir, cleanup := setupRepoWithRemote(t, "git@github.com:octocat/hello-world.git")
	defer cleanup()

	context, err := NewGit(repoDir).RepoContext(nestedDir)
	if err != nil {
		t.Fatalf("RepoContext() error = %v", err)
	}
	if context.GitHubHost != "github.com" || context.Owner != "octocat" || context.Name != "hello-world" {
		t.Fatalf("context = %#v", context)
	}
}

func TestRepoContextReportsRepoNotGitHub(t *testing.T) {
	repoDir, nestedDir, cleanup := setupRepoWithRemote(t, "https://gitlab.com/acme/rocket.git")
	defer cleanup()

	context, err := NewGit(repoDir).RepoContext(nestedDir)
	if err == nil {
		t.Fatal("RepoContext() error = nil, want repo_not_github")
	}
	if err != ErrRepoNotGitHub {
		t.Fatalf("RepoContext() error = %v", err)
	}
	if context == nil || context.Status != RepoContextStatusRepoNotGitHub {
		t.Fatalf("context = %#v", context)
	}
}


func TestParseGitHubRemoteURLSupportsHTTPSAndSSH(t *testing.T) {
	for _, tc := range []struct {
		name      string
		remoteURL string
		host      string
		owner     string
		repo      string
	}{
		{name: "https", remoteURL: "https://github.com/acme/rocket.git", host: "github.com", owner: "acme", repo: "rocket"},
		{name: "ssh", remoteURL: "git@github.com:octocat/hello-world.git", host: "github.com", owner: "octocat", repo: "hello-world"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			host, owner, repo, err := ParseGitHubRemoteURL(tc.remoteURL)
			if err != nil {
				t.Fatalf("ParseGitHubRemoteURL() error = %v", err)
			}
			if host != tc.host || owner != tc.owner || repo != tc.repo {
				t.Fatalf("ParseGitHubRemoteURL() = (%q, %q, %q), want (%q, %q, %q)", host, owner, repo, tc.host, tc.owner, tc.repo)
			}
		})
	}
}

func TestRepoContextReportsNonGitHubRemote(t *testing.T) {
	repoDir, nestedDir, cleanup := setupRepoWithRemote(t, "https://gitlab.com/acme/rocket.git")
	defer cleanup()

	context, err := NewGit(repoDir).RepoContext(nestedDir)
	if err == nil {
		t.Fatal("RepoContext() error = nil, want non-GitHub error")
	}
	if context == nil || context.RepoRoot != repoDir {
		t.Fatalf("RepoContext() context = %#v", context)
	}
	if context.Status != RepoContextStatusRepoNotGitHub {
		t.Fatalf("RepoContext() status = %q, want %q", context.Status, RepoContextStatusRepoNotGitHub)
	}
	if context.RemoteURL != "https://gitlab.com/acme/rocket.git" {
		t.Fatalf("RepoContext() remote URL = %q", context.RemoteURL)
	}
}
