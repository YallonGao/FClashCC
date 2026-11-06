import 'dart:convert';

import 'package:fl_clash/common/profile_sync.dart';
import 'package:flutter_test/flutter_test.dart';

SyncProfile _profile(String id, {String label = 'Airport', String yaml = 'proxies: []'}) {
  return SyncProfile(
    id: id,
    label: label,
    url: 'https://sub.example.com/$id',
    type: 'url',
    content: utf8.encode(yaml),
  );
}

void main() {
  test('a fresh device uploads everything it has', () {
    final plan = planProfileSync(
      local: {'1': _profile('1'), '2': _profile('2')},
      snapshot: const {},
    );
    expect(plan.upserts.map((p) => p.id), containsAll(['1', '2']));
    expect(plan.deletes, isEmpty);
  });

  test('an unchanged device sends nothing', () {
    final local = {'1': _profile('1')};
    final snapshot = snapshotOf(local.values);

    final plan = planProfileSync(local: local, snapshot: snapshot);
    expect(plan.isEmpty, isTrue);
  });

  test('an edited profile is uploaded', () {
    final local = {'1': _profile('1', yaml: 'proxies: [a]')};
    final snapshot = snapshotOf([_profile('1')]);

    final plan = planProfileSync(local: local, snapshot: snapshot);
    expect(plan.upserts.single.id, '1');
    expect(plan.deletes, isEmpty);
  });

  test('a local delete becomes a tombstone request', () {
    final snapshot = snapshotOf([_profile('1'), _profile('2')]);
    final local = {'1': _profile('1')};

    final plan = planProfileSync(local: local, snapshot: snapshot);
    expect(plan.deletes, ['2']);
    expect(plan.upserts, isEmpty);
  });

  test('adds and removes travel in the same pass', () {
    final snapshot = snapshotOf([_profile('1')]);
    final local = {'2': _profile('2')};

    final plan = planProfileSync(local: local, snapshot: snapshot);
    expect(plan.upserts.single.id, '2');
    expect(plan.deletes, ['1']);
  });

  test('checksum covers label, url and content', () {
    final base = _profile('1');
    expect(_profile('1', label: 'Other').checksum, isNot(base.checksum));
    expect(_profile('1', yaml: 'proxies: [a]').checksum, isNot(base.checksum));
  });
}
