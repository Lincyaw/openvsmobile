// Publish-token admin state (design section 4.5).
//
// These tokens let agents, CI, and monitoring post notifications without
// sharing the backend auth token. The screen is just a projection of this
// model; BackendClient stays behind AppState per docs/conventions.md section 2.

import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../backend_client.dart';
import '../models.dart';

class PublishTokensModel extends ChangeNotifier {
  final BackendClient _client;
  final void Function(String message) _reportError;

  final List<PublishTokenRecord> _items = [];
  bool _loading = false;
  bool _loaded = false;
  String? _error;

  PublishTokensModel({
    required BackendClient client,
    required void Function(String message) reportError,
  }) : this._(client, reportError);

  PublishTokensModel._(this._client, this._reportError);

  UnmodifiableListView<PublishTokenRecord> get items =>
      UnmodifiableListView(_items);
  bool get loading => _loading;
  bool get loaded => _loaded;
  String? get error => _error;

  Future<void> refresh({bool includeRevoked = false}) async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final params = <String, dynamic>{};
      if (includeRevoked) params['includeRevoked'] = true;
      final result =
          await _client.call('auth.publishTokens.list', params)
              as Map<String, dynamic>;
      final raw = (result['items'] as List?) ?? const [];
      _items
        ..clear()
        ..addAll(
          raw.cast<Map<String, dynamic>>().map(PublishTokenRecord.fromJson),
        );
      _loaded = true;
      _loading = false;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      _loading = false;
      notifyListeners();
    }
  }

  Future<CreatedPublishToken> create({
    required String label,
    String? sourcePrefix,
    required int rateLimitPerMin,
    required int rateLimitPerHour,
  }) async {
    final params = <String, dynamic>{
      'label': label,
      'rateLimitPerMin': rateLimitPerMin,
      'rateLimitPerHour': rateLimitPerHour,
    };
    final cleanPrefix = sourcePrefix?.trim();
    if (cleanPrefix != null && cleanPrefix.isNotEmpty) {
      params['sourcePrefix'] = cleanPrefix;
    }
    try {
      final result =
          await _client.call('auth.publishTokens.create', params)
              as Map<String, dynamic>;
      final rawRecord = result['record'];
      if (rawRecord is! Map<String, dynamic>) {
        throw StateError('publish token create returned no record');
      }
      final secret = result['secret'];
      if (secret is! String || secret.isEmpty) {
        throw StateError('publish token create returned no secret');
      }
      final record = PublishTokenRecord.fromJson(rawRecord);
      _replace(record);
      _loaded = true;
      notifyListeners();
      return CreatedPublishToken(record: record, secret: secret);
    } catch (e) {
      _reportError('Could not mint webhook token: $e');
      rethrow;
    }
  }

  Future<void> revoke(String id) async {
    try {
      await _client.call('auth.publishTokens.revoke', {'id': id});
      _items.removeWhere((item) => item.id == id);
      notifyListeners();
    } catch (e) {
      _reportError('Could not revoke webhook token: $e');
      rethrow;
    }
  }

  Future<void> relabel(String id, String label) async {
    try {
      await _client.call('auth.publishTokens.relabel', {
        'id': id,
        'label': label,
      });
      for (var i = 0; i < _items.length; i++) {
        if (_items[i].id == id) {
          _items[i] = _items[i].copyWith(label: label);
          break;
        }
      }
      notifyListeners();
    } catch (e) {
      _reportError('Could not rename webhook token: $e');
      rethrow;
    }
  }

  void _replace(PublishTokenRecord record) {
    for (var i = 0; i < _items.length; i++) {
      if (_items[i].id == record.id) {
        _items[i] = record;
        return;
      }
    }
    _items.add(record);
  }

  void resetLocal() {
    _items.clear();
    _loading = false;
    _loaded = false;
    _error = null;
    notifyListeners();
  }
}
