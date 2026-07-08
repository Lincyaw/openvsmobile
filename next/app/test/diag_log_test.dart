// Unit tests for the general debug event log and its terminal-specific
// DEC private-mode sniffer (the parser most prone to off-by-one).

import 'package:flutter_test/flutter_test.dart';

import 'package:mobilecode/services/diag_log.dart';
import 'package:mobilecode/services/terminal_diag.dart';

void main() {
  final diag = DiagLog.instance;

  setUp(() {
    // The singleton carries state across tests; reset it each time.
    diag.enabled = false;
    diag.clearLive();
    diag.clearSegments();
    diag.enabled = true;
  });

  tearDown(() => diag.enabled = false);

  group('visEscapes', () {
    test('renders ESC and C0 control bytes visibly', () {
      expect(visEscapes('\x1b[<65;1;1M'), '⎋[<65;1;1M');
      expect(visEscapes('a\x01b'), 'a^Ab'); // 0x01 → ^A
      expect(visEscapes('plain'), 'plain');
    });
  });

  group('sniffDecModes', () {
    test('logs only the modes we reason about, with on/off direction', () {
      // 1000 on, 1006 on (combined), then 1002 off, plus an ignored 25.
      sniffDecModes('\x1b[?1000;1006h\x1b[?1002l\x1b[?25h');
      final modes = diag.live
          .where((e) => e.category == DiagCat.mode)
          .map((e) => e.text)
          .toList();
      expect(modes.length, 3); // 25 (cursor-visible) is filtered out
      expect(modes[0], contains('?1000↑on'));
      expect(modes[1], contains('?1006↑on'));
      expect(modes[2], contains('?1002↓off'));
    });

    test('handles alt-buffer and app-cursor-keys toggles', () {
      sniffDecModes('\x1b[?1049h\x1b[?1l');
      final modes = diag.live.where((e) => e.category == DiagCat.mode).toList();
      expect(modes[0].text, contains('alt-buffer'));
      expect(modes[1].text, contains('app-cursor-keys'));
    });

    test('ignores a truncated sequence at end of chunk', () {
      sniffDecModes('text\x1b[?100'); // no final byte
      expect(diag.live.where((e) => e.category == DiagCat.mode), isEmpty);
    });

    test('is a no-op when disabled', () {
      diag.enabled = false;
      sniffDecModes('\x1b[?1000h');
      expect(diag.live, isEmpty);
    });
  });

  group('record / mark / export', () {
    test('captures a tagged window and exports a labelled trace', () {
      diag.startRecording();
      diag.log(DiagCat.terminal, 'drag start');
      diag.mark('here it broke');
      diag.log(DiagCat.terminal, 'wheel x1');
      diag.stopRecording('problem');

      expect(diag.recording, isFalse);
      expect(diag.segments, hasLength(1));
      final seg = diag.segments.single;
      expect(seg.label, 'problem');

      final out = diag.exportText();
      expect(out, contains('segment 1 · problem'));
      expect(out, contains('◆ here it broke'));
      expect(out, contains('wheel x1'));
    });

    test('markers show live even while not recording', () {
      diag.mark('lone marker');
      expect(diag.segments, isEmpty);
      expect(diag.live.last.text, contains('lone marker'));
      expect(diag.live.last.category, DiagCat.marker);
    });

    test('arbitrary categories are accepted', () {
      diag.log('custom-subsystem', 'hello');
      expect(diag.live.last.category, 'custom-subsystem');
    });

    test('has a distinct Iroh transport category', () {
      diag.log(DiagCat.iroh, 'closed: recv EOF');
      expect(diag.live.last.category, DiagCat.iroh);
      expect(diag.live.last.text, contains('recv EOF'));
    });
  });
}
