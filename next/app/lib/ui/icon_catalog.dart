// Curated Feather icon catalog (Batch 1 — design §4.3).
//
// Single source of truth for icon names accepted by the `UiIcon` widget
// and `UiAppTile.icon` (when the icon field is a string). Plugins
// reference icons by kebab-case name (Feather's canonical form); we
// translate to `flutter_feather_icons`' camelCase constants.
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
import 'package:flutter_feather_icons/flutter_feather_icons.dart';

/// Resolve a Feather catalog name (kebab-case, e.g. `arrow-left`) to its
/// `IconData`. Returns `null` if the name is not in the curated subset —
/// callers render a placeholder in that case.
IconData? resolveIconByName(String name) => _catalog[name];

/// Read-only view of every known icon name. Exposed so tests can assert
/// coverage without enumerating the map literal.
Iterable<String> knownIconNames() => _catalog.keys;

final Map<String, IconData> _catalog = <String, IconData>{
  // Navigation
  'arrow-left': FeatherIcons.arrowLeft,
  'arrow-right': FeatherIcons.arrowRight,
  'arrow-up': FeatherIcons.arrowUp,
  'arrow-down': FeatherIcons.arrowDown,
  'chevron-left': FeatherIcons.chevronLeft,
  'chevron-right': FeatherIcons.chevronRight,
  'chevron-up': FeatherIcons.chevronUp,
  'chevron-down': FeatherIcons.chevronDown,
  'menu': FeatherIcons.menu,
  'more-horizontal': FeatherIcons.moreHorizontal,
  'more-vertical': FeatherIcons.moreVertical,
  'home': FeatherIcons.home,
  'compass': FeatherIcons.compass,
  'map': FeatherIcons.map,
  'corner-down-left': FeatherIcons.cornerDownLeft,
  'corner-down-right': FeatherIcons.cornerDownRight,
  'external-link': FeatherIcons.externalLink,

  // Files & folders
  'file': FeatherIcons.file,
  'file-text': FeatherIcons.fileText,
  'file-plus': FeatherIcons.filePlus,
  'file-minus': FeatherIcons.fileMinus,
  'folder': FeatherIcons.folder,
  'folder-plus': FeatherIcons.folderPlus,
  'folder-minus': FeatherIcons.folderMinus,
  'archive': FeatherIcons.archive,
  'inbox': FeatherIcons.inbox,
  'paperclip': FeatherIcons.paperclip,
  'save': FeatherIcons.save,
  'download': FeatherIcons.download,
  'upload': FeatherIcons.upload,
  'copy': FeatherIcons.copy,
  'clipboard': FeatherIcons.clipboard,

  // Code & terminal
  'code': FeatherIcons.code,
  'terminal': FeatherIcons.terminal,
  'cpu': FeatherIcons.cpu,
  'database': FeatherIcons.database,
  'server': FeatherIcons.server,
  'package': FeatherIcons.package,
  'box': FeatherIcons.box,
  'layers': FeatherIcons.layers,
  'grid': FeatherIcons.grid,
  'list': FeatherIcons.list,
  'git-branch': FeatherIcons.gitBranch,
  'git-commit': FeatherIcons.gitCommit,
  'git-merge': FeatherIcons.gitMerge,
  'git-pull-request': FeatherIcons.gitPullRequest,
  'github': FeatherIcons.github,
  'gitlab': FeatherIcons.gitlab,
  'hash': FeatherIcons.hash,

  // Status / signal
  'check': FeatherIcons.check,
  'check-circle': FeatherIcons.checkCircle,
  'check-square': FeatherIcons.checkSquare,
  'x': FeatherIcons.x,
  'x-circle': FeatherIcons.xCircle,
  'x-square': FeatherIcons.xSquare,
  'alert-circle': FeatherIcons.alertCircle,
  'alert-triangle': FeatherIcons.alertTriangle,
  'alert-octagon': FeatherIcons.alertOctagon,
  'info': FeatherIcons.info,
  'help-circle': FeatherIcons.helpCircle,
  'circle': FeatherIcons.circle,
  'square': FeatherIcons.square,
  'minus': FeatherIcons.minus,
  'minus-circle': FeatherIcons.minusCircle,
  'minus-square': FeatherIcons.minusSquare,
  'plus': FeatherIcons.plus,
  'plus-circle': FeatherIcons.plusCircle,
  'plus-square': FeatherIcons.plusSquare,
  'loader': FeatherIcons.loader,
  'activity': FeatherIcons.activity,
  'zap': FeatherIcons.zap,
  'zap-off': FeatherIcons.zapOff,

  // Actions
  'edit': FeatherIcons.edit,
  'edit-2': FeatherIcons.edit2,
  'edit-3': FeatherIcons.edit3,
  'trash': FeatherIcons.trash,
  'trash-2': FeatherIcons.trash2,
  'refresh-cw': FeatherIcons.refreshCw,
  'refresh-ccw': FeatherIcons.refreshCcw,
  'rotate-cw': FeatherIcons.rotateCw,
  'rotate-ccw': FeatherIcons.rotateCcw,
  'play': FeatherIcons.play,
  'pause': FeatherIcons.pause,
  'square-stop': FeatherIcons.square, // alias for "stop" — Feather has no stop glyph
  'skip-back': FeatherIcons.skipBack,
  'skip-forward': FeatherIcons.skipForward,
  'send': FeatherIcons.send,
  'share': FeatherIcons.share,
  'share-2': FeatherIcons.share2,
  'log-in': FeatherIcons.logIn,
  'log-out': FeatherIcons.logOut,

  // Communication
  'mail': FeatherIcons.mail,
  'message-circle': FeatherIcons.messageCircle,
  'message-square': FeatherIcons.messageSquare,
  'phone': FeatherIcons.phone,
  'bell': FeatherIcons.bell,
  'bell-off': FeatherIcons.bellOff,
  'at-sign': FeatherIcons.atSign,
  'rss': FeatherIcons.rss,

  // Settings / config
  'settings': FeatherIcons.settings,
  'sliders': FeatherIcons.sliders,
  // Feather has no dedicated `tool` glyph; alias to the sliders glyph
  // which the broader catalog uses as the canonical "settings/tool" mark.
  'tool': FeatherIcons.sliders,
  'filter': FeatherIcons.filter,
  'toggle-left': FeatherIcons.toggleLeft,
  'toggle-right': FeatherIcons.toggleRight,

  // User / identity
  'user': FeatherIcons.user,
  'users': FeatherIcons.users,
  'user-plus': FeatherIcons.userPlus,
  'user-minus': FeatherIcons.userMinus,
  'user-check': FeatherIcons.userCheck,
  'user-x': FeatherIcons.userX,

  // Search / view
  'search': FeatherIcons.search,
  'eye': FeatherIcons.eye,
  'eye-off': FeatherIcons.eyeOff,
  'zoom-in': FeatherIcons.zoomIn,
  'zoom-out': FeatherIcons.zoomOut,

  // Security
  'lock': FeatherIcons.lock,
  'unlock': FeatherIcons.unlock,
  'shield': FeatherIcons.shield,
  'shield-off': FeatherIcons.shieldOff,
  'key': FeatherIcons.key,

  // Time
  'clock': FeatherIcons.clock,
  'calendar': FeatherIcons.calendar,
  'watch': FeatherIcons.watch,

  // Network
  'wifi': FeatherIcons.wifi,
  'wifi-off': FeatherIcons.wifiOff,
  'globe': FeatherIcons.globe,
  'link': FeatherIcons.link,
  'link-2': FeatherIcons.link2,
  'cloud': FeatherIcons.cloud,
  'cloud-off': FeatherIcons.cloudOff,
  'cloud-download': FeatherIcons.cloudDrizzle, // closest match
  'cloud-upload': FeatherIcons.cloudRain, // closest match

  // Bookmark / tag
  'bookmark': FeatherIcons.bookmark,
  'star': FeatherIcons.star,
  'heart': FeatherIcons.heart,
  'flag': FeatherIcons.flag,
  'tag': FeatherIcons.tag,
  'award': FeatherIcons.award,

  // Misc
  'sun': FeatherIcons.sun,
  'moon': FeatherIcons.moon,
  'image': FeatherIcons.image,
  'camera': FeatherIcons.camera,
  'mic': FeatherIcons.mic,
  'mic-off': FeatherIcons.micOff,
  'volume': FeatherIcons.volume,
  'volume-1': FeatherIcons.volume1,
  'volume-2': FeatherIcons.volume2,
  'volume-x': FeatherIcons.volumeX,
  'thumbs-up': FeatherIcons.thumbsUp,
  'thumbs-down': FeatherIcons.thumbsDown,
  'power': FeatherIcons.power,
  'monitor': FeatherIcons.monitor,
  'smartphone': FeatherIcons.smartphone,
  'tablet': FeatherIcons.tablet,
};
