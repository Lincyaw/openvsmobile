package github

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"path"
	"strconv"
	"strings"
	"time"
)

type Client struct {
	httpClient *http.Client
	webBaseURL func(string) string
	apiBaseURL func(string) string
}

func NewClient(httpClient *http.Client) *Client {
	if httpClient == nil {
		httpClient = &http.Client{Timeout: 15 * time.Second}
	}
	return &Client{httpClient: httpClient, webBaseURL: webBaseURL, apiBaseURL: apiBaseURL}
}

func (c *Client) SetBaseURLFuncs(webBaseURLFn, apiBaseURLFn func(string) string) {
	if webBaseURLFn != nil {
		c.webBaseURL = webBaseURLFn
	}
	if apiBaseURLFn != nil {
		c.apiBaseURL = apiBaseURLFn
	}
}

func (c *Client) StartDeviceFlow(ctx context.Context, host, clientID string) (*DeviceCodeResponse, error) {
	values := url.Values{}
	values.Set("client_id", clientID)

	var resp DeviceCodeResponse
	if err := c.postForm(ctx, c.webBaseURL(host)+"/login/device/code", values, &resp); err != nil {
		return nil, err
	}
	return &resp, nil
}

func (c *Client) ExchangeDeviceCode(ctx context.Context, host, clientID, deviceCode string) (*TokenResponse, error) {
	values := url.Values{}
	values.Set("client_id", clientID)
	values.Set("device_code", deviceCode)
	values.Set("grant_type", "urn:ietf:params:oauth:grant-type:device_code")
	return c.exchangeToken(ctx, host, values)
}

func (c *Client) RefreshToken(ctx context.Context, host, clientID, refreshToken string) (*TokenResponse, error) {
	values := url.Values{}
	values.Set("client_id", clientID)
	values.Set("grant_type", "refresh_token")
	values.Set("refresh_token", refreshToken)
	return c.exchangeToken(ctx, host, values)
}

func (c *Client) GetUser(ctx context.Context, host, accessToken string) (*User, error) {
	var user User
	if err := c.getJSON(ctx, c.apiBaseURL(host)+"/user", accessToken, &user); err != nil {
		if apiErr, ok := err.(*APIError); ok {
			return nil, &HostError{Host: NormalizeHost(host), Err: apiErr}
		}
		return nil, err
	}
	return &user, nil
}

func (c *Client) GetAccount(ctx context.Context, host, accessToken string) (*Account, error) {
	var payload accountWire
	if err := c.getJSON(ctx, c.apiBaseURL(host)+"/user", accessToken, &payload); err != nil {
		if apiErr, ok := err.(*APIError); ok {
			return nil, &HostError{Host: NormalizeHost(host), Err: apiErr}
		}
		return nil, err
	}
	account := mapAccount(payload)
	return &account, nil
}

func (c *Client) GetRepo(ctx context.Context, host, owner, repo, accessToken string) (*Repository, error) {
	var repository Repository
	endpoint := c.apiBaseURL(host) + "/repos/" + url.PathEscape(owner) + "/" + url.PathEscape(repo)
	if err := c.getJSON(ctx, endpoint, accessToken, &repository); err != nil {
		return nil, err
	}
	repository.GitHubHost = NormalizeHost(host)
	if repository.Owner == "" {
		repository.Owner = owner
	}
	if repository.Name == "" {
		repository.Name = repo
	}
	if repository.FullName == "" && repository.Owner != "" && repository.Name != "" {
		repository.FullName = repository.Owner + "/" + repository.Name
	}
	return &repository, nil
}

func (c *Client) GetRepoInstallation(ctx context.Context, host, owner, repo, accessToken string) (*AppInstallation, error) {
	var installation AppInstallation
	endpoint := c.apiBaseURL(host) + "/repos/" + url.PathEscape(owner) + "/" + url.PathEscape(repo) + "/installation"
	if err := c.getJSON(ctx, endpoint, accessToken, &installation); err != nil {
		if IsAPIStatus(err, http.StatusNotFound) {
			return nil, &HostError{Host: NormalizeHost(host), Err: ErrAppNotInstalledForRepo}
		}
		if IsAPIStatus(err, http.StatusForbidden) {
			return nil, &HostError{Host: NormalizeHost(host), Err: ErrRepoAccessUnavailable}
		}
		return nil, err
	}
	return &installation, nil
}

