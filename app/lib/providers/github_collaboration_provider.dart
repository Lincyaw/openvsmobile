import 'package:flutter/foundation.dart';

import '../models/github_collaboration_models.dart';
import '../services/github_collaboration_api_client.dart';

class GitHubCollaborationFileAction {
  final bool shouldOpenLocalFile;
  final String localPath;
  final int? line;
  final String patchPath;
  final String patch;

  const GitHubCollaborationFileAction._({
    required this.shouldOpenLocalFile,
    required this.localPath,
    required this.line,
    required this.patchPath,
    required this.patch,
  });

  const GitHubCollaborationFileAction.openLocalFile({
    required String localPath,
    required int? line,
  }) : this._(
         shouldOpenLocalFile: true,
         localPath: localPath,
         line: line,
         patchPath: '',
         patch: '',
       );

  const GitHubCollaborationFileAction.showPatch({
    required String patchPath,
    required String patch,
  }) : this._(
         shouldOpenLocalFile: false,
         localPath: '',
         line: null,
         patchPath: patchPath,
         patch: patch,
       );
}

class GitHubCollaborationProvider extends ChangeNotifier {
  final GitHubCollaborationApiClient _apiClient;

  GitHubCollaborationProvider({required GitHubCollaborationApiClient apiClient})
    : _apiClient = apiClient;

  String _workspacePath = '';
  bool _initialized = false;
  bool _isLoadingRepo = false;
  bool _isLoadingIssues = false;
  bool _isLoadingPulls = false;
  String? _repoLoadError;
  String? _issuesLoadError;
  String? _pullsLoadError;
  GitHubCurrentRepoContext? _repoContext;
  GitHubAccountContext? _accountContext;
  List<GitHubIssue> _issues = const <GitHubIssue>[];
  List<GitHubPullRequest> _pulls = const <GitHubPullRequest>[];
  GitHubCollaborationFilter _issueFilter = const GitHubCollaborationFilter(
    state: 'open',
  );
  GitHubCollaborationFilter _pullFilter = const GitHubCollaborationFilter(
    state: 'open',
  );

  final Map<int, GitHubIssueDetail> _issueDetails = <int, GitHubIssueDetail>{};
  final Map<int, String> _issueDetailErrors = <int, String>{};
  final Set<int> _loadingIssueDetails = <int>{};
  final Set<int> _submittingIssueComments = <int>{};
  final Map<int, String> _issueSubmitErrors = <int, String>{};

  final Map<int, GitHubPullRequestDetail> _pullDetails =
      <int, GitHubPullRequestDetail>{};
  final Map<int, String> _pullDetailErrors = <int, String>{};
  final Set<int> _loadingPullDetails = <int>{};
  final Set<int> _submittingPullReviews = <int>{};
  final Set<int> _submittingPullComments = <int>{};
  final Map<int, String> _pullSubmitErrors = <int, String>{};

  String get workspacePath => _workspacePath;
  bool get isLoadingRepo => _isLoadingRepo;
  bool get isLoadingIssues => _isLoadingIssues;
  bool get isLoadingPulls => _isLoadingPulls;
  String? get repoLoadError => _repoLoadError;
  String? get issuesLoadError => _issuesLoadError;
  String? get pullsLoadError => _pullsLoadError;
  GitHubCurrentRepoContext? get repoContext => _repoContext;
  GitHubAccountContext? get accountContext => _accountContext;
  List<GitHubIssue> get issues => List<GitHubIssue>.unmodifiable(_issues);
  List<GitHubPullRequest> get pulls =>
      List<GitHubPullRequest>.unmodifiable(_pulls);
  GitHubCollaborationFilter get issueFilter => _issueFilter;
  GitHubCollaborationFilter get pullFilter => _pullFilter;

