// Curated Feather icon catalog (Batch 1 — design §4.3).
//
// Single source of truth for icon names accepted by the `UiIcon` widget
// and `UiAppTile.icon` (when the icon field is a string). Plugins
// reference icons by kebab-case name (Feather's canonical form); we
// translate to `IconData` instances backed by the bundled Feather font.
//
// Curated subset (~155 names) chosen for breadth of common needs:
// navigation, file/folder, code/terminal, status, communication, media,
// security, system. We do not ship the full ~280 — every icon adds glyph
// data to the font, and the typed-widget-tree philosophy favors a small
// vocabulary over a kitchen sink.
//
// Unknown names render a question-mark placeholder (handled by the
// renderer); they do not throw. This is intentional: a typo or a name a
// plugin author thought was in the catalog should degrade visibly but
// gracefully, not crash the panel.

import 'package:flutter/widgets.dart';

/// Const so each catalog entry's IconData stays tree-shake-eligible.
const String _ff = 'FeatherIcons';

/// Resolve a Feather catalog name (kebab-case, e.g. `arrow-left`) to its
/// `IconData`. Returns `null` if the name is not in the curated subset —
/// callers render a placeholder in that case.
IconData? resolveIconByName(String name) => _catalog[name];

/// Read-only view of every known icon name. Exposed so tests can assert
/// coverage without enumerating the map literal.
Iterable<String> knownIconNames() => _catalog.keys;

