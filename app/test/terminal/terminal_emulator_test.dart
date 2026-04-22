import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscode_mobile/terminal/terminal_emulator.dart';

void main() {
  group('TerminalEmulator', () {
    test('writes printable text into the visible grid', () {
      final emulator = TerminalEmulator(rows: 3, cols: 6);

      emulator.write('hello');
      final snapshot = emulator.snapshot(clearDirtyRows: true);

      expect(snapshot.lines[0].toDisplayString(trimRight: true), 'hello');
      expect(snapshot.cursor.row, 0);
      expect(snapshot.cursor.column, 5);
      expect(snapshot.dirtyRows, {0});
    });

    test('handles carriage return and backspace overwrite', () {
      final emulator = TerminalEmulator(rows: 2, cols: 8);

      emulator.write('hello\rYo\b!');
      final snapshot = emulator.snapshot();

      expect(snapshot.lines[0].toDisplayString(trimRight: true), 'Y!llo');
    });

    test('tracks scrollback when output exceeds viewport height', () {
      final emulator = TerminalEmulator(rows: 2, cols: 8);

      emulator.write('one\r\ntwo\r\nthree');
      final snapshot = emulator.snapshot();

      expect(snapshot.scrollbackLength, 1);
      expect(snapshot.lines[0].toDisplayString(trimRight: true), 'two');
      expect(snapshot.lines[1].toDisplayString(trimRight: true), 'three');
      expect(emulator.plainText, contains('one'));
    });

    test('switches between main and alternate buffers with 1049 mode', () {
      final emulator = TerminalEmulator(rows: 2, cols: 10);

      emulator.write('shell\r\nready');
      emulator.write('\u001b[?1049h');
      emulator.write('alt');

      final alternate = emulator.snapshot();
      expect(alternate.isAlternateBuffer, isTrue);
      expect(alternate.lines[0].toDisplayString(trimRight: true), 'alt');
      expect(alternate.scrollbackLength, 0);

      emulator.write('\u001b[?1049l');
      final restored = emulator.snapshot();
      expect(restored.isAlternateBuffer, isFalse);
      expect(restored.lines[0].toDisplayString(trimRight: true), 'shell');
      expect(restored.lines[1].toDisplayString(trimRight: true), 'ready');
    });

    test('supports core zellij-oriented CSI mutations', () {
      final emulator = TerminalEmulator(rows: 4, cols: 8);

      emulator.write('abcd');
      emulator.write('\u001b[1;2H');
      emulator.write('\u001b[@');
      emulator.write('Z');
      emulator.write('\u001b[1;4H');
      emulator.write('\u001b[P');
      emulator.write('\u001b[2;4r');
      emulator.write('\u001b[2;1H');
      emulator.write('\u001b[L');
      emulator.write('X');

      final snapshot = emulator.snapshot();
      expect(snapshot.lines[0].toDisplayString(trimRight: true), 'aZbd');
      expect(snapshot.lines[1].toDisplayString(trimRight: true), 'X');
    });

    test('emits device-status and device-attribute responses', () {
      final emulator = TerminalEmulator(rows: 3, cols: 8);

      emulator.write('hi');
      final responses = emulator.write('\u001b[6n\u001b[5n\u001b[c\u001b[>c');

      expect(
        responses,
        equals(<String>[
          '\x1B[1;3R',
          '\x1B[0n',
          '\x1B[?62;1;6;22c',
          '\x1B[>0;0;0c',
        ]),
      );
    });

    test('tracks application cursor mode and save/restore cursor', () {
      final emulator = TerminalEmulator(rows: 2, cols: 8);

      emulator.write('\u001b[?1h');
      expect(emulator.snapshot().applicationCursorKeys, isTrue);

      emulator.write('\u001b[s');
      emulator.write('\u001b[2;5H');
      expect(emulator.snapshot().cursor.row, 1);
      expect(emulator.snapshot().cursor.column, 4);

      emulator.write('\u001b[u');
      final restored = emulator.snapshot();
      expect(restored.cursor.row, 0);
      expect(restored.cursor.column, 0);

      emulator.write('\u001b[?1l');
      expect(emulator.snapshot().applicationCursorKeys, isFalse);
    });

    test('treats wide and combining characters as cell-aware writes', () {
      final emulator = TerminalEmulator(rows: 1, cols: 6);

      emulator.write('A你e\u0301🙂');
      final snapshot = emulator.snapshot();

      expect(snapshot.lines[0].cells[0].text, 'A');
      expect(snapshot.lines[0].cells[1].text, '你');
      expect(snapshot.lines[0].cells[1].width, 2);
      expect(snapshot.lines[0].cells[2].isPlaceholder, isTrue);
      expect(snapshot.lines[0].cells[3].text, 'e\u0301');
      expect(snapshot.lines[0].cells[4].text, '🙂');
      expect(snapshot.lines[0].cells[4].width, 2);
    });

    test('resizes while keeping the newest visible content', () {
      final emulator = TerminalEmulator(rows: 3, cols: 6);

      emulator.write('aa\r\nbb\r\ncc');
      emulator.resize(2, 4);
      final snapshot = emulator.snapshot();

      expect(snapshot.rows, 2);
      expect(snapshot.cols, 4);
      expect(snapshot.lines[0].toDisplayString(trimRight: true), 'bb');
      expect(snapshot.lines[1].toDisplayString(trimRight: true), 'cc');
    });

    test('replays a real zellij startup fixture into the alternate screen', () {
      final fixture = File(
        'test/fixtures/terminal/zellij_startup.base64',
      ).readAsStringSync().trim();
      final bytes = base64Decode(fixture);
      final emulator = TerminalEmulator(rows: 24, cols: 80);

      emulator.writeBytes(bytes);
      final snapshot = emulator.snapshot();

      expect(snapshot.isAlternateBuffer, isTrue);
      expect(snapshot.plainText, contains('Zellij'));
      expect(snapshot.plainText, contains('Ctrl'));
      expect(snapshot.applicationCursorKeys, isFalse);
    });
  });
}
