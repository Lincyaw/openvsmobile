package github

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	gitctx "github.com/Lincyaw/vscode-mobile/server/internal/git"
)

func buildIssueListQuery(options IssueListOptions) url.Values {
	values := url.Values{}
	setQuery(values, "state", options.State)
	setQuery(values, "sort", options.Sort)
	setQuery(values, "direction", options.Direction)
	setQuery(values, "since", options.Since)
	setQuery(values, "labels", options.Labels)
	setQuery(values, "creator", options.Creator)
	setQuery(values, "mentioned", options.Mentioned)
	setQuery(values, "assignee", options.Assignee)
	setQuery(values, "milestone", options.Milestone)
	setPage(values, options.Page, options.PerPage)
	return values
}

func buildPullRequestListQuery(options PullRequestListOptions) url.Values {
	values := url.Values{}
	setQuery(values, "state", options.State)
	setQuery(values, "head", options.Head)
	setQuery(values, "base", options.Base)
	setQuery(values, "sort", options.Sort)
	setQuery(values, "direction", options.Direction)
	setPage(values, options.Page, options.PerPage)
	return values
}

func buildListQuery(options ListOptions) url.Values {
	values := url.Values{}
	setQuery(values, "sort", options.Sort)
	setQuery(values, "direction", options.Direction)
	setQuery(values, "since", options.Since)
	setPage(values, options.Page, options.PerPage)
	return values
}

func setQuery(values url.Values, key, value string) {
	if strings.TrimSpace(value) != "" {
		values.Set(key, strings.TrimSpace(value))
	}
}

func setPage(values url.Values, page, perPage int) {
	if page > 0 {
		values.Set("page", strconv.Itoa(page))
	}
	if perPage > 0 {
		values.Set("per_page", strconv.Itoa(perPage))
	}
}

func filterState(state string) string {
	switch strings.ToLower(strings.TrimSpace(state)) {
	case "", "open":
		return "open"
	case "closed":
		return "closed"
	case "all":
		return "all"
	default:
		return strings.TrimSpace(state)
	}
}

func (s *Service) GetCurrentRepoAccount(ctx context.Context, gitClient *gitctx.Git, path string) (*Account, *Repository, error) {
	repository, record, err := s.resolveAuthorizedRepository(ctx, gitClient, path)
	if err != nil {
		return nil, repository, err
	}
	account, err := s.client.GetAccount(ctx, repository.GitHubHost, record.AccessToken)
	if err != nil {
		return nil, repository, s.translateAPIError(err)
	}
	return account, repository, nil
}

func (s *Service) ListCurrentRepoIssues(ctx context.Context, gitClient *gitctx.Git, path string, options IssueListOptions) ([]Issue, *Repository, error) {
	repository, record, err := s.resolveAuthorizedRepository(ctx, gitClient, path)
	if err != nil {
		return nil, repository, err
	}
	issues, err := s.client.ListIssues(ctx, repository.GitHubHost, repository.Owner, repository.Name, record.AccessToken, options)
	if err != nil {
		return nil, repository, s.translateAPIError(err)
	}
	return issues, repository, nil
}

func (s *Service) GetCurrentRepoIssue(ctx context.Context, gitClient *gitctx.Git, path string, number int) (*Issue, *Repository, error) {
	repository, record, err := s.resolveAuthorizedRepository(ctx, gitClient, path)
	if err != nil {
		return nil, repository, err
	}
	issue, err := s.client.GetIssue(ctx, repository.GitHubHost, repository.Owner, repository.Name, number, record.AccessToken)
	if err != nil {
		return nil, repository, s.translateAPIError(err)
	}
	return issue, repository, nil
}

func (s *Service) CreateCurrentRepoIssueComment(ctx context.Context, gitClient *gitctx.Git, path string, number int, input CreateIssueCommentInput) (*IssueComment, *Repository, error) {
	repository, record, err := s.resolveAuthorizedRepository(ctx, gitClient, path)
	if err != nil {
		return nil, repository, err
	}
	comment, err := s.client.CreateIssueComment(ctx, repository.GitHubHost, repository.Owner, repository.Name, number, record.AccessToken, input)
	if err != nil {
		return nil, repository, s.translateAPIError(err)
	}
	return comment, repository, nil
}

func (s *Service) ListCurrentRepoPullRequests(ctx context.Context, gitClient *gitctx.Git, path string, options PullRequestListOptions) ([]PullRequest, *Repository, error) {
	repository, record, err := s.resolveAuthorizedRepository(ctx, gitClient, path)
	if err != nil {
		return nil, repository, err
	}
	pulls, err := s.client.ListPullRequests(ctx, repository.GitHubHost, repository.Owner, repository.Name, record.AccessToken, options)
	if err != nil {
		return nil, repository, s.translateAPIError(err)
	}
	return pulls, repository, nil
}

func (s *Service) GetCurrentRepoPullRequest(ctx context.Context, gitClient *gitctx.Git, path string, number int) (*PullRequest, *Repository, error) {
	repository, record, err := s.resolveAuthorizedRepository(ctx, gitClient, path)
	if err != nil {
		return nil, repository, err
	}
	pull, err := s.client.GetPullRequest(ctx, repository.GitHubHost, repository.Owner, repository.Name, number, record.AccessToken)
	if err != nil {
		return nil, repository, s.translateAPIError(err)
	}
	checks, err := s.client.GetPullRequestChecks(ctx, repository.GitHubHost, repository.Owner, repository.Name, number, record.AccessToken)
	if err != nil {
		return nil, repository, s.translateAPIError(err)
	}
	pull.Checks = checks
	return pull, repository, nil
}