func (c *Client) ListIssues(ctx context.Context, host, owner, repo, accessToken string, options IssueListOptions) ([]Issue, error) {
	endpoint := c.repoEndpoint(host, owner, repo, "/issues")
	var payload []issueWire
	if err := c.getJSONWithQuery(ctx, endpoint, accessToken, buildIssueListQuery(options), &payload); err != nil {
		return nil, err
	}
	issues := make([]Issue, 0, len(payload))
	for _, item := range payload {
		if item.PullRequest.URL != "" {
			continue
		}
		issues = append(issues, mapIssue(item))
	}
	return issues, nil
}

func (c *Client) GetIssue(ctx context.Context, host, owner, repo string, number int, accessToken string) (*Issue, error) {
	endpoint := c.repoEndpoint(host, owner, repo, "/issues/"+strconv.Itoa(number))
	var payload issueWire
	if err := c.getJSON(ctx, endpoint, accessToken, &payload); err != nil {
		return nil, err
	}
	issue := mapIssue(payload)
	return &issue, nil
}

func (c *Client) CreateIssueComment(ctx context.Context, host, owner, repo string, number int, accessToken string, input CreateIssueCommentInput) (*IssueComment, error) {
	endpoint := c.repoEndpoint(host, owner, repo, "/issues/"+strconv.Itoa(number)+"/comments")
	var payload issueCommentWire
	if err := c.postJSON(ctx, endpoint, accessToken, map[string]any{"body": input.Body}, &payload); err != nil {
		return nil, err
	}
	comment := mapIssueComment(payload)
	return &comment, nil
}

func (c *Client) ListIssueComments(ctx context.Context, host, owner, repo string, number int, accessToken string, options ListOptions) ([]IssueComment, error) {
	endpoint := c.repoEndpoint(host, owner, repo, "/issues/"+strconv.Itoa(number)+"/comments")
	var payload []issueCommentWire
	if err := c.getJSONWithQuery(ctx, endpoint, accessToken, buildListQuery(options), &payload); err != nil {
		return nil, err
	}
	comments := make([]IssueComment, 0, len(payload))
	for _, item := range payload {
		comments = append(comments, mapIssueComment(item))
	}
	return comments, nil
}

func (c *Client) SearchIssues(ctx context.Context, host, accessToken, query string, page, perPage int) ([]Issue, error) {
	var payload searchIssuesResponseWire
	values := url.Values{}
	values.Set("q", query)
	setPage(values, page, perPage)
	if err := c.getJSONWithQuery(ctx, c.apiBaseURL(host)+"/search/issues", accessToken, values, &payload); err != nil {
		return nil, err
	}
	issues := make([]Issue, 0, len(payload.Items))
	for _, item := range payload.Items {
		if item.PullRequest.URL != "" {
			continue
		}
		issues = append(issues, mapIssue(item))
	}
	return issues, nil
}

func (c *Client) ListPullRequests(ctx context.Context, host, owner, repo, accessToken string, options PullRequestListOptions) ([]PullRequest, error) {
	endpoint := c.repoEndpoint(host, owner, repo, "/pulls")
	var payload []pullRequestWire
	if err := c.getJSONWithQuery(ctx, endpoint, accessToken, buildPullRequestListQuery(options), &payload); err != nil {
		return nil, err
	}
	pulls := make([]PullRequest, 0, len(payload))
	for _, item := range payload {
		pulls = append(pulls, mapPullRequest(item))
	}
	return pulls, nil
}

