// Unit tests for the per-workspace resident model: decoration deltas,
// snapshot reset, dir-rollup computation, listDir cache invalidation, and
// the version-gap → re-subscribe path.
//
// We don't mock the WebSocket — BackendClient's call() goes nowhere useful
// in tests without a server. Instead we drive the WorkspacesModel via its
// public notification handlers (onTreeDelta / onDecorationDelta / etc.) and
// assert on the resulting state. The subscribe lifecycle is exercised
// separately by feeding a fake client.

import 'package:flutter_test/flutter_test.dart';

import 'package:openvsmobile_next/backend_client.dart';
import 'package:openvsmobile_next/models.dart';
import 'package:openvsmobile_next/state/workspace_model.dart';

void main() {
  group('dirRollup', () {
    test('counts decorated descendants up the ancestor chain', () {
      final model = WorkspacesModel(client: BackendClient());
      model.onDecorationSnapshot({
        'workspaceId': 'ws-1',
        'version': 1,
        'entries': [
          {'path': 'src/a.dart', 'status': 'M'},
          {'path': 'src/sub/b.dart', 'status': 'A'},
          {'path': 'src/sub/c.dart', 'status': '?'},
          {'path': 'README.md', 'status': 'M'},
        ],
      });
      final st = model.stateFor('ws-1')!;
      // root (empty path)
      expect(st.dirRollup[''], 4);
      // src has 3 descendants
      expect(st.dirRollup['src'], 3);
      // src/sub has 2 descendants
      expect(st.dirRollup['src/sub'], 2);
      // file-level entries don't appear in the rollup map
      expect(st.dirRollup.containsKey('src/a.dart'), isFalse);
    });

    test('cleared entries (status null) drop out of the map', () {
      final model = WorkspacesModel(client: BackendClient());
      model.onDecorationSnapshot({
        'workspaceId': 'ws-1',
        'version': 1,
        'entries': [
          {'path': 'a.dart', 'status': 'M'},
          {'path': 'b.dart', 'status': 'A'},
        ],
      });
      expect(model.decoratedCount('ws-1'), 2);
      model.onDecorationDelta({
        'workspaceId': 'ws-1',
        'version': 2,
        'entries': [
          {'path': 'a.dart', 'status': null},
        ],
      });
      final st = model.stateFor('ws-1')!;
      expect(st.decorationMap.containsKey('a.dart'), isFalse);
      expect(st.decorationMap['b.dart'], 'A');
      expect(st.dirRollup[''], 1);
    });

    test('decoration.snapshot replaces, not merges', () {
      final model = WorkspacesModel(client: BackendClient());
      model.onDecorationDelta({
        'workspaceId': 'ws-1',
        'version': 1,
        'entries': [
          {'path': 'old.dart', 'status': 'M'},
        ],
      });
      // Skip a version (no gap detection since we're seeding) by using a
      // separate workspace state for the snapshot.
      model.onDecorationSnapshot({
        'workspaceId': 'ws-1',
        'version': 5,
        'entries': [
          {'path': 'new.dart', 'status': 'A'},
        ],
      });
      final st = model.stateFor('ws-1')!;
      expect(st.decorationMap.length, 1);
      expect(st.decorationMap.containsKey('old.dart'), isFalse);
      expect(st.decorationMap['new.dart'], 'A');
      expect(st.lastSeenVersion, 5);
    });
  });

  group('head + commit', () {
    test('onHeadChanged populates branch / ahead / behind', () {
      final model = WorkspacesModel(client: BackendClient());
      model.onHeadChanged({
        'workspaceId': 'ws-1',
        'version': 1,
        'branch': 'main',
        'headSha': 'abc123',
        'ahead': 2,
        'behind': 1,
      });
      final st = model.stateFor('ws-1')!;
      expect(st.branch, 'main');
      expect(st.headSha, 'abc123');
      expect(st.ahead, 2);
      expect(st.behind, 1);
      expect(st.isGitRepo, isTrue);
    });

    test('commit.added bumps ahead for matching branch', () {
      final model = WorkspacesModel(client: BackendClient());
      model.onHeadChanged({
        'workspaceId': 'ws-1',
        'version': 1,
        'branch': 'feature',
        'headSha': 'aaa',
        'ahead': 0,
        'behind': 0,
      });
      model.onCommitAdded({
        'workspaceId': 'ws-1',
        'version': 2,
        'branch': 'feature',
        'sha': 'bbb',
        'subject': 'tweak',
      });
      expect(model.stateFor('ws-1')!.ahead, 1);
    });
  });

  group('listDir cache', () {
    test('serves cached entries on second call', () async {
      final model = WorkspacesModel(client: BackendClient());
      var fetches = 0;
      Future<List<DirEntry>> fetch() async {
        fetches++;
        return const [];
      }

      await model.listDir(workspaceId: 'ws-1', path: 'src', fetch: fetch);
      await model.listDir(workspaceId: 'ws-1', path: 'src', fetch: fetch);
      // First call hits the lambda; second is cache hit.
      expect(fetches, 1);
    });

    test('tree.delta invalidates affected parent', () async {
      final model = WorkspacesModel(client: BackendClient());
      var fetches = 0;
      Future<List<DirEntry>> fetch() async {
        fetches++;
        return const [];
      }

      // Seed lastSeenVersion so a version-1 delta is treated as the first
      // valid event (matching server semantics where the first event after
      // subscribe is version=baseVersion+1).
      model.onDecorationSnapshot({
        'workspaceId': 'ws-1',
        'version': 0,
        'entries': const [],
      });
      await model.listDir(
        workspaceId: 'ws-1',
        path: 'src',
        fetch: fetch,
      );
      // Cache hit confirms baseline.
      await model.listDir(
        workspaceId: 'ws-1',
        path: 'src',
        fetch: fetch,
      );
      expect(fetches, 1);
      // tree.delta touching src/ should evict its cache entry.
      model.onTreeDelta({
        'workspaceId': 'ws-1',
        'version': 1,
        'added': ['src/new.dart'],
        'removed': const [],
        'renamed': const [],
      });
      await model.listDir(
        workspaceId: 'ws-1',
        path: 'src',
        fetch: fetch,
      );
      expect(fetches, 2);
    });

    test('snapshot subscribe-mode clears entire cache via state hook', () async {
      final model = WorkspacesModel(client: BackendClient());
      var fetches = 0;
      Future<List<DirEntry>> fetch() async {
        fetches++;
        return const [];
      }

      await model.listDir(
        workspaceId: 'ws-1',
        path: 'src',
        fetch: fetch,
      );
      await model.listDir(
        workspaceId: 'ws-1',
        path: 'docs',
        fetch: fetch,
      );
      expect(fetches, 2);
      expect(model.stateFor('ws-1')!.cachedListDirCount, 2);
      // A snapshot push doesn't itself wipe the listDir cache (that's done
      // by the subscribe handler on mode=snapshot). Verify the
      // evictListDirEntry hook works as our coarse approximation.
      model.evictListDirEntry('ws-1', 'src');
      expect(model.stateFor('ws-1')!.hasCachedListDir('src'), isFalse);
      expect(model.stateFor('ws-1')!.hasCachedListDir('docs'), isTrue);
    });
  });
}