  bool get hasRepository => _repoContext?.repository != null;
  bool get needsAuthAction => _repoContext?.needsAuthAction == true;
  bool get canLoadCollaboration => _repoContext?.isOk == true;
  bool get isRepoUnavailable => _repoContext?.isRepoUnavailable == true;
  String get repoStatusMessage =>
      _repoContext?.message ?? _repoLoadError ?? 'Repository unavailable.';

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    _initialized = true;
    await refresh();
  }

  Future<void> setWorkspacePath(String path) async {
    final trimmed = path.trim();
    if (trimmed == _workspacePath) {
      return;
    }
    _workspacePath = trimmed;
    _resetTransientState();
    notifyListeners();
    if (_initialized) {
      await refresh();
    }
  }

  Future<void> refresh() async {
    await loadCurrentRepo();
    if (!canLoadCollaboration) {
      _issues = const <GitHubIssue>[];
      _pulls = const <GitHubPullRequest>[];
      _issuesLoadError = null;
      _pullsLoadError = null;
      notifyListeners();
      return;
    }
    await Future.wait<void>(<Future<void>>[loadIssues(), loadPullRequests()]);
  }

  Future<void> loadCurrentRepo() async {
    _isLoadingRepo = true;
    _repoLoadError = null;
    notifyListeners();

    try {
      _repoContext = await _apiClient.fetchCurrentRepo(
        workspacePath: _workspacePath,
      );
      if (_repoContext!.isOk) {
        try {
          _accountContext = await _apiClient.fetchAccount(
            workspacePath: _workspacePath,
          );
        } on GitHubCollaborationException {
          _accountContext = null;
        }
      } else {
        _accountContext = null;
      }
    } on GitHubCollaborationException catch (error) {
      _repoContext = null;
      _accountContext = null;
      _repoLoadError = error.toDisplayMessage();
    } finally {
      _isLoadingRepo = false;
      notifyListeners();
    }
  }

  Future<void> loadIssues({bool silent = false}) async {
    if (!canLoadCollaboration) {
      return;
    }
    if (!silent) {
      _isLoadingIssues = true;
      _issuesLoadError = null;
      notifyListeners();
    }

    try {
      _issues = await _apiClient.fetchIssues(
        filter: _issueFilter,
        workspacePath: _workspacePath,
      );
      _issuesLoadError = null;
    } on GitHubCollaborationException catch (error) {
      _issuesLoadError = error.toDisplayMessage();
      _issues = const <GitHubIssue>[];
    } finally {
      _isLoadingIssues = false;
      notifyListeners();
    }
  }

  Future<void> loadPullRequests({bool silent = false}) async {
    if (!canLoadCollaboration) {
      return;
    }
    if (!silent) {
      _isLoadingPulls = true;
      _pullsLoadError = null;
      notifyListeners();
    }

    try {
      _pulls = await _apiClient.fetchPullRequests(
        filter: _pullFilter,
        workspacePath: _workspacePath,
      );
      _pullsLoadError = null;
    } on GitHubCollaborationException catch (error) {
      _pullsLoadError = error.toDisplayMessage();
      _pulls = const <GitHubPullRequest>[];
    } finally {
      _isLoadingPulls = false;
      notifyListeners();
    }
  }

  Future<void> updateIssueFilter(GitHubCollaborationFilter filter) async {
    _issueFilter = filter;
    await loadIssues();
  }

  Future<void> updatePullFilter(GitHubCollaborationFilter filter) async {
    _pullFilter = filter;
    await loadPullRequests();
  }

  GitHubIssueDetail? issueDetailFor(int number) => _issueDetails[number];

  String? issueDetailErrorFor(int number) => _issueDetailErrors[number];

  bool isLoadingIssueDetail(int number) =>
      _loadingIssueDetails.contains(number);

  bool isSubmittingIssueComment(int number) =>
      _submittingIssueComments.contains(number);

  String? issueSubmitErrorFor(int number) => _issueSubmitErrors[number];

  Future<void> loadIssueDetail(int number, {bool forceRefresh = false}) async {
    if (!forceRefresh && _issueDetails.containsKey(number)) {
      return;
    }

    _loadingIssueDetails.add(number);
    _issueDetailErrors.remove(number);
    notifyListeners();

    try {
      _issueDetails[number] = await _apiClient.fetchIssueDetail(
        number,
        workspacePath: _workspacePath,
      );
    } on GitHubCollaborationException catch (error) {
      _issueDetailErrors[number] = error.toDisplayMessage();
    } finally {
      _loadingIssueDetails.remove(number);
      notifyListeners();
    }
  }

  Future<bool> submitIssueComment(int number, String body) async {
    if (body.trim().isEmpty) {
      _issueSubmitErrors[number] = 'Comment body cannot be empty.';
      notifyListeners();
      return false;
    }

    _submittingIssueComments.add(number);
    _issueSubmitErrors.remove(number);
    notifyListeners();

    try {
      await _apiClient.submitIssueComment(
        number,
        GitHubIssueCommentInput(body: body.trim()),
        workspacePath: _workspacePath,
      );
      await loadIssueDetail(number, forceRefresh: true);
      return true;
    } on GitHubCollaborationException catch (error) {
      _issueSubmitErrors[number] = error.toDisplayMessage();
      notifyListeners();
      return false;
    } finally {
      _submittingIssueComments.remove(number);
      notifyListeners();
    }
  }

  GitHubPullRequestDetail? pullRequestDetailFor(int number) =>
      _pullDetails[number];

  String? pullRequestDetailErrorFor(int number) => _pullDetailErrors[number];

  bool isLoadingPullRequestDetail(int number) =>
      _loadingPullDetails.contains(number);

  bool isSubmittingPullRequestReview(int number) =>
      _submittingPullReviews.contains(number);

  bool isSubmittingPullRequestComment(int number) =>
      _submittingPullComments.contains(number);

  String? pullSubmitErrorFor(int number) => _pullSubmitErrors[number];

  Future<void> loadPullRequestDetail(
    int number, {
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && _pullDetails.containsKey(number)) {
      return;
    }

    _loadingPullDetails.add(number);
    _pullDetailErrors.remove(number);
    notifyListeners();

    try {
      _pullDetails[number] = await _apiClient.fetchPullRequestDetail(
        number,
        workspacePath: _workspacePath,
      );
    } on GitHubCollaborationException catch (error) {
      _pullDetailErrors[number] = error.toDisplayMessage();
    } finally {
      _loadingPullDetails.remove(number);
      notifyListeners();
    }
  }

  Future<void> loadPullRequestConversation(
    int number, {
    bool notify = true,
  }) async {
    if (notify) {
      _loadingPullDetails.add(number);
      _pullDetailErrors.remove(number);
      notifyListeners();
    }

    try {
      final conversation = await _apiClient.fetchPullRequestConversation(
        number,
        workspacePath: _workspacePath,
      );
      final current = _pullDetails[number];
      if (current != null) {
        _pullDetails[number] = GitHubPullRequestDetail(
          pullRequest: current.pullRequest,
          files: current.files,
          comments: conversation.comments,
          reviews: conversation.reviews,
        );
      }
    } on GitHubCollaborationException catch (error) {
      _pullDetailErrors[number] = error.toDisplayMessage();
    } finally {
      if (notify) {
        _loadingPullDetails.remove(number);
        notifyListeners();
      }
    }
  }

  Future<bool> submitPullRequestReview(
    int number,
    GitHubPullRequestReviewInput input,
  ) async {
    if (input.event.trim().isEmpty) {
      _pullSubmitErrors[number] = 'Review action is required.';
      notifyListeners();
      return false;
    }

    _submittingPullReviews.add(number);
    _pullSubmitErrors.remove(number);
    notifyListeners();

    try {
      await _apiClient.submitPullRequestReview(
        number,
        input,
        workspacePath: _workspacePath,
      );
      await loadPullRequestDetail(number, forceRefresh: true);
      return true;
    } on GitHubCollaborationException catch (error) {
      _pullSubmitErrors[number] = error.toDisplayMessage();
      notifyListeners();
      return false;
    } finally {
      _submittingPullReviews.remove(number);
      notifyListeners();
    }
  }

  Future<bool> submitPullRequestComment(
    int number,
    GitHubPullRequestCommentInput input,
  ) async {
    if (input.body.trim().isEmpty) {
      _pullSubmitErrors[number] = 'Comment body cannot be empty.';
      notifyListeners();
      return false;
    }

    _submittingPullComments.add(number);
    _pullSubmitErrors.remove(number);
    notifyListeners();

    try {
      await _apiClient.submitPullRequestComment(
        number,
        input,
        workspacePath: _workspacePath,
      );
      await loadPullRequestDetail(number, forceRefresh: true);
      return true;
    } on GitHubCollaborationException catch (error) {
      _pullSubmitErrors[number] = error.toDisplayMessage();
      notifyListeners();
      return false;
    } finally {
      _submittingPullComments.remove(number);
      notifyListeners();
    }
  }

  Future<GitHubCollaborationFileAction> resolvePullRequestFileAction(
    GitHubPullRequestFile file,
  ) async {
    try {
      final result = await _apiClient.resolveLocalFile(
        workspacePath: _workspacePath,
        relativePath: file.filename,
      );
      if (result.exists) {
        return GitHubCollaborationFileAction.openLocalFile(
          localPath: result.localPath,
          line: firstChangedLineForPatch(file.patch),
        );
      }
    } on GitHubCollaborationException {
      // Fall through to the patch view when local resolution is unavailable.
    }

    return GitHubCollaborationFileAction.showPatch(
      patchPath: file.filename,
      patch: file.patch.isNotEmpty ? file.patch : 'No patch is available.',
    );
  }

  int? firstChangedLineForPatch(String patch) {
    final match = RegExp(
      r'@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@',
    ).firstMatch(patch);
    if (match == null) {
      return null;
    }
    return int.tryParse(match.group(1)!);
  }

  void _resetTransientState() {
    _repoContext = null;
    _accountContext = null;
    _repoLoadError = null;
    _issuesLoadError = null;
    _pullsLoadError = null;
    _issues = const <GitHubIssue>[];
    _pulls = const <GitHubPullRequest>[];
    _issueDetails.clear();
    _issueDetailErrors.clear();
    _loadingIssueDetails.clear();
    _submittingIssueComments.clear();
    _issueSubmitErrors.clear();
    _pullDetails.clear();
    _pullDetailErrors.clear();
    _loadingPullDetails.clear();
    _submittingPullReviews.clear();
    _submittingPullComments.clear();
    _pullSubmitErrors.clear();
  }
}