func (c *Client) SearchPullRequests(ctx context.Context, host, accessToken, query string, page, perPage int) ([]PullRequest, error) {
	var payload searchIssuesResponseWire
	values := url.Values{}
	values.Set("q", query)
	setPage(values, page, perPage)
	if err := c.getJSONWithQuery(ctx, c.apiBaseURL(host)+"/search/issues", accessToken, values, &payload); err != nil {
		return nil, err
	}
	pulls := make([]PullRequest, 0, len(payload.Items))
	for _, item := range payload.Items {
		pulls = append(pulls, mapPullRequest(searchIssueToPullRequest(item)))
	}
	return pulls, nil
}

func (c *Client) GetPullRequest(ctx context.Context, host, owner, repo string, number int, accessToken string) (*PullRequest, error) {
	endpoint := c.repoEndpoint(host, owner, repo, "/pulls/"+strconv.Itoa(number))
	var payload pullRequestWire
	if err := c.getJSON(ctx, endpoint, accessToken, &payload); err != nil {
		return nil, err
	}
	pr := mapPullRequest(payload)
	return &pr, nil
}

func (c *Client) GetPullRequestChecks(ctx context.Context, host, owner, repo string, number int, accessToken string) (*PullRequestChecks, error) {
	pr, err := c.GetPullRequest(ctx, host, owner, repo, number, accessToken)
	if err != nil {
		return nil, err
	}
	sha := strings.TrimSpace(pr.HeadRef.SHA)
	if sha == "" {
		return &PullRequestChecks{State: "unknown", Checks: []PullRequestCheckRun{}}, nil
	}

	statusEndpoint := c.repoEndpoint(host, owner, repo, "/commits/"+url.PathEscape(sha)+"/status")
	checksEndpoint := c.repoEndpoint(host, owner, repo, "/commits/"+url.PathEscape(sha)+"/check-runs")

	var statusPayload combinedStatusWire
	var checksPayload checkRunsResponseWire
	statusErr := c.getJSON(ctx, statusEndpoint, accessToken, &statusPayload)
	checksErr := c.getJSON(ctx, checksEndpoint, accessToken, &checksPayload)

	if statusErr != nil && !IsAPIStatus(statusErr, http.StatusNotFound) {
		return nil, statusErr
	}
	if checksErr != nil && !IsAPIStatus(checksErr, http.StatusNotFound) {
		return nil, checksErr
	}

	result := aggregatePullRequestChecks(statusPayload, checksPayload)
	return &result, nil
}

func (c *Client) ListPullRequestFiles(ctx context.Context, host, owner, repo string, number int, accessToken string, options ListOptions) ([]PullRequestFile, error) {
	endpoint := c.repoEndpoint(host, owner, repo, "/pulls/"+strconv.Itoa(number)+"/files")
	var payload []pullRequestFileWire
	if err := c.getJSONWithQuery(ctx, endpoint, accessToken, buildListQuery(options), &payload); err != nil {
		return nil, err
	}
	files := make([]PullRequestFile, 0, len(payload))
	for _, item := range payload {
		files = append(files, mapPullRequestFile(item))
	}
	return files, nil
}

func (c *Client) ListPullRequestComments(ctx context.Context, host, owner, repo string, number int, accessToken string, options ListOptions) ([]PullRequestComment, error) {
	endpoint := c.repoEndpoint(host, owner, repo, "/pulls/"+strconv.Itoa(number)+"/comments")
	var payload []pullRequestCommentWire
	if err := c.getJSONWithQuery(ctx, endpoint, accessToken, buildListQuery(options), &payload); err != nil {
		return nil, err
	}
	comments := make([]PullRequestComment, 0, len(payload))
	for _, item := range payload {
		comments = append(comments, mapPullRequestComment(item))
	}
	return comments, nil
}

func (c *Client) CreatePullRequestComment(ctx context.Context, host, owner, repo string, number int, accessToken string, input CreatePullRequestCommentInput) (*PullRequestComment, error) {
	endpoint := c.repoEndpoint(host, owner, repo, "/pulls/"+strconv.Itoa(number)+"/comments")
	body := map[string]any{"body": input.Body}
	if input.InReplyTo > 0 {
		body["in_reply_to"] = input.InReplyTo
	} else {
		body["path"] = input.Path
		body["commit_id"] = input.CommitID
		body["side"] = input.Side
		body["line"] = input.Line
		if input.StartSide != "" {
			body["start_side"] = input.StartSide
		}
		if input.StartLine > 0 {
			body["start_line"] = input.StartLine
		}
	}

	var payload pullRequestCommentWire
	if err := c.postJSON(ctx, endpoint, accessToken, body, &payload); err != nil {
		return nil, err
	}
	comment := mapPullRequestComment(payload)
	return &comment, nil
}

