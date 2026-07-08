// Plugin surface (design §3) — client mirror.
//
// Owns the list of installed plugins as the backend reports them and keeps
// it live against `plugin.stateChanged` pushes (CLAUDE.md first principle
// #1: backend is the source of truth). Composed under AppState; AppState
// forwards `notifyListeners` so widgets only need to listen to AppState to
// see plugin-list changes.
//
// Toggling a plugin is a thin call into `plugin.enable` / `plugin.disable`.
// We do NOT optimistically flip local state — the wire-state push from the
// backend is the only source that mutates `_byId`. That keeps the model
// honest in two-client and reconnect scenarios.

import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../backend_client.dart';

/// Wire-state vocabulary mirrored from `next/backend/src/plugins/host.ts`.
/// Anything the backend sends that doesn't match these falls back to
/// `unknown` so a forward-compatible newer backend can't crash older
/// clients.
enum PluginWireState { running, stopped, crashed, disabled, unknown }

PluginWireState pluginWireStateFromString(String? raw) {
  switch (raw) {
    case 'running':
      return PluginWireState.running;
    case 'stopped':
      return PluginWireState.stopped;
    case 'crashed':
      return PluginWireState.crashed;
    case 'disabled':
      return PluginWireState.disabled;
    default:
      return PluginWireState.unknown;
  }
}

@immutable
class PluginCommandStub {
  final String id;
  final String title;
  const PluginCommandStub({required this.id, required this.title});
}

@immutable
class PluginLogTail {
  final String id;
  final String path;
  final String text;
  final int bytes;
  final bool truncated;

  const PluginLogTail({
    required this.id,
    required this.path,
    required this.text,
    required this.bytes,
    required this.truncated,
  });

  factory PluginLogTail.fromJson(Map<String, dynamic> json) => PluginLogTail(
    id: json['id'] as String? ?? '',
    path: json['path'] as String? ?? '',
    text: json['text'] as String? ?? '',
    bytes: (json['bytes'] as num?)?.toInt() ?? 0,
    truncated: json['truncated'] == true,
  );
}

/// Mirror of the backend's `PluginInfo` shape returned by `plugin.list`.
/// `contributes` lists the panels we should render; we read them out of
/// the `contributes.panels` key when present, otherwise treat the plugin
/// as having no panel. C4 surface — the keys come from the manifest's
/// `contributes` map; v0 looks for `panels: [{ id, title }]` and falls
/// back to "no panels".
@immutable
class PluginInfo {
  final String id;
  final String name;
  final String version;
  final PluginWireState state;
  final String? crashReason;
  final List<PluginPanelStub> panels;
  final List<PluginCommandStub> commands;

  /// Capability flags as the backend projects them out of `plugin.json`'s
  /// `capabilities` block. The shape is intentionally loose (a string-keyed
  /// map) so a forward-compatible newer backend can add new keys without
  /// breaking older clients; the detail screen reads known keys
  /// (`fs`/`terminal`/`network`/`secrets`/`ui`) and ignores the rest.
  final Map<String, dynamic> capabilities;

  /// Plugin-level brand color (Batch 1 — design §4.3). One of seven named
  /// hues (teal/blue/green/orange/red/purple/mono). Resolved via
  /// `resolvePluginThemeColor` in `app_tokens.dart`. The Plugins tab
  /// scopes a Theme override around the plugin's panels so the `brand`
  /// AccentToken resolves to this color inside the panel only.
  final String? themeColor;

  const PluginInfo({
    required this.id,
    required this.name,
    required this.version,
    required this.state,
    required this.crashReason,
    required this.panels,
    required this.commands,
    this.capabilities = const <String, dynamic>{},
    this.themeColor,
  });

