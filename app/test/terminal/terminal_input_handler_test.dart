import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vscode_mobile/terminal/terminal_input_handler.dart';

void main() {
  group('TerminalInputHandler', () {
    test('maps navigation and function keys to xterm sequences', () {
      expect(
        TerminalInputHandler.translateKey(LogicalKeyboardKey.arrowUp),
        '\x1B[A',
      );
      expect(
        TerminalInputHandler.translateKey(LogicalKeyboardKey.arrowDown),
        '\x1B[B',
      );
      expect(
        TerminalInputHandler.translateKey(LogicalKeyboardKey.f5),
        '\x1B[15~',
      );
      expect(
        TerminalInputHandler.translateKey(
          LogicalKeyboardKey.tab,
          shiftPressed: true,
        ),
        '\x1B[Z',
      );
      expect(
        TerminalInputHandler.translateKey(
          LogicalKeyboardKey.arrowUp,
          applicationCursorKeys: true,
        ),
        '\x1BOA',
      );
      expect(
        TerminalInputHandler.translateKey(
          LogicalKeyboardKey.home,
          applicationCursorKeys: true,
        ),
        '\x1BOH',
      );
    });

    test('maps printable ctrl combinations to control bytes', () {
      expect(
        TerminalInputHandler.translateKey(
          LogicalKeyboardKey.keyC,
          character: 'c',
          ctrlPressed: true,
        ),
        '\x03',
      );
      expect(TerminalInputHandler.ctrlCharacter('/'), '\x1F');
      expect(TerminalInputHandler.ctrlCharacter(' '), '\x00');
    });

    test('prefixes alt modified printable keys with escape', () {
      expect(
        TerminalInputHandler.translateKey(
          LogicalKeyboardKey.keyH,
          character: 'h',
          altPressed: true,
        ),
        '\x1Bh',
      );
    });

    test('passes through plain printable characters', () {
      expect(
        TerminalInputHandler.translateKey(
          LogicalKeyboardKey.keyA,
          character: 'a',
        ),
        'a',
      );
      expect(
        TerminalInputHandler.translateKey(LogicalKeyboardKey.shiftLeft),
        isNull,
      );
    });
  });
}
