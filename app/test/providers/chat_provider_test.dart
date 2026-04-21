import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscode_mobile/models/editor_context.dart';
import 'package:vscode_mobile/providers/chat_provider.dart';

import '../test_support/chat_test_helpers.dart';

void main() {
  group('ChatProvider minimal IDE context', () {
    late RecordingWebSocketChannel channel;
    late ChatProvider provider;

    setUp(() {
      channel = RecordingWebSocketChannel();
      provider = ChatProvider(apiClient: FakeChatApiClient(channel: channel));
    });

    tearDown(() async {
      provider.dispose();
      await channel.dispose();
    });

    test('binds new conversations to the exact workspace root', () {
      provider.setWorkspace('/workspaces/alpha');

      provider.startConversation();

      final startPayload = decodeSentJson(channel, 0);
      expect(startPayload, <String, dynamic>{
        'type': 'start',
        'workspaceRoot': '/workspaces/alpha',
      });
    });

    test(
      'serializes only workspace, file, cursor, and selection for each turn when no GitHub action is queued',
      () async {
        provider.setWorkspace('/workspaces/alpha');
        provider.setEditorContext(
          const EditorChatContext(
            activeFile: '/workspaces/alpha/lib/main.dart',
            cursor: EditorCursor(line: 12, column: 4),
            selection: EditorSelection(
              start: EditorCursor(line: 10, column: 2),
              end: EditorCursor(line: 14, column: 8),
            ),
          ),
        );

        provider.resumeConversation('sess-1');
        final resumePayload = decodeSentJson(channel, 0);
        expect(resumePayload, <String, dynamic>{
          'type': 'resume',
          'sessionId': 'sess-1',
          'workspaceRoot': '/workspaces/alpha',
        });

        channel.serverSend(<String, dynamic>{
          'type': 'resumed',
          'conversationId': 'sess-1',
        });
        await Future<void>.delayed(Duration.zero);
        provider.sendMessage('Explain this code');

        final sendPayload = decodeSentJson(channel, 1);
        expect(sortedKeys(sendPayload), <String>[
          'activeFile',
          'cursor',
          'message',
          'selection',
          'sessionId',
          'type',
          'workspaceRoot',
        ]);
        expect(sendPayload['type'], 'send');
        expect(sendPayload['sessionId'], 'sess-1');
        expect(sendPayload['message'], 'Explain this code');
        expect(sendPayload['workspaceRoot'], '/workspaces/alpha');
        expect(sendPayload['activeFile'], '/workspaces/alpha/lib/main.dart');
        expect(sendPayload['cursor'], <String, dynamic>{
          'line': 12,
          'column': 4,
        });
        expect(sendPayload['selection'], <String, dynamic>{
          'start': <String, dynamic>{'line': 10, 'column': 2},
          'end': <String, dynamic>{'line': 14, 'column': 8},
        });
        expect(extractGitHubAttachmentPayload(sendPayload), isEmpty);
        expect(sendPayload.containsKey('git'), isFalse);
        expect(sendPayload.containsKey('diagnostics'), isFalse);
        expect(sendPayload.containsKey('terminal'), isFalse);
        expect(sendPayload.containsKey('tabs'), isFalse);
        expect(sendPayload.containsKey('search'), isFalse);
      },
    );

    test(
      'updates file and cursor and clears selection to null for the next turn',
      () async {
        provider.setWorkspace('/workspaces/alpha');
        provider.resumeConversation('sess-2');
        channel.serverSend(<String, dynamic>{
          'type': 'resumed',
          'conversationId': 'sess-2',
        });
        await Future<void>.delayed(Duration.zero);

        provider.setEditorContext(
          const EditorChatContext(
            activeFile: '/workspaces/alpha/lib/first.dart',
            cursor: EditorCursor(line: 3, column: 1),
            selection: EditorSelection(
              start: EditorCursor(line: 3, column: 1),
              end: EditorCursor(line: 5, column: 12),
            ),
          ),
        );
        provider.sendMessage('first turn');

        provider.setEditorContext(
          const EditorChatContext(
            activeFile: '/workspaces/alpha/lib/second.dart',
            cursor: EditorCursor(line: 9, column: 7),
            selection: null,
          ),
        );
        provider.sendMessage('second turn');

        final secondSendPayload = decodeSentJson(channel, 2);
        expect(secondSendPayload['workspaceRoot'], '/workspaces/alpha');
        expect(
          secondSendPayload['activeFile'],
          '/workspaces/alpha/lib/second.dart',
        );
        expect(secondSendPayload['cursor'], <String, dynamic>{
          'line': 9,
          'column': 7,
        });
        expect(secondSendPayload.containsKey('selection'), isTrue);
        expect(secondSendPayload['selection'], isNull);
        expect(extractGitHubAttachmentPayload(secondSendPayload), isEmpty);
      },
    );
  });

  group('ChatProvider one-shot GitHub attachments', () {
    late RecordingWebSocketChannel channel;
    late ChatProvider provider;

    setUp(() {
      channel = RecordingWebSocketChannel();
      provider = ChatProvider(apiClient: FakeChatApiClient(channel: channel));
      provider.setWorkspace('/workspaces/repo');
      provider.setEditorContext(
        const EditorChatContext(
          activeFile: '/workspaces/repo/lib/chat.dart',
          cursor: EditorCursor(line: 21, column: 6),
          selection: EditorSelection(
            start: EditorCursor(line: 18, column: 1),
            end: EditorCursor(line: 24, column: 9),
          ),
        ),
      );
      provider.resumeConversation('sess-github');
      channel.serverSend(<String, dynamic>{
        'type': 'resumed',
        'conversationId': 'sess-github',
      });
    });

    tearDown(() async {
      provider.dispose();
      await channel.dispose();
    });

    test(
      'serializes only the selected issue attachment on the next turn and preserves IDE context',
      () async {
        await Future<void>.delayed(Duration.zero);

        queueIssueAttachmentForNextTurn(
          provider,
          actionLabel: 'Summarize issue',
          repository: 'octo/repo',
          issueNumber: 7,
          title: 'Fix reconnect',
          body: 'Reconnect stalls after sleep.',
        );

        final pending = pendingChatAttachmentJson(provider);
        expect(jsonEncode(pending).toLowerCase(), contains('issue'));
        expect(jsonEncode(pending), contains('Fix reconnect'));

        provider.sendMessage('Summarize this issue');

        final sendPayload = decodeSentJson(channel, 1);
        final attachment = extractGitHubAttachmentPayload(sendPayload);
        final encodedAttachment = jsonEncode(attachment);

        expect(sendPayload['workspaceRoot'], '/workspaces/repo');
        expect(sendPayload['activeFile'], '/workspaces/repo/lib/chat.dart');
        expect(sendPayload['cursor'], <String, dynamic>{
          'line': 21,
          'column': 6,
        });
        expect(encodedAttachment.toLowerCase(), contains('issue'));
        expect(encodedAttachment, contains('Summarize issue'));
        expect(encodedAttachment, contains('octo/repo'));
        expect(encodedAttachment, contains('Fix reconnect'));
        expect(encodedAttachment, contains('Reconnect stalls after sleep.'));
        expect(encodedAttachment, isNot(contains('Inline note')));
        expect(encodedAttachment, isNot(contains('app/lib/main.dart')));
      },
    );

    test(
      'consumes the queued attachment after one send so it does not leak',
      () async {
        await Future<void>.delayed(Duration.zero);

        queuePullRequestCommentAttachmentForNextTurn(
          provider,
          actionLabel: 'Check review comment',
          repository: 'octo/repo',
          pullRequestNumber: 12,
          title: 'Add collaboration UI',
          commentId: 22,
          commentBody: 'Please cover the empty state.',
          path: 'app/lib/chat.dart',
        );

        provider.sendMessage('Handle this comment');
        final firstAttachment = extractGitHubAttachmentPayload(
          decodeSentJson(channel, 1),
        );
        expect(
          jsonEncode(firstAttachment),
          contains('Please cover the empty state.'),
        );
        expect(jsonEncode(firstAttachment), contains('app/lib/chat.dart'));

        final pendingAfterSend = pendingChatAttachmentJson(provider);
        expect(pendingAfterSend, isEmpty);

        provider.sendMessage('Now answer normally');
        final secondSendPayload = decodeSentJson(channel, 2);
        expect(extractGitHubAttachmentPayload(secondSendPayload), isEmpty);
        expect(
          jsonEncode(secondSendPayload),
          isNot(contains('Please cover the empty state.')),
        );
        expect(
          jsonEncode(secondSendPayload),
          isNot(contains('app/lib/chat.dart')),
        );
      },
    );
  });
}