final Map<String, IconData> _catalog = <String, IconData>{
  // Navigation
  'arrow-left': const IconData(0xe911, fontFamily: _ff),
  'arrow-right': const IconData(0xe913, fontFamily: _ff),
  'arrow-up': const IconData(0xe917, fontFamily: _ff),
  'arrow-down': const IconData(0xe90f, fontFamily: _ff),
  'chevron-left': const IconData(0xe92f, fontFamily: _ff),
  'chevron-right': const IconData(0xe930, fontFamily: _ff),
  'chevron-up': const IconData(0xe931, fontFamily: _ff),
  'chevron-down': const IconData(0xe92e, fontFamily: _ff),
  'menu': const IconData(0xe998, fontFamily: _ff),
  'more-horizontal': const IconData(0xe9a4, fontFamily: _ff),
  'more-vertical': const IconData(0xe9a5, fontFamily: _ff),
  'home': const IconData(0xe980, fontFamily: _ff),
  'compass': const IconData(0xe946, fontFamily: _ff),
  'map': const IconData(0xe994, fontFamily: _ff),
  'corner-down-left': const IconData(0xe948, fontFamily: _ff),
  'corner-down-right': const IconData(0xe949, fontFamily: _ff),
  'external-link': const IconData(0xe95e, fontFamily: _ff),

  // Files & folders
  'file': const IconData(0xe968, fontFamily: _ff),
  'file-text': const IconData(0xe967, fontFamily: _ff),
  'file-plus': const IconData(0xe966, fontFamily: _ff),
  'file-minus': const IconData(0xe965, fontFamily: _ff),
  'folder': const IconData(0xe96e, fontFamily: _ff),
  'folder-plus': const IconData(0xe96d, fontFamily: _ff),
  'folder-minus': const IconData(0xe96c, fontFamily: _ff),
  'archive': const IconData(0xe90b, fontFamily: _ff),
  'inbox': const IconData(0xe982, fontFamily: _ff),
  'paperclip': const IconData(0xe9ad, fontFamily: _ff),
  'save': const IconData(0xe9ca, fontFamily: _ff),
  'download': const IconData(0xe959, fontFamily: _ff),
  'upload': const IconData(0xe9fd, fontFamily: _ff),
  'copy': const IconData(0xe947, fontFamily: _ff),
  'clipboard': const IconData(0xe938, fontFamily: _ff),

  // Code & terminal
  'code': const IconData(0xe940, fontFamily: _ff),
  'terminal': const IconData(0xe9e9, fontFamily: _ff),
  'cpu': const IconData(0xe950, fontFamily: _ff),
  'database': const IconData(0xe954, fontFamily: _ff),
  'server': const IconData(0xe9ce, fontFamily: _ff),
  'package': const IconData(0xe9ac, fontFamily: _ff),
  'box': const IconData(0xe925, fontFamily: _ff),
  'layers': const IconData(0xe987, fontFamily: _ff),
  'grid': const IconData(0xe979, fontFamily: _ff),
  'list': const IconData(0xe98d, fontFamily: _ff),
  'git-branch': const IconData(0xe972, fontFamily: _ff),
  'git-commit': const IconData(0xe973, fontFamily: _ff),
  'git-merge': const IconData(0xe974, fontFamily: _ff),
  'git-pull-request': const IconData(0xe975, fontFamily: _ff),
  'github': const IconData(0xe976, fontFamily: _ff),
  'gitlab': const IconData(0xe977, fontFamily: _ff),
  'hash': const IconData(0xe97b, fontFamily: _ff),

  // Status / signal
  'check': const IconData(0xe92d, fontFamily: _ff),
  'check-circle': const IconData(0xe92b, fontFamily: _ff),
  'check-square': const IconData(0xe92c, fontFamily: _ff),
  'x': const IconData(0xea12, fontFamily: _ff),
  'x-circle': const IconData(0xea0f, fontFamily: _ff),
  'x-square': const IconData(0xea11, fontFamily: _ff),
  'alert-circle': const IconData(0xe902, fontFamily: _ff),
  'alert-triangle': const IconData(0xe904, fontFamily: _ff),
  'alert-octagon': const IconData(0xe903, fontFamily: _ff),
  'info': const IconData(0xe983, fontFamily: _ff),
  'help-circle': const IconData(0xe97e, fontFamily: _ff),
  'circle': const IconData(0xe937, fontFamily: _ff),
  'square': const IconData(0xe9e0, fontFamily: _ff),
  'minus': const IconData(0xe9a1, fontFamily: _ff),
  'minus-circle': const IconData(0xe99f, fontFamily: _ff),
  'minus-square': const IconData(0xe9a0, fontFamily: _ff),
  'plus': const IconData(0xe9be, fontFamily: _ff),
  'plus-circle': const IconData(0xe9bc, fontFamily: _ff),
  'plus-square': const IconData(0xe9bd, fontFamily: _ff),
  'loader': const IconData(0xe98e, fontFamily: _ff),
  'activity': const IconData(0xe900, fontFamily: _ff),
  'zap': const IconData(0xea15, fontFamily: _ff),
  'zap-off': const IconData(0xea14, fontFamily: _ff),

  // Actions
  'edit': const IconData(0xe95d, fontFamily: _ff),
  'edit-2': const IconData(0xe95b, fontFamily: _ff),
  'edit-3': const IconData(0xe95c, fontFamily: _ff),
  'trash': const IconData(0xe9f0, fontFamily: _ff),
  'trash-2': const IconData(0xe9ef, fontFamily: _ff),
  'refresh-cw': const IconData(0xe9c4, fontFamily: _ff),
  'refresh-ccw': const IconData(0xe9c3, fontFamily: _ff),
  'rotate-cw': const IconData(0xe9c8, fontFamily: _ff),
  'rotate-ccw': const IconData(0xe9c7, fontFamily: _ff),
  'play': const IconData(0xe9bb, fontFamily: _ff),
  'pause': const IconData(0xe9af, fontFamily: _ff),
  'square-stop': const IconData(0xe9e0, fontFamily: _ff), // alias for "stop" — Feather has no stop glyph
  'skip-back': const IconData(0xe9d8, fontFamily: _ff),
  'skip-forward': const IconData(0xe9d9, fontFamily: _ff),
  'send': const IconData(0xe9cd, fontFamily: _ff),
  'share': const IconData(0xe9d1, fontFamily: _ff),
  'share-2': const IconData(0xe9d0, fontFamily: _ff),
  'log-in': const IconData(0xe990, fontFamily: _ff),
  'log-out': const IconData(0xe991, fontFamily: _ff),

  // Communication
  'mail': const IconData(0xe992, fontFamily: _ff),
  'message-circle': const IconData(0xe999, fontFamily: _ff),
  'message-square': const IconData(0xe99a, fontFamily: _ff),
  'phone': const IconData(0xe9b8, fontFamily: _ff),
  'bell': const IconData(0xe91f, fontFamily: _ff),
  'bell-off': const IconData(0xe91e, fontFamily: _ff),
  'at-sign': const IconData(0xe918, fontFamily: _ff),
  'rss': const IconData(0xe9c9, fontFamily: _ff),

  // Settings / config
  'settings': const IconData(0xe9cf, fontFamily: _ff),
  'sliders': const IconData(0xe9dc, fontFamily: _ff),
  // Feather has no dedicated `tool` glyph; alias to the sliders glyph
  // which the broader catalog uses as the canonical "settings/tool" mark.
  'tool': const IconData(0xe9dc, fontFamily: _ff),
  'filter': const IconData(0xe96a, fontFamily: _ff),
  'toggle-left': const IconData(0xe9ed, fontFamily: _ff),
  'toggle-right': const IconData(0xe9ee, fontFamily: _ff),

  // User / identity
  'user': const IconData(0xea02, fontFamily: _ff),
  'users': const IconData(0xea03, fontFamily: _ff),
  'user-plus': const IconData(0xea00, fontFamily: _ff),
  'user-minus': const IconData(0xe9ff, fontFamily: _ff),
  'user-check': const IconData(0xe9fe, fontFamily: _ff),
  'user-x': const IconData(0xea01, fontFamily: _ff),

  // Search / view
  'search': const IconData(0xe9cc, fontFamily: _ff),
  'eye': const IconData(0xe960, fontFamily: _ff),
  'eye-off': const IconData(0xe95f, fontFamily: _ff),
  'zoom-in': const IconData(0xea16, fontFamily: _ff),
  'zoom-out': const IconData(0xea17, fontFamily: _ff),

  // Security
  'lock': const IconData(0xe98f, fontFamily: _ff),
  'unlock': const IconData(0xe9fb, fontFamily: _ff),
  'shield': const IconData(0xe9d3, fontFamily: _ff),
  'shield-off': const IconData(0xe9d2, fontFamily: _ff),
  'key': const IconData(0xe986, fontFamily: _ff),

  // Time
  'clock': const IconData(0xe939, fontFamily: _ff),
  'calendar': const IconData(0xe927, fontFamily: _ff),
  'watch': const IconData(0xea0b, fontFamily: _ff),

  // Network
  'wifi': const IconData(0xea0d, fontFamily: _ff),
  'wifi-off': const IconData(0xea0c, fontFamily: _ff),
  'globe': const IconData(0xe978, fontFamily: _ff),
  'link': const IconData(0xe98b, fontFamily: _ff),
  'link-2': const IconData(0xe98a, fontFamily: _ff),
  'cloud': const IconData(0xe93f, fontFamily: _ff),
  'cloud-off': const IconData(0xe93c, fontFamily: _ff),
  'cloud-download': const IconData(0xe93a, fontFamily: _ff), // closest match
  'cloud-upload': const IconData(0xe93d, fontFamily: _ff), // closest match

  // Bookmark / tag
  'bookmark': const IconData(0xe924, fontFamily: _ff),
  'star': const IconData(0xe9e1, fontFamily: _ff),
  'heart': const IconData(0xe97d, fontFamily: _ff),
  'flag': const IconData(0xe96b, fontFamily: _ff),
  'tag': const IconData(0xe9e7, fontFamily: _ff),
  'award': const IconData(0xe919, fontFamily: _ff),

  // Misc
  'sun': const IconData(0xe9e3, fontFamily: _ff),
  'moon': const IconData(0xe9a3, fontFamily: _ff),
  'image': const IconData(0xe981, fontFamily: _ff),
  'camera': const IconData(0xe929, fontFamily: _ff),
  'mic': const IconData(0xe99c, fontFamily: _ff),
  'mic-off': const IconData(0xe99b, fontFamily: _ff),
  'volume': const IconData(0xea0a, fontFamily: _ff),
  'volume-1': const IconData(0xea07, fontFamily: _ff),
  'volume-2': const IconData(0xea08, fontFamily: _ff),
  'volume-x': const IconData(0xea09, fontFamily: _ff),
  'thumbs-up': const IconData(0xe9ec, fontFamily: _ff),
  'thumbs-down': const IconData(0xe9eb, fontFamily: _ff),
  'power': const IconData(0xe9c0, fontFamily: _ff),
  'monitor': const IconData(0xe9a2, fontFamily: _ff),
  'smartphone': const IconData(0xe9dd, fontFamily: _ff),
  'tablet': const IconData(0xe9e6, fontFamily: _ff),
};