  factory PluginInfo.fromJson(Map<String, dynamic> json) {
    final contributes = json['contributes'];
    final panels = <PluginPanelStub>[];
    final commands = <PluginCommandStub>[];
    if (contributes is Map<String, dynamic>) {
      final rawPanels = contributes['panels'];
      if (rawPanels is List) {
        for (final raw in rawPanels) {
          if (raw is! Map<String, dynamic>) continue;
          final pid = raw['id'];
          final title = raw['title'];
          if (pid is! String || pid.isEmpty) continue;
          panels.add(
            PluginPanelStub(
              id: pid,
              title: title is String && title.isNotEmpty ? title : pid,
            ),
          );
        }
      }
      final rawCommands = contributes['commands'];
      if (rawCommands is List) {
        for (final raw in rawCommands) {
          if (raw is! Map<String, dynamic>) continue;
          final cid = raw['id'];
          final ctitle = raw['title'];
          if (cid is! String || cid.isEmpty) continue;
          commands.add(
            PluginCommandStub(
              id: cid,
              title: ctitle is String && ctitle.isNotEmpty ? ctitle : cid,
            ),
          );
        }
      }
    }
    final rawCaps = json['capabilities'];
    final caps = <String, dynamic>{};
    if (rawCaps is Map) {
      for (final entry in rawCaps.entries) {
        final k = entry.key;
        if (k is String) caps[k] = entry.value;
      }
    }
    return PluginInfo(
      id: (json['id'] as String?) ?? '',
      name: (json['name'] as String?) ?? ((json['id'] as String?) ?? ''),
      version: (json['version'] as String?) ?? '',
      state: pluginWireStateFromString(json['state'] as String?),
      crashReason: json['crashReason'] as String?,
      panels: panels,
      commands: commands,
      capabilities: caps,
      themeColor: json['themeColor'] as String?,
    );
  }

  PluginInfo copyWith({
    PluginWireState? state,
    String? crashReason,
    bool clearCrashReason = false,
  }) {
    return PluginInfo(
      id: id,
      name: name,
      version: version,
      state: state ?? this.state,
      crashReason: clearCrashReason ? null : (crashReason ?? this.crashReason),
      panels: panels,
      commands: commands,
      capabilities: capabilities,
      themeColor: themeColor,
    );
  }
}

@immutable
class PluginPanelStub {
  final String id;
  final String title;
  const PluginPanelStub({required this.id, required this.title});
}

class PluginsModel extends ChangeNotifier {
  final BackendClient _client;
  final void Function(String message)? _reportError;

  /// id → info. Insertion order from the most recent `plugin.list` is
  /// preserved by `LinkedHashMap`; widgets read [plugins] which projects
  /// that order.
  final LinkedHashMap<String, PluginInfo> _byId = LinkedHashMap();
  bool _subscribed = false;
  bool _loaded = false;

  /// Test seam: when set, every wire call routes here instead of the
  /// real backend client. Widget tests use this to record + assert call
  /// order without a live socket. Production code leaves it `null`.
  @visibleForTesting
  Future<Map<String, dynamic>?> Function(
    String method,
    Map<String, dynamic>? params,
  )?
  debugRpcOverride;

  PluginsModel({
    required BackendClient client,
    void Function(String message)? reportError,
  }) : this._(client, reportError);

  PluginsModel._(this._client, this._reportError);

  Future<dynamic> _call(String method, [Map<String, dynamic>? params]) {
    final ovr = debugRpcOverride;
    if (ovr != null) return ovr(method, params);
    return _client.call(method, params);
  }

  /// Read-only list of installed plugins, in the order the backend
  /// returned them. Re-projected on every getter call — the list is tiny
  /// (< 10) and the cost is negligible.
  List<PluginInfo> get plugins => List.unmodifiable(_byId.values);

  PluginInfo? plugin(String id) => _byId[id];

  bool get isSubscribed => _subscribed;
  bool get isLoaded => _loaded;

  /// Hard reset for an intentional backend target switch. Reconnect keeps
  /// the last-known list visible and only re-subscribes to pushes.
  void resetLocal() {
    _byId.clear();
    _subscribed = false;
    _loaded = false;
    notifyListeners();
  }

  /// Subscribe to push updates only. Used on reconnect so we keep the
  /// last-known plugin list visible (first principle #4) instead of
  /// briefly wiping it through a full `plugin.list` refresh. The backend
  /// pushes `plugin.stateChanged` for any state transitions we missed.
  Future<void> subscribe() async {
    try {
      await _call('plugin.subscribe');
      _subscribed = true;
      notifyListeners();
    } catch (e) {
      debugPrint('plugin.subscribe failed: $e');
    }
  }