func (c *Client) ListPullRequestReviews(ctx context.Context, host, owner, repo string, number int, accessToken string, options ListOptions) ([]PullRequestReview, error) {
	endpoint := c.repoEndpoint(host, owner, repo, "/pulls/"+strconv.Itoa(number)+"/reviews")
	var payload []pullRequestReviewWire
	if err := c.getJSONWithQuery(ctx, endpoint, accessToken, buildListQuery(options), &payload); err != nil {
		return nil, err
	}
	reviews := make([]PullRequestReview, 0, len(payload))
	for _, item := range payload {
		reviews = append(reviews, mapPullRequestReview(item))
	}
	return reviews, nil
}

func (c *Client) CreatePullRequestReview(ctx context.Context, host, owner, repo string, number int, accessToken string, input CreatePullRequestReviewInput) (*PullRequestReview, error) {
	endpoint := c.repoEndpoint(host, owner, repo, "/pulls/"+strconv.Itoa(number)+"/reviews")
	body := map[string]any{}
	if input.Event != "" {
		body["event"] = input.Event
	}
	if input.Body != "" {
		body["body"] = input.Body
	}
	if input.CommitID != "" {
		body["commit_id"] = input.CommitID
	}
	if len(input.Comments) > 0 {
		comments := make([]map[string]any, 0, len(input.Comments))
		for _, comment := range input.Comments {
			item := map[string]any{
				"body": comment.Body,
				"path": comment.Path,
				"line": comment.Line,
			}
			if comment.Side != "" {
				item["side"] = comment.Side
			}
			if comment.StartSide != "" {
				item["start_side"] = comment.StartSide
			}
			if comment.StartLine > 0 {
				item["start_line"] = comment.StartLine
			}
			comments = append(comments, item)
		}
		body["comments"] = comments
	}

	var payload pullRequestReviewWire
	if err := c.postJSON(ctx, endpoint, accessToken, body, &payload); err != nil {
		return nil, err
	}
	review := mapPullRequestReview(payload)
	return &review, nil
}

func (c *Client) exchangeToken(ctx context.Context, host string, values url.Values) (*TokenResponse, error) {
	var resp TokenResponse
	if err := c.postForm(ctx, c.webBaseURL(host)+"/login/oauth/access_token", values, &resp); err != nil {
		return nil, err
	}
	if resp.Error != "" {
		return nil, &HostError{Host: NormalizeHost(host), Err: mapOAuthError(resp.Error)}
	}
	return &resp, nil
}

func (c *Client) getJSON(ctx context.Context, endpoint, accessToken string, out any) error {
	return c.getJSONWithQuery(ctx, endpoint, accessToken, nil, out)
}

func (c *Client) getJSONWithQuery(ctx context.Context, endpoint, accessToken string, query url.Values, out any) error {
	if len(query) > 0 {
		if strings.Contains(endpoint, "?") {
			endpoint += "&" + query.Encode()
		} else {
			endpoint += "?" + query.Encode()
		}
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return err
	}
	applyGitHubHeaders(req, accessToken)
	return c.doJSON(req, out)
}

func (c *Client) postJSON(ctx context.Context, endpoint, accessToken string, payload any, out any) error {
	body, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return err
	}
	applyGitHubHeaders(req, accessToken)
	req.Header.Set("Content-Type", "application/json")
	return c.doJSON(req, out)
}