func (s *Service) ListCurrentRepoPullRequestFiles(ctx context.Context, gitClient *gitctx.Git, path string, number int, options ListOptions) ([]PullRequestFile, *Repository, error) {
	repository, record, err := s.resolveAuthorizedRepository(ctx, gitClient, path)
	if err != nil {
		return nil, repository, err
	}
	files, err := s.client.ListPullRequestFiles(ctx, repository.GitHubHost, repository.Owner, repository.Name, number, record.AccessToken, options)
	if err != nil {
		return nil, repository, s.translateAPIError(err)
	}
	return files, repository, nil
}

func (s *Service) ListCurrentRepoPullRequestComments(ctx context.Context, gitClient *gitctx.Git, path string, number int, options ListOptions) ([]PullRequestComment, *Repository, error) {
	repository, record, err := s.resolveAuthorizedRepository(ctx, gitClient, path)
	if err != nil {
		return nil, repository, err
	}
	comments, err := s.client.ListPullRequestComments(ctx, repository.GitHubHost, repository.Owner, repository.Name, number, record.AccessToken, options)
	if err != nil {
		return nil, repository, s.translateAPIError(err)
	}
	return comments, repository, nil
}

func (s *Service) CreateCurrentRepoPullRequestComment(ctx context.Context, gitClient *gitctx.Git, path string, number int, input CreatePullRequestCommentInput) (*PullRequestComment, *Repository, error) {
	repository, record, err := s.resolveAuthorizedRepository(ctx, gitClient, path)
	if err != nil {
		return nil, repository, err
	}
	comment, err := s.client.CreatePullRequestComment(ctx, repository.GitHubHost, repository.Owner, repository.Name, number, record.AccessToken, input)
	if err != nil {
		return nil, repository, s.translateAPIError(err)
	}
	return comment, repository, nil
}

func (s *Service) CreateCurrentRepoPullRequestReview(ctx context.Context, gitClient *gitctx.Git, path string, number int, input CreatePullRequestReviewInput) (*PullRequestReview, *Repository, error) {
	repository, record, err := s.resolveAuthorizedRepository(ctx, gitClient, path)
	if err != nil {
		return nil, repository, err
	}
	review, err := s.client.CreatePullRequestReview(ctx, repository.GitHubHost, repository.Owner, repository.Name, number, record.AccessToken, input)
	if err != nil {
		return nil, repository, s.translateAPIError(err)
	}
	return review, repository, nil
}

func (s *Service) resolveAuthorizedRepository(ctx context.Context, gitClient *gitctx.Git, path string) (*Repository, *AuthRecord, error) {
	if s == nil || s.client == nil || s.store == nil {
		return nil, nil, fmt.Errorf("github auth is not configured")
	}
	if gitClient == nil {
		return nil, nil, fmt.Errorf("git client is not configured")
	}

	repoContext, err := gitClient.ResolveRepoContext(path)
	if err != nil {
		switch {
		case errors.Is(err, gitctx.ErrNotRepository), errors.Is(err, gitctx.ErrNoRemote), errors.Is(err, gitctx.ErrRepoNotGitHub):
			return nil, nil, errors.Join(ErrInvalidRequest, ErrRepoNotGitHub, err)
		default:
			return nil, nil, err
		}
	}
	repository := &Repository{
		GitHubHost: repoContext.GitHubHost,
		Owner:      repoContext.Owner,
		Name:       repoContext.Name,
		FullName:   repoContext.FullName,
		RemoteName: repoContext.RemoteName,
		RemoteURL:  repoContext.RemoteURL,
		RepoRoot:   repoContext.RepoRoot,
	}

	record, err := s.EnsureFreshToken(ctx, repository.GitHubHost)
	if err != nil {
		return repository, nil, err
	}
	if _, err := s.client.GetRepo(ctx, repository.GitHubHost, repository.Owner, repository.Name, record.AccessToken); err != nil {
		return repository, nil, s.translateRepositoryAccessError(err)
	}
	if _, err := s.client.GetRepoInstallation(ctx, repository.GitHubHost, repository.Owner, repository.Name, record.AccessToken); err != nil {
		return repository, nil, s.translateRepositoryAccessError(err)
	}
	return repository, record, nil
}

func (s *Service) translateRepositoryAccessError(err error) error {
	if err == nil {
		return nil
	}
	if errors.Is(err, ErrAppNotInstalledForRepo) {
		return ErrAppNotInstalledForRepo
	}
	if IsAPIStatus(err, http.StatusForbidden) {
		return ErrRepoAccessUnavailable
	}
	if IsAPIStatus(err, http.StatusNotFound) {
		return ErrNotFound
	}
	return s.translateAPIError(err)
}

func (s *Service) translateAPIError(err error) error {
	if err == nil {
		return nil
	}
	if errors.Is(err, ErrNotAuthenticated) || errors.Is(err, ErrReauthRequired) || errors.Is(err, ErrRepoAccessUnavailable) || errors.Is(err, ErrAppNotInstalledForRepo) || errors.Is(err, ErrInvalidRequest) || errors.Is(err, ErrNotFound) || errors.Is(err, ErrRepoNotGitHub) {
		return err
	}
	var apiErr *APIError
	if errors.As(err, &apiErr) {
		switch apiErr.StatusCode {
		case http.StatusUnauthorized:
			return ErrReauthRequired
		case http.StatusForbidden:
			return ErrRepoAccessUnavailable
		case http.StatusNotFound:
			return ErrNotFound
		case http.StatusUnprocessableEntity, http.StatusBadRequest:
			return errors.Join(ErrInvalidRequest, err)
		default:
			return err
		}
	}
	var hostErr *HostError
	if errors.As(err, &hostErr) {
		translated := s.translateAPIError(hostErr.Err)
		if translated == hostErr.Err {
			return err
		}
		return &HostError{Host: hostErr.Host, Err: translated}
	}
	return err
}
