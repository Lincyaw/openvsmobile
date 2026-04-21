import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/chat_context_attachment.dart';
import '../providers/chat_provider.dart';
import '../screens/chat_screen.dart';

Future<void> openChatWithGitHubAttachment(
  BuildContext context, {
  required String prompt,
  required GitHubChatAttachment attachment,
}) async {
  final chatProvider = context.read<ChatProvider>();
  chatProvider.queueGitHubAction(prompt: prompt, attachment: attachment);

  if (!context.mounted) {
    return;
  }

  await Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => const ChatScreen()));
}