func (c *Client) doJSON(req *http.Request, out any) error {
	resp, err := c.httpClient.Do(req)
	if err != nil {
		return &HostError{Host: NormalizeHost(hostFromURL(req.URL.String())), Err: err}
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return decodeAPIError(resp, req.URL.String())
	}
	if out == nil {
		return nil
	}
	if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
		return &HostError{Host: NormalizeHost(hostFromURL(req.URL.String())), Err: fmt.Errorf("decode github response: %w", err)}
	}
	return nil
}

func (c *Client) postForm(ctx context.Context, endpoint string, values url.Values, out any) error {
	body := bytes.NewBufferString(values.Encode())
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, body)
	if err != nil {
		return err
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return &HostError{Host: NormalizeHost(hostFromURL(endpoint)), Err: err}
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		payload, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return &HostError{Host: NormalizeHost(hostFromURL(endpoint)), Err: fmt.Errorf("github auth request failed: status=%d body=%s", resp.StatusCode, strings.TrimSpace(string(payload)))}
	}

	if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
		return &HostError{Host: NormalizeHost(hostFromURL(endpoint)), Err: fmt.Errorf("decode github auth response: %w", err)}
	}
	return nil
}

func applyGitHubHeaders(req *http.Request, accessToken string) {
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	if strings.TrimSpace(accessToken) != "" {
		req.Header.Set("Authorization", "Bearer "+accessToken)
	}
}

func decodeAPIError(resp *http.Response, endpoint string) error {
	payload, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	message := strings.TrimSpace(string(payload))
	var parsed struct {
		Message string `json:"message"`
	}
	if len(payload) > 0 && json.Unmarshal(payload, &parsed) == nil && strings.TrimSpace(parsed.Message) != "" {
		message = strings.TrimSpace(parsed.Message)
	}
	return &APIError{Host: NormalizeHost(hostFromURL(endpoint)), StatusCode: resp.StatusCode, Message: message}
}

func (c *Client) repoEndpoint(host, owner, repo, suffix string) string {
	return c.apiBaseURL(host) + "/repos/" + url.PathEscape(owner) + "/" + url.PathEscape(repo) + suffix
}

func mapOAuthError(code string) error {
	switch code {
	case "authorization_pending":
		return ErrAuthorizationPending
	case "slow_down":
		return ErrSlowDown
	case "access_denied":
		return ErrAccessDenied
	case "expired_token":
		return ErrExpiredToken
	case "bad_verification_code", "bad_refresh_token", "incorrect_client_credentials":
		return ErrBadRefreshToken
	default:
		return fmt.Errorf("github oauth error: %s", code)
	}
}

func webBaseURL(host string) string {
	return "https://" + NormalizeHost(host)
}

func apiBaseURL(host string) string {
	normalized := NormalizeHost(host)
	if normalized == DefaultHost {
		return "https://api.github.com"
	}
	return webBaseURL(normalized) + "/api/v3"
}

func hostFromURL(raw string) string {
	parsed, err := url.Parse(raw)
	if err != nil {
		return ""
	}
	if parsed.Path != "" {
		parsed.Path = path.Clean(parsed.Path)
	}
	return parsed.Host
}

type accountWire struct {
	Login     string `json:"login"`
	ID        int64  `json:"id"`
	Name      string `json:"name"`
	AvatarURL string `json:"avatar_url"`
	HTMLURL   string `json:"html_url"`
}

type actorWire struct {
	Login     string `json:"login"`
	ID        int64  `json:"id"`
	AvatarURL string `json:"avatar_url"`
	HTMLURL   string `json:"html_url"`
}

type labelWire struct {
	Name  string `json:"name"`
	Color string `json:"color"`
}

type issueWire struct {
	Number      int         `json:"number"`
	Title       string      `json:"title"`
	State       string      `json:"state"`
	Body        string      `json:"body"`
	HTMLURL     string      `json:"html_url"`
	Comments    int         `json:"comments"`
	Locked      bool        `json:"locked"`
	User        *actorWire  `json:"user"`
	Assignees   []actorWire `json:"assignees"`
	Labels      []labelWire `json:"labels"`
	CreatedAt   *time.Time  `json:"created_at"`
	UpdatedAt   *time.Time  `json:"updated_at"`
	ClosedAt    *time.Time  `json:"closed_at"`
	PullRequest struct {
		URL string `json:"url"`
	} `json:"pull_request"`
}

