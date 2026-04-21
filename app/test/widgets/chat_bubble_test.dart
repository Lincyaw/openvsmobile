import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vscode_mobile/models/chat_message.dart';
import 'package:vscode_mobile/widgets/chat_bubble.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('forwards file taps from assistant tool cards', (tester) async {
    String? tappedFilePath;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatBubble(
            message: const ChatMessage(
              role: 'assistant',
              content: <ContentBlock>[
                ContentBlock(
                  type: 'tool_use',
                  name: 'Read',
                  input: <String, dynamic>{
                    'file_path': '/workspace/lib/main.dart',
                  },
                ),
              ],
            ),
            onFileTap: (String filePath, FileAnnotation? annotation) {
              tappedFilePath = filePath;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Read'), findsOneWidget);
    expect(find.textContaining('/workspace/lib/main.dart'), findsOneWidget);

    await tester.tap(find.textContaining('/workspace/lib/main.dart'));
    await tester.pumpAndSettle();

    expect(tappedFilePath, '/workspace/lib/main.dart');
  });
}