  /// Pull the current list AND subscribe to push updates. Used by code
  /// paths that genuinely need an initial snapshot (e.g. cold start with
  /// no cached data). Reconnect uses [subscribe] alone.
  Future<void> subscribeAndRefresh() async {
    await subscribe();
    await refresh();
  }

  Future<void> refresh() async {
    try {
      final res = await _call('plugin.list');
      if (res is! Map<String, dynamic>) return;
      final raw = res['plugins'];
      if (raw is! List) return;
      _byId.clear();
      for (final entry in raw) {
        if (entry is! Map<String, dynamic>) continue;
        final info = PluginInfo.fromJson(entry);
        if (info.id.isEmpty) continue;
        _byId[info.id] = info;
      }
      _loaded = true;
      notifyListeners();
    } catch (e) {
      debugPrint('plugin.list failed: $e');
    }
  }

  /// Test seam: load a fixture list directly without touching the wire.
  /// Used by widget tests to exercise the screens against a known mix
  /// of states.
  @visibleForTesting
  void debugSeed(List<PluginInfo> seed) {
    _byId.clear();
    for (final p in seed) {
      _byId[p.id] = p;
    }
    _loaded = true;
    notifyListeners();
  }

  /// Test seam: feed a `plugin.stateChanged` push directly. Production
  /// reaches this method through `AppState._onNotification`.
  @visibleForTesting
  void debugApplyStateChange(Map<String, dynamic> params) {
    _applyStateChange(params);
  }

  /// Apply a `plugin.stateChanged` push to local state. Returns true if
  /// it mutated `_byId`, false if the event was for an unknown plugin
  /// (which can happen briefly after install before we've refreshed).
  bool onStateChanged(Map<String, dynamic> params) {
    return _applyStateChange(params);
  }

  bool _applyStateChange(Map<String, dynamic> params) {
    final id = params['id'];
    final stateStr = params['state'];
    if (id is! String || stateStr is! String) return false;
    final existing = _byId[id];
    if (existing == null) {
      // Backend reported state for a plugin we don't have in our list
      // yet. Trigger a refresh so the row appears with its full
      // metadata; the next push for the same id will then mutate the
      // entry in place. Skip the optimistic insert — without the
      // manifest fields we can't render a usable row anyway.
      unawaited(refresh());
      return false;
    }
    final next = existing.copyWith(
      state: pluginWireStateFromString(stateStr),
      crashReason: params['crashReason'] as String?,
      clearCrashReason: params['crashReason'] == null,
    );
    _byId[id] = next;
    notifyListeners();
    return true;
  }

  /// Enable a plugin. Backend pushes `plugin.stateChanged` on success;
  /// we don't optimistically flip local state. Returns the future from
  /// the RPC so callers can show inline progress.
  Future<void> enable(String pluginId) async {
    await _call('plugin.enable', <String, dynamic>{'id': pluginId});
  }

  /// Disable a plugin. Same fire-and-await pattern as [enable].
  Future<void> disable(String pluginId) async {
    await _call('plugin.disable', <String, dynamic>{'id': pluginId});
  }

  Future<dynamic> invokeCommand(
    String pluginId,
    String commandId, {
    Object? args,
  }) {
    final params = <String, dynamic>{'id': pluginId, 'commandId': commandId};
    if (args != null) params['args'] = args;
    return _call('plugin.invokeCommand', params);
  }

  Future<PluginLogTail> fetchLog(
    String pluginId, {
    int maxBytes = 32 * 1024,
  }) async {
    final result =
        await _call('plugin.log', <String, dynamic>{
              'id': pluginId,
              'maxBytes': maxBytes,
            })
            as Map<String, dynamic>;
    return PluginLogTail.fromJson(result);
  }

  /// Reload a crashed plugin: disable then enable. The interleaving of
  /// state pushes is fine — the model only mutates on the wire state,
  /// and the final `running` push after `enable` wins.
  ///
  /// If `enable` fails after `disable` succeeded the plugin is left in a
  /// disabled state; surface that via [_reportError] so the user has a
  /// chance to retry instead of silently observing a stuck row.
  Future<void> reload(String pluginId) async {
    await disable(pluginId);
    try {
      await enable(pluginId);
    } catch (e) {
      _reportError?.call('Could not re-enable $pluginId: $e');
      rethrow;
    }
  }
}
