import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/cloud_hash.dart';
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

  test('a cloud upload is visible to the next check', () async {
    final client = SyncClient(baseUrl: baseUrl);
    final auth = await client.authenticate(
      username: 'cloud_${DateTime.now().microsecondsSinceEpoch}',
      password: 'password123',
      register: true,
      deviceKey: 'device-cloud-01',
      deviceName: 'smoke',
      platform: 'windows',
    );

    final content = utf8.encode('proxies: []');
    final checksum = cloudChecksum(title: 'Airport', content: content);

    expect(
      await client.checkCloud(
        auth.accessToken,
        kind: 'profile',
        checksums: [checksum],
      ),
      isEmpty,
    );

    await client.uploadCloud(
      auth.accessToken,
      kind: 'profile',
      checksum: checksum,
      title: 'Airport',
      content: content,
    );

    final present = await client.checkCloud(
      auth.accessToken,
      kind: 'profile',
      checksums: [checksum],
    );
    expect(present, contains(checksum));

    client.close();
  }, skip: skip);
}
