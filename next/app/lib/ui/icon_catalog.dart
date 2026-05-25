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

IconData _f(int codePoint) => IconData(codePoint, fontFamily: 'FeatherIcons');

/// Resolve a Feather catalog name (kebab-case, e.g. `arrow-left`) to its
/// `IconData`. Returns `null` if the name is not in the curated subset —
/// callers render a placeholder in that case.
IconData? resolveIconByName(String name) => _catalog[name];

/// Read-only view of every known icon name. Exposed so tests can assert
/// coverage without enumerating the map literal.
Iterable<String> knownIconNames() => _catalog.keys;

final Map<String, IconData> _catalog = <String, IconData>{
  // Navigation
  'arrow-left': _f(0xe911),
  'arrow-right': _f(0xe913),
  'arrow-up': _f(0xe917),
  'arrow-down': _f(0xe90f),
  'chevron-left': _f(0xe92f),
  'chevron-right': _f(0xe930),
  'chevron-up': _f(0xe931),
  'chevron-down': _f(0xe92e),
  'menu': _f(0xe998),
  'more-horizontal': _f(0xe9a4),
  'more-vertical': _f(0xe9a5),
  'home': _f(0xe980),
  'compass': _f(0xe946),
  'map': _f(0xe994),
  'corner-down-left': _f(0xe948),
  'corner-down-right': _f(0xe949),
  'external-link': _f(0xe95e),

  // Files & folders
  'file': _f(0xe968),
  'file-text': _f(0xe967),
  'file-plus': _f(0xe966),
  'file-minus': _f(0xe965),
  'folder': _f(0xe96e),
  'folder-plus': _f(0xe96d),
  'folder-minus': _f(0xe96c),
  'archive': _f(0xe90b),
  'inbox': _f(0xe982),
  'paperclip': _f(0xe9ad),
  'save': _f(0xe9ca),
  'download': _f(0xe959),
  'upload': _f(0xe9fd),
  'copy': _f(0xe947),
  'clipboard': _f(0xe938),

  // Code & terminal
  'code': _f(0xe940),
  'terminal': _f(0xe9e9),
  'cpu': _f(0xe950),
  'database': _f(0xe954),
  'server': _f(0xe9ce),
  'package': _f(0xe9ac),
  'box': _f(0xe925),
  'layers': _f(0xe987),
  'grid': _f(0xe979),
  'list': _f(0xe98d),
  'git-branch': _f(0xe972),
  'git-commit': _f(0xe973),
  'git-merge': _f(0xe974),
  'git-pull-request': _f(0xe975),
  'github': _f(0xe976),
  'gitlab': _f(0xe977),
  'hash': _f(0xe97b),

  // Status / signal
  'check': _f(0xe92d),
  'check-circle': _f(0xe92b),
  'check-square': _f(0xe92c),
  'x': _f(0xea12),
  'x-circle': _f(0xea0f),
  'x-square': _f(0xea11),
  'alert-circle': _f(0xe902),
  'alert-triangle': _f(0xe904),
  'alert-octagon': _f(0xe903),
  'info': _f(0xe983),
  'help-circle': _f(0xe97e),
  'circle': _f(0xe937),
  'square': _f(0xe9e0),
  'minus': _f(0xe9a1),
  'minus-circle': _f(0xe99f),
  'minus-square': _f(0xe9a0),
  'plus': _f(0xe9be),
  'plus-circle': _f(0xe9bc),
  'plus-square': _f(0xe9bd),
  'loader': _f(0xe98e),
  'activity': _f(0xe900),
  'zap': _f(0xea15),
  'zap-off': _f(0xea14),

  // Actions
  'edit': _f(0xe95d),
  'edit-2': _f(0xe95b),
  'edit-3': _f(0xe95c),
  'trash': _f(0xe9f0),
  'trash-2': _f(0xe9ef),
  'refresh-cw': _f(0xe9c4),
  'refresh-ccw': _f(0xe9c3),
  'rotate-cw': _f(0xe9c8),
  'rotate-ccw': _f(0xe9c7),
  'play': _f(0xe9bb),
  'pause': _f(0xe9af),
  'square-stop': _f(0xe9e0), // alias for "stop" — Feather has no stop glyph
  'skip-back': _f(0xe9d8),
  'skip-forward': _f(0xe9d9),
  'send': _f(0xe9cd),
  'share': _f(0xe9d1),
  'share-2': _f(0xe9d0),
  'log-in': _f(0xe990),
  'log-out': _f(0xe991),

  // Communication
  'mail': _f(0xe992),
  'message-circle': _f(0xe999),
  'message-square': _f(0xe99a),
  'phone': _f(0xe9b8),
  'bell': _f(0xe91f),
  'bell-off': _f(0xe91e),
  'at-sign': _f(0xe918),
  'rss': _f(0xe9c9),

  // Settings / config
  'settings': _f(0xe9cf),
  'sliders': _f(0xe9dc),
  // Feather has no dedicated `tool` glyph; alias to the sliders glyph
  // which the broader catalog uses as the canonical "settings/tool" mark.
  'tool': _f(0xe9dc),
  'filter': _f(0xe96a),
  'toggle-left': _f(0xe9ed),
  'toggle-right': _f(0xe9ee),

  // User / identity
  'user': _f(0xea02),
  'users': _f(0xea03),
  'user-plus': _f(0xea00),
  'user-minus': _f(0xe9ff),
  'user-check': _f(0xe9fe),
  'user-x': _f(0xea01),

  // Search / view
  'search': _f(0xe9cc),
  'eye': _f(0xe960),
  'eye-off': _f(0xe95f),
  'zoom-in': _f(0xea16),
  'zoom-out': _f(0xea17),

  // Security
  'lock': _f(0xe98f),
  'unlock': _f(0xe9fb),
  'shield': _f(0xe9d3),
  'shield-off': _f(0xe9d2),
  'key': _f(0xe986),

  // Time
  'clock': _f(0xe939),
  'calendar': _f(0xe927),
  'watch': _f(0xea0b),

  // Network
  'wifi': _f(0xea0d),
  'wifi-off': _f(0xea0c),
  'globe': _f(0xe978),
  'link': _f(0xe98b),
  'link-2': _f(0xe98a),
  'cloud': _f(0xe93f),
  'cloud-off': _f(0xe93c),
  'cloud-download': _f(0xe93a), // closest match
  'cloud-upload': _f(0xe93d), // closest match

  // Bookmark / tag
  'bookmark': _f(0xe924),
  'star': _f(0xe9e1),
  'heart': _f(0xe97d),
  'flag': _f(0xe96b),
  'tag': _f(0xe9e7),
  'award': _f(0xe919),

  // Misc
  'sun': _f(0xe9e3),
  'moon': _f(0xe9a3),
  'image': _f(0xe981),
  'camera': _f(0xe929),
  'mic': _f(0xe99c),
  'mic-off': _f(0xe99b),
  'volume': _f(0xea0a),
  'volume-1': _f(0xea07),
  'volume-2': _f(0xea08),
  'volume-x': _f(0xea09),
  'thumbs-up': _f(0xe9ec),
  'thumbs-down': _f(0xe9eb),
  'power': _f(0xe9c0),
  'monitor': _f(0xe9a2),
  'smartphone': _f(0xe9dd),
  'tablet': _f(0xe9e6),
};
