// Streams install.sh over SSH stdin to a remote host, parses the single
// JSON line install.sh emits on success, and surfaces stderr live to the UI.
//
// The remote side runs `bash -s -- <version> [--tarball <path>]`. We don't
// upload a file; bash reads the script body from stdin so there's no temp
// file to clean up on the remote and no permissions to worry about.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../version.dart';

sealed class SshAuth {
  const SshAuth();
}

class SshPasswordAuth extends SshAuth {
  final String password;
  const SshPasswordAuth(this.password);
}

class SshKeyAuth extends SshAuth {
  final String privateKeyPem;
  final String? passphrase;
  const SshKeyAuth({required this.privateKeyPem, this.passphrase});
}

sealed class BootstrapEvent {
  const BootstrapEvent();
}

class BootstrapStatus extends BootstrapEvent {
  final String message;
  const BootstrapStatus(this.message);
}

class BootstrapLog extends BootstrapEvent {
  final String line;
  const BootstrapLog(this.line);
}

class BootstrapSuccess extends BootstrapEvent {
  final int port;
  final String token;
  final String version;
  final bool linger;
  const BootstrapSuccess({
    required this.port,
    required this.token,
    required this.version,
    required this.linger,
  });
}

class BootstrapFailure extends BootstrapEvent {
  final int? exitCode;
  final List<String> lastStderr;
  final String reason;
  const BootstrapFailure({
    required this.exitCode,
    required this.lastStderr,
    required this.reason,
  });
}

class SshBootstrapService {
  // How many trailing stderr lines we keep around for failure reports.
  static const int _stderrTailMax = 20;

  Stream<BootstrapEvent> run({
    required String host,
    required int port,
    required String username,
    required SshAuth auth,
    String? tarballPath,
    String? githubMirror,
  }) async* {
    final controller = StreamController<BootstrapEvent>();
    unawaited(_drive(
      controller: controller,
      host: host,
      port: port,
      username: username,
      auth: auth,
      tarballPath: tarballPath,
      githubMirror: githubMirror,
    ));
    yield* controller.stream;
  }

  Future<void> _drive({
    required StreamController<BootstrapEvent> controller,
    required String host,
    required int port,
    required String username,
    required SshAuth auth,
    String? tarballPath,
    String? githubMirror,
  }) async {
    SSHClient? client;
    SSHSession? session;
    try {
      controller.add(const BootstrapStatus('Loading install.sh asset…'));
      final scriptBody = await rootBundle.loadString('assets/install.sh');

      controller.add(BootstrapStatus('Connecting to $username@$host:$port…'));
      final socket = await SSHSocket.connect(host, port,
          timeout: const Duration(seconds: 15));

      client = SSHClient(
        socket,
        username: username,
        onPasswordRequest: auth is SshPasswordAuth ? () => auth.password : null,
        identities: auth is SshKeyAuth
            ? SSHKeyPair.fromPem(auth.privateKeyPem, auth.passphrase)
            : null,
      );

      await client.authenticated;
      controller.add(const BootstrapStatus('Authenticated. Starting install.sh…'));

      final tarballArg =
          tarballPath != null && tarballPath.trim().isNotEmpty
              ? " --tarball '${_shellSingleQuote(tarballPath.trim())}'"
              : '';
      final mirror = githubMirror?.trim();
      final envPrefix = (mirror != null && mirror.isNotEmpty)
          ? "GITHUB_MIRROR='${_shellSingleQuote(mirror)}' "
          : '';
      final command =
          "${envPrefix}bash -s -- '${_shellSingleQuote(kBackendVersion)}'$tarballArg";

      session = await client.execute(command);

      final stderrTail = <String>[];
      final stderrLines = StreamController<String>();
      final stdoutBuf = StringBuffer();

      final stdoutSub = session.stdout
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(stdoutBuf.write);

      final stderrSub = session.stderr
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((line) {
        stderrLines.add(line);
        stderrTail.add(line);
        if (stderrTail.length > _stderrTailMax) {
          stderrTail.removeAt(0);
        }
        controller.add(BootstrapLog(line));
      });

      controller.add(const BootstrapStatus('Streaming install.sh over stdin…'));
      session.stdin.add(Uint8List.fromList(utf8.encode(scriptBody)));
      await session.stdin.close();

      controller.add(const BootstrapStatus('Running on remote — this may take a minute…'));

      await session.done;
      await stdoutSub.cancel();
      await stderrSub.cancel();
      await stderrLines.close();

      final exit = session.exitCode;
      if (exit == 0) {
        final jsonLine = _lastNonEmptyLine(stdoutBuf.toString());
        if (jsonLine == null) {
          controller.add(BootstrapFailure(
            exitCode: 0,
            lastStderr: List.unmodifiable(stderrTail),
            reason: 'install.sh exited 0 but emitted no JSON on stdout.',
          ));
        } else {
          try {
            final parsed = jsonDecode(jsonLine) as Map<String, dynamic>;
            controller.add(BootstrapSuccess(
              port: (parsed['port'] as num).toInt(),
              token: parsed['token'] as String,
              version: parsed['version'] as String,
              linger: (parsed['linger'] as bool?) ?? false,
            ));
          } catch (e) {
            controller.add(BootstrapFailure(
              exitCode: 0,
              lastStderr: List.unmodifiable(stderrTail),
              reason: 'Could not parse install.sh JSON output: $e\nLine was: $jsonLine',
            ));
          }
        }
      } else {
        final hint = exit == 127
            ? 'bash not found on remote — install.sh requires bash 4+.'
            : _hintForExit(exit);
        controller.add(BootstrapFailure(
          exitCode: exit,
          lastStderr: List.unmodifiable(stderrTail),
          reason: hint,
        ));
      }
    } catch (e) {
      controller.add(BootstrapFailure(
        exitCode: null,
        lastStderr: const [],
        reason: 'SSH error: $e',
      ));
    } finally {
      try {
        session?.close();
      } catch (_) {
        // Already closed (remote hangup, exit before we got here).
      }
      try {
        client?.close();
      } catch (_) {
        // Already closed (transport torn down by the failure path above).
      }
      await controller.close();
    }
  }

  static String _shellSingleQuote(String s) => s.replaceAll("'", r"'\''");

  static String? _lastNonEmptyLine(String s) {
    for (final line in s.split('\n').reversed) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    return null;
  }

  // Exit codes mirror install.sh's documented contract.
  static String _hintForExit(int? code) {
    switch (code) {
      case 2:
        return 'install.sh argument error (exit 2).';
      case 3:
        return 'Release tarball not found on GitHub for this version (exit 3).';
      case 5:
        return 'Conflict — the real service is already active (exit 5).';
      case 7:
        return 'Missing dependency on remote (exit 7) — see stderr for which one.';
      default:
        return 'install.sh exited with code $code.';
    }
  }
}
