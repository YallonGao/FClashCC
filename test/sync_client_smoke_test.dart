import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/profile_sync.dart';
import 'package:fl_clash/common/sync_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// Exercises the real client against a running FClashBack instance:
///
///     flutter test test/sync_client_smoke_test.dart \
///       --dart-define=FCLASH_SYNC_SMOKE_SERVER=http://127.0.0.1:8799
///
/// It is skipped without that define so the normal suite needs no server.
void main() {
  const baseUrl = String.fromEnvironment('FCLASH_SYNC_SMOKE_SERVER');
  final skip = baseUrl.isEmpty
      ? 'set FCLASH_SYNC_SMOKE_SERVER to run this test'
      : null;

  test('round trip against a live server', () async {
    final client = SyncClient(baseUrl: baseUrl);
    final username = 'smoke_${DateTime.now().microsecondsSinceEpoch}';

    final auth = await client.authenticate(
      username: username,
      password: 'password123',
      register: true,
      deviceKey: 'device-smoke-0001',
      deviceName: 'smoke',
      platform: 'windows',
    );

    final empty = await client.state(auth.accessToken);
    expect(empty.revision, 0);

    final pushed = await client.upload(
      token: auth.accessToken,
      bytes: const [1, 2, 3, 4],
      baseRevision: 0,
    );
    expect(pushed.revision, 1);

    final dir = Directory.systemTemp.createTempSync('fclash-sync-smoke');
    final path = '${dir.path}/snapshot.zip';
    final revision = await client.download(
      token: auth.accessToken,
      destinationPath: path,
    );
    expect(revision, 1);
    expect(File(path).readAsBytesSync(), const [1, 2, 3, 4]);

    await expectLater(
      client.upload(token: auth.accessToken, bytes: const [9], baseRevision: 0),
      throwsA(
        isA<SyncException>().having(
          (error) => error.failure,
          'failure',
          SyncFailure.conflict,
        ),
      ),
    );

    await expectLater(
      client.state('not-a-token'),
      throwsA(
        isA<SyncException>().having(
          (error) => error.failure,
          'failure',
          SyncFailure.unauthorized,
        ),
      ),
    );

    client.close();
    dir.deleteSync(recursive: true);
  }, skip: skip);

  test('profile sync keeps add, edit and delete in step', () async {
    final client = SyncClient(baseUrl: baseUrl);
    final auth = await client.authenticate(
      username: 'profiles_${DateTime.now().microsecondsSinceEpoch}',
      password: 'password123',
      register: true,
      deviceKey: 'device-profiles-01',
      deviceName: 'smoke',
      platform: 'windows',
    );

    SyncProfile make(String id, {String yaml = 'proxies: []'}) => SyncProfile(
      id: id,
      label: 'Airport $id',
      url: 'https://sub.example.com/$id',
      type: 'url',
      content: utf8.encode(yaml),
    );

    final first = await client.pushProfiles(
      token: auth.accessToken,
      since: 0,
      upserts: [make('1'), make('2')],
      deletes: const [],
    );
    expect(first.profiles.map((p) => p.id), containsAll(['1', '2']));
    expect(first.tombstones, isEmpty);

    // A second device joins and sees the same rows.
    final other = await client.pullProfiles(auth.accessToken, 0);
    expect(other.profiles.length, 2);
    expect(utf8.decode(other.profiles.first.content), 'proxies: []');

    // Deleting one publishes a tombstone instead of resurrecting later.
    final removed = await client.pushProfiles(
      token: auth.accessToken,
      since: first.revision,
      upserts: const [],
      deletes: const ['2'],
    );
    expect(removed.tombstones, contains('2'));

    // Re-adding the same content is a no-op for the server.
    final idle = await client.pushProfiles(
      token: auth.accessToken,
      since: removed.revision,
      upserts: [make('1')],
      deletes: const [],
    );
    expect(idle.revision, removed.revision);
    expect(idle.profiles, isEmpty);

    client.close();
  }, skip: skip);
}