type issueCommentWire struct {
	ID        int64      `json:"id"`
	Body      string     `json:"body"`
	HTMLURL   string     `json:"html_url"`
	User      *actorWire `json:"user"`
	CreatedAt *time.Time `json:"created_at"`
	UpdatedAt *time.Time `json:"updated_at"`
}

type pullRefRepoWire struct {
	FullName string `json:"full_name"`
	Owner    struct {
		Login string `json:"login"`
	} `json:"owner"`
	Name string `json:"name"`
}

type pullRefWire struct {
	Label string           `json:"label"`
	Ref   string           `json:"ref"`
	SHA   string           `json:"sha"`
	Repo  *pullRefRepoWire `json:"repo"`
}

type pullRequestWire struct {
	Number         int         `json:"number"`
	Title          string      `json:"title"`
	State          string      `json:"state"`
	Body           string      `json:"body"`
	HTMLURL        string      `json:"html_url"`
	Draft          bool        `json:"draft"`
	Merged         bool        `json:"merged"`
	Mergeable      *bool       `json:"mergeable"`
	MergeableState string      `json:"mergeable_state"`
	Comments       int         `json:"comments"`
	ReviewComments int         `json:"review_comments"`
	Commits        int         `json:"commits"`
	Additions      int         `json:"additions"`
	Deletions      int         `json:"deletions"`
	ChangedFiles   int         `json:"changed_files"`
	User           *actorWire  `json:"user"`
	Assignees      []actorWire `json:"assignees"`
	Labels         []labelWire `json:"labels"`
	Base           pullRefWire `json:"base"`
	Head           pullRefWire `json:"head"`
	CreatedAt      *time.Time  `json:"created_at"`
	UpdatedAt      *time.Time  `json:"updated_at"`
	ClosedAt       *time.Time  `json:"closed_at"`
	MergedAt       *time.Time  `json:"merged_at"`
}

type pullRequestFileWire struct {
	SHA              string `json:"sha"`
	Filename         string `json:"filename"`
	Status           string `json:"status"`
	Additions        int    `json:"additions"`
	Deletions        int    `json:"deletions"`
	Changes          int    `json:"changes"`
	BlobURL          string `json:"blob_url"`
	RawURL           string `json:"raw_url"`
	Patch            string `json:"patch"`
	PreviousFilename string `json:"previous_filename"`
}

type pullRequestCommentWire struct {
	ID               int64      `json:"id"`
	Body             string     `json:"body"`
	HTMLURL          string     `json:"html_url"`
	Path             string     `json:"path"`
	DiffHunk         string     `json:"diff_hunk"`
	CommitID         string     `json:"commit_id"`
	OriginalCommitID string     `json:"original_commit_id"`
	Position         int        `json:"position"`
	OriginalPosition int        `json:"original_position"`
	Line             int        `json:"line"`
	OriginalLine     int        `json:"original_line"`
	Side             string     `json:"side"`
	StartLine        int        `json:"start_line"`
	StartSide        string     `json:"start_side"`
	InReplyToID      int64      `json:"in_reply_to_id"`
	User             *actorWire `json:"user"`
	CreatedAt        *time.Time `json:"created_at"`
	UpdatedAt        *time.Time `json:"updated_at"`
}

type pullRequestReviewWire struct {
	ID          int64      `json:"id"`
	Body        string     `json:"body"`
	State       string     `json:"state"`
	CommitID    string     `json:"commit_id"`
	HTMLURL     string     `json:"html_url"`
	User        *actorWire `json:"user"`
	SubmittedAt *time.Time `json:"submitted_at"`
}

type combinedStatusWire struct {
	State      string                  `json:"state"`
	Statuses   []combinedStatusRunWire `json:"statuses"`
	TotalCount int                     `json:"total_count"`
}

type combinedStatusRunWire struct {
	Context     string     `json:"context"`
	State       string     `json:"state"`
	TargetURL   string     `json:"target_url"`
	CreatedAt   *time.Time `json:"created_at"`
	UpdatedAt   *time.Time `json:"updated_at"`
	Description string     `json:"description"`
}

