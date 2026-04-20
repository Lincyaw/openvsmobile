package github

import (
	"context"
	"strings"

	gitctx "github.com/Lincyaw/vscode-mobile/server/internal/git"
)

type CollaborationFilter struct {
	State        string
	AssignedToMe bool
	CreatedByMe  bool
	Mentioned    bool
	NeedsReview  bool
	Page         int
	PerPage      int
}

func (s *Service) GetAccount(ctx context.Context, path string) (*Account, error) {
	account, _, err := s.GetCurrentRepoAccount(ctx, sGit(s), path)
	return account, err
}

func (s *Service) ListIssues(ctx context.Context, path string, filter CollaborationFilter) ([]Issue, error) {
	repository, record, login, err := s.authorizedRepoSession(ctx, sGit(s), path)
	if err != nil {
		return nil, err
	}
	filter = normalizeCollaborationFilter(filter)
	if filter.Mentioned {
		return s.client.SearchIssues(ctx, repository.GitHubHost, record.AccessToken, buildSearchQuery(repository.FullName, login, filter, false), filter.Page, filter.PerPage)
	}
	options := IssueListOptions{State: filterState(filter.State), Page: filter.Page, PerPage: filter.PerPage}
	if filter.AssignedToMe {
		options.Assignee = login
	}
	if filter.CreatedByMe {
		options.Creator = login
	}
	return s.client.ListIssues(ctx, repository.GitHubHost, repository.Owner, repository.Name, record.AccessToken, options)
}

func (s *Service) GetPullRequest(ctx context.Context, path string, number int) (*PullRequest, error) {
	pr, _, err := s.GetCurrentRepoPullRequest(ctx, sGit(s), path, number)
	return pr, err
}

func (s *Service) ListPullRequests(ctx context.Context, path string, filter CollaborationFilter) ([]PullRequest, error) {
	repository, record, login, err := s.authorizedRepoSession(ctx, sGit(s), path)
	if err != nil {
		return nil, err
	}
	filter = normalizeCollaborationFilter(filter)
	if filter.AssignedToMe || filter.CreatedByMe || filter.Mentioned || filter.NeedsReview {
		return s.client.SearchPullRequests(ctx, repository.GitHubHost, record.AccessToken, buildSearchQuery(repository.FullName, login, filter, true), filter.Page, filter.PerPage)
	}
	options := PullRequestListOptions{State: filterState(filter.State), Page: filter.Page, PerPage: filter.PerPage}
	return s.client.ListPullRequests(ctx, repository.GitHubHost, repository.Owner, repository.Name, record.AccessToken, options)
}

func (s *Service) CreateIssueComment(ctx context.Context, path string, number int, input CreateIssueCommentInput) (*IssueComment, error) {
	comment, _, err := s.CreateCurrentRepoIssueComment(ctx, sGit(s), path, number, input)
	return comment, err
}

func (s *Service) CreatePullRequestComment(ctx context.Context, path string, number int, input CreatePullRequestCommentInput) (*PullRequestComment, error) {
	comment, _, err := s.CreateCurrentRepoPullRequestComment(ctx, sGit(s), path, number, input)
	return comment, err
}

func (s *Service) CreatePullRequestReview(ctx context.Context, path string, number int, input CreatePullRequestReviewInput) (*PullRequestReview, error) {
	review, _, err := s.CreateCurrentRepoPullRequestReview(ctx, sGit(s), path, number, input)
	return review, err
}

func (s *Service) GetIssueComments(ctx context.Context, path string, number int, options ListOptions) ([]IssueComment, *Repository, error) {
	repository, record, _, err := s.authorizedRepoSession(ctx, sGit(s), path)
	if err != nil {
		return nil, repository, err
	}
	comments, err := s.client.ListIssueComments(ctx, repository.GitHubHost, repository.Owner, repository.Name, number, record.AccessToken, options)
	if err != nil {
		return nil, repository, s.translateAPIError(err)
	}
	return comments, repository, nil
}

func (s *Service) GetPullRequestReviews(ctx context.Context, path string, number int, options ListOptions) ([]PullRequestReview, *Repository, error) {
	repository, record, _, err := s.authorizedRepoSession(ctx, sGit(s), path)
	if err != nil {
		return nil, repository, err
	}
	reviews, err := s.client.ListPullRequestReviews(ctx, repository.GitHubHost, repository.Owner, repository.Name, number, record.AccessToken, options)
	if err != nil {
		return nil, repository, s.translateAPIError(err)
	}
	return reviews, repository, nil
}

func (s *Service) authorizedRepoSession(ctx context.Context, gitClient *gitctx.Git, path string) (*Repository, *AuthRecord, string, error) {
	repository, record, err := s.resolveAuthorizedRepository(ctx, gitClient, path)
	if err != nil {
		return repository, nil, "", err
	}
	login := strings.TrimSpace(record.AccountLogin)
	if login == "" {
		account, accountErr := s.client.GetAccount(ctx, repository.GitHubHost, record.AccessToken)
		if accountErr != nil {
			return repository, nil, "", s.translateAPIError(accountErr)
		}
		login = account.Login
	}
	return repository, record, login, nil
}

func buildSearchQuery(repoFullName, login string, filter CollaborationFilter, isPR bool) string {
	parts := []string{"repo:" + repoFullName}
	if isPR {
		parts = append(parts, "is:pr")
	} else {
		parts = append(parts, "is:issue")
	}
	parts = append(parts, "is:"+filterState(filter.State))
	if filter.AssignedToMe {
		parts = append(parts, "assignee:"+login)
	}
	if filter.CreatedByMe {
		parts = append(parts, "author:"+login)
	}
	if filter.Mentioned {
		parts = append(parts, "mentions:"+login)
	}
	if isPR && filter.NeedsReview {
		parts = append(parts, "review-requested:"+login)
	}
	return strings.Join(parts, " ")
}

func normalizeCollaborationFilter(filter CollaborationFilter) CollaborationFilter {
	if strings.TrimSpace(filter.State) == "" {
		filter.State = "open"
	}
	if filter.Page <= 0 {
		filter.Page = 1
	}
	if filter.PerPage <= 0 || filter.PerPage > 100 {
		filter.PerPage = 30
	}
	return filter
}

func sGit(s *Service) *gitctx.Git { return gitctx.NewGit(".") }
