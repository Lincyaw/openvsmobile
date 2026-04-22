import 'package:flutter/services.dart';

class TerminalInputHandler {
  const TerminalInputHandler._();

  static String? translate(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return null;
    }

    final key = event.logicalKey;
    final character = event.character;
    final hardwareKeyboard = HardwareKeyboard.instance;
    return translateKey(
      key,
      character: character,
      ctrlPressed: hardwareKeyboard.isControlPressed,
      altPressed: hardwareKeyboard.isAltPressed,
      shiftPressed: hardwareKeyboard.isShiftPressed,
    );
  }

  static String? translateKey(
    LogicalKeyboardKey key, {
    String? character,
    bool ctrlPressed = false,
    bool altPressed = false,
    bool shiftPressed = false,
    bool applicationCursorKeys = false,
  }) {
    if (_isModifierKey(key)) {
      return null;
    }

    final special = _specialSequenceForKey(
      key,
      ctrlPressed: ctrlPressed,
      altPressed: altPressed,
      shiftPressed: shiftPressed,
      applicationCursorKeys: applicationCursorKeys,
    );
    if (special != null) {
      return special;
    }

    if (character == null || character.isEmpty) {
      return null;
    }

    if (ctrlPressed) {
      return ctrlCharacter(character);
    }

    if (altPressed) {
      return '\x1B$character';
    }

    return character;
  }

  static String? ctrlCharacter(String value) {
    if (value.isEmpty) {
      return null;
    }
    final character = value.toUpperCase();
    if (character.length != 1) {
      return null;
    }
    final codeUnit = character.codeUnitAt(0);
    if (codeUnit >= 0x40 && codeUnit <= 0x5F) {
      return String.fromCharCode(codeUnit & 0x1F);
    }
    return switch (character) {
      '2' => '\x00',
      ' ' => '\x00',
      '/' => '\x1F',
      _ => null,
    };
  }

  static bool _isModifierKey(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.shiftLeft ||
        key == LogicalKeyboardKey.shiftRight ||
        key == LogicalKeyboardKey.controlLeft ||
        key == LogicalKeyboardKey.controlRight ||
        key == LogicalKeyboardKey.altLeft ||
        key == LogicalKeyboardKey.altRight ||
        key == LogicalKeyboardKey.metaLeft ||
        key == LogicalKeyboardKey.metaRight;
  }

  static String? _specialSequenceForKey(
    LogicalKeyboardKey key, {
    required bool ctrlPressed,
    required bool altPressed,
    required bool shiftPressed,
    required bool applicationCursorKeys,
  }) {
    final sequence = switch (key) {
      LogicalKeyboardKey.enter => '\r',
      LogicalKeyboardKey.numpadEnter => '\r',
      LogicalKeyboardKey.escape => '\x1B',
      LogicalKeyboardKey.tab => shiftPressed ? '\x1B[Z' : '\t',
      LogicalKeyboardKey.backspace => '\x7F',
      LogicalKeyboardKey.delete => '\x1B[3~',
      LogicalKeyboardKey.arrowUp => applicationCursorKeys ? '\x1BOA' : '\x1B[A',
      LogicalKeyboardKey.arrowDown =>
        applicationCursorKeys ? '\x1BOB' : '\x1B[B',
      LogicalKeyboardKey.arrowRight =>
        applicationCursorKeys ? '\x1BOC' : '\x1B[C',
      LogicalKeyboardKey.arrowLeft =>
        applicationCursorKeys ? '\x1BOD' : '\x1B[D',
      LogicalKeyboardKey.home => applicationCursorKeys ? '\x1BOH' : '\x1B[H',
      LogicalKeyboardKey.end => applicationCursorKeys ? '\x1BOF' : '\x1B[F',
      LogicalKeyboardKey.pageUp => '\x1B[5~',
      LogicalKeyboardKey.pageDown => '\x1B[6~',
      LogicalKeyboardKey.f1 => '\x1BOP',
      LogicalKeyboardKey.f2 => '\x1BOQ',
      LogicalKeyboardKey.f3 => '\x1BOR',
      LogicalKeyboardKey.f4 => '\x1BOS',
      LogicalKeyboardKey.f5 => '\x1B[15~',
      LogicalKeyboardKey.f6 => '\x1B[17~',
      LogicalKeyboardKey.f7 => '\x1B[18~',
      LogicalKeyboardKey.f8 => '\x1B[19~',
      LogicalKeyboardKey.f9 => '\x1B[20~',
      LogicalKeyboardKey.f10 => '\x1B[21~',
      LogicalKeyboardKey.f11 => '\x1B[23~',
      LogicalKeyboardKey.f12 => '\x1B[24~',
      _ => null,
    };

    if (sequence == null) {
      return null;
    }
    if (!altPressed) {
      return sequence;
    }
    if (ctrlPressed && key == LogicalKeyboardKey.space) {
      return '\x00';
    }
    return '\x1B$sequence';
  }
}
