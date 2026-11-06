import 'dart:convert';

import 'package:crypto/crypto.dart';

/// One subscription as it travels between a device and the server.
class SyncProfile {
  const SyncProfile({
    required this.id,
    required this.label,
    required this.url,
    required this.type,
    required this.content,
  });

  final String id;
  final String label;
  final String url;
  final String type;
  final List<int> content;

  String get checksum {
    final digest = sha256.convert([
      ...utf8.encode('$label\u0000$url\u0000$type\u0000'),
      ...content,
    ]);
    return digest.toString();
  }
}

/// What to send: changed or new rows, and ids this device no longer has.
class SyncPlan {
  const SyncPlan({required this.upserts, required this.deletes});

  final List<SyncProfile> upserts;
  final List<String> deletes;

  bool get isEmpty => upserts.isEmpty && deletes.isEmpty;
}

/// Diffs the device against the checksums it saw after the last sync.
///
/// The snapshot is the whole state, so a profile that is gone locally but
/// present in the snapshot is a deletion the server has not heard about yet.
/// That is what makes a delete travel to the other devices instead of the
/// next pull bringing the row back.
SyncPlan planProfileSync({
  required Map<String, SyncProfile> local,
  required Map<String, String> snapshot,
}) {
  final upserts = [
    for (final profile in local.values)
      if (snapshot[profile.id] != profile.checksum) profile,
  ];
  final deletes = [
    for (final id in snapshot.keys)
      if (!local.containsKey(id)) id,
  ];
  return SyncPlan(upserts: upserts, deletes: deletes);
}

/// The checksums a device should remember after applying [profiles].
Map<String, String> snapshotOf(Iterable<SyncProfile> profiles) {
  return {for (final profile in profiles) profile.id: profile.checksum};
}