type checkRunsResponseWire struct {
	TotalCount int            `json:"total_count"`
	CheckRuns  []checkRunWire `json:"check_runs"`
}

type checkRunWire struct {
	Name        string     `json:"name"`
	Status      string     `json:"status"`
	Conclusion  string     `json:"conclusion"`
	DetailsURL  string     `json:"details_url"`
	StartedAt   *time.Time `json:"started_at"`
	CompletedAt *time.Time `json:"completed_at"`
}

type searchIssuesResponseWire struct {
	TotalCount int         `json:"total_count"`
	Items      []issueWire `json:"items"`
}

func mapAccount(in accountWire) Account {
	return Account{Login: in.Login, ID: in.ID, Name: in.Name, AvatarURL: in.AvatarURL, HTMLURL: in.HTMLURL}
}

func mapActor(in *actorWire) *Actor {
	if in == nil {
		return nil
	}
	return &Actor{Login: in.Login, ID: in.ID, AvatarURL: in.AvatarURL, HTMLURL: in.HTMLURL}
}

func mapActors(in []actorWire) []Actor {
	if len(in) == 0 {
		return nil
	}
	out := make([]Actor, 0, len(in))
	for _, item := range in {
		out = append(out, Actor{Login: item.Login, ID: item.ID, AvatarURL: item.AvatarURL, HTMLURL: item.HTMLURL})
	}
	return out
}

func mapLabels(in []labelWire) []Label {
	if len(in) == 0 {
		return nil
	}
	out := make([]Label, 0, len(in))
	for _, item := range in {
		out = append(out, Label{Name: item.Name, Color: item.Color})
	}
	return out
}

func mapIssue(in issueWire) Issue {
	return Issue{
		Number:        in.Number,
		Title:         in.Title,
		State:         in.State,
		Body:          in.Body,
		HTMLURL:       in.HTMLURL,
		CommentsCount: in.Comments,
		Locked:        in.Locked,
		Author:        mapActor(in.User),
		Assignees:     mapActors(in.Assignees),
		Labels:        mapLabels(in.Labels),
		CreatedAt:     in.CreatedAt,
		UpdatedAt:     in.UpdatedAt,
		ClosedAt:      in.ClosedAt,
	}
}

func mapIssueComment(in issueCommentWire) IssueComment {
	return IssueComment{ID: in.ID, Body: in.Body, HTMLURL: in.HTMLURL, Author: mapActor(in.User), CreatedAt: in.CreatedAt, UpdatedAt: in.UpdatedAt}
}

func mapPullRequestRef(in pullRefWire) PullRequestRef {
	return PullRequestRef{Label: in.Label, Ref: in.Ref, SHA: in.SHA}
}

func mapPullRequest(in pullRequestWire) PullRequest {
	return PullRequest{
		Number:              in.Number,
		Title:               in.Title,
		State:               in.State,
		Body:                in.Body,
		HTMLURL:             in.HTMLURL,
		Draft:               in.Draft,
		Merged:              in.Merged,
		Mergeable:           in.Mergeable,
		MergeableState:      in.MergeableState,
		CommentsCount:       in.Comments,
		ReviewCommentsCount: in.ReviewComments,
		CommitsCount:        in.Commits,
		Additions:           in.Additions,
		Deletions:           in.Deletions,
		ChangedFiles:        in.ChangedFiles,
		Author:              mapActor(in.User),
		Assignees:           mapActors(in.Assignees),
		Labels:              mapLabels(in.Labels),
		BaseRef:             mapPullRequestRef(in.Base),
		HeadRef:             mapPullRequestRef(in.Head),
		CreatedAt:           in.CreatedAt,
		UpdatedAt:           in.UpdatedAt,
		ClosedAt:            in.ClosedAt,
		MergedAt:            in.MergedAt,
	}
}

func searchIssueToPullRequest(in issueWire) pullRequestWire {
	return pullRequestWire{
		Number:    in.Number,
		Title:     in.Title,
		State:     in.State,
		Body:      in.Body,
		HTMLURL:   in.HTMLURL,
		Comments:  in.Comments,
		User:      in.User,
		Assignees: in.Assignees,
		Labels:    in.Labels,
		CreatedAt: in.CreatedAt,
		UpdatedAt: in.UpdatedAt,
		ClosedAt:  in.ClosedAt,
	}
}

func mapPullRequestFile(in pullRequestFileWire) PullRequestFile {
	return PullRequestFile{SHA: in.SHA, Filename: in.Filename, Status: in.Status, Additions: in.Additions, Deletions: in.Deletions, Changes: in.Changes, BlobURL: in.BlobURL, RawURL: in.RawURL, Patch: in.Patch, PreviousFilename: in.PreviousFilename}
}

func mapPullRequestComment(in pullRequestCommentWire) PullRequestComment {
	return PullRequestComment{
		ID:               in.ID,
		Body:             in.Body,
		HTMLURL:          in.HTMLURL,
		Path:             in.Path,
		DiffHunk:         in.DiffHunk,
		CommitID:         in.CommitID,
		OriginalCommitID: in.OriginalCommitID,
		Position:         in.Position,
		OriginalPosition: in.OriginalPosition,
		Line:             in.Line,
		OriginalLine:     in.OriginalLine,
		Side:             in.Side,
		StartLine:        in.StartLine,
		StartSide:        in.StartSide,
		InReplyToID:      in.InReplyToID,
		Author:           mapActor(in.User),
		CreatedAt:        in.CreatedAt,
		UpdatedAt:        in.UpdatedAt,
	}
}

func mapPullRequestReview(in pullRequestReviewWire) PullRequestReview {
	return PullRequestReview{ID: in.ID, Body: in.Body, State: in.State, CommitID: in.CommitID, HTMLURL: in.HTMLURL, Author: mapActor(in.User), SubmittedAt: in.SubmittedAt}
}

func aggregatePullRequestChecks(status combinedStatusWire, runs checkRunsResponseWire) PullRequestChecks {
	checks := PullRequestChecks{Checks: []PullRequestCheckRun{}}
	for _, item := range runs.CheckRuns {
		check := PullRequestCheckRun{Name: item.Name, Status: item.Status, Conclusion: item.Conclusion, DetailsURL: item.DetailsURL, StartedAt: item.StartedAt, CompletedAt: item.CompletedAt}
		checks.Checks = append(checks.Checks, check)
		switch {
		case strings.EqualFold(item.Status, "completed") && isSuccessConclusion(item.Conclusion):
			checks.SuccessCount++
		case strings.EqualFold(item.Status, "queued") || strings.EqualFold(item.Status, "in_progress") || strings.EqualFold(item.Status, "pending"):
			checks.PendingCount++
		case strings.EqualFold(item.Status, "completed"):
			checks.FailureCount++
		default:
			checks.PendingCount++
		}
	}
	for _, item := range status.Statuses {
		check := PullRequestCheckRun{Name: item.Context, Status: item.State, DetailsURL: item.TargetURL, StartedAt: item.CreatedAt, CompletedAt: item.UpdatedAt}
		checks.Checks = append(checks.Checks, check)
		switch strings.ToLower(strings.TrimSpace(item.State)) {
		case "success":
			checks.SuccessCount++
		case "pending":
			checks.PendingCount++
		default:
			checks.FailureCount++
		}
	}
	checks.TotalCount = len(checks.Checks)
	checks.State = aggregateCheckState(checks)
	return checks
}

func aggregateCheckState(in PullRequestChecks) string {
	switch {
	case in.FailureCount > 0:
		return "failure"
	case in.PendingCount > 0:
		return "pending"
	case in.SuccessCount > 0:
		return "success"
	default:
		return "unknown"
	}
}

func isSuccessConclusion(conclusion string) bool {
	switch strings.ToLower(strings.TrimSpace(conclusion)) {
	case "", "success", "neutral", "skipped":
		return true
	default:
		return false
	}
}
