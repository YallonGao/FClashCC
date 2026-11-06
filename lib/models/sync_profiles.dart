import 'dart:convert';

/// A subscription as the server holds it.
class RemoteProfile {
  const RemoteProfile({
    required this.id,
    required this.label,
    required this.url,
    required this.type,
    required this.content,
    required this.checksum,
  });

  final String id;
  final String label;
  final String url;
  final String type;
  final List<int> content;
  final String checksum;

  static RemoteProfile? fromJson(Map<String, Object?> json) {
    final id = json['profile_id'];
    if (id is! String || id.isEmpty) return null;
    final raw = json['content'];
    return RemoteProfile(
      id: id,
      label: json['label'] is String ? json['label']! as String : '',
      url: json['url'] is String ? json['url']! as String : '',
      type: json['type'] is String ? json['type']! as String : 'file',
      content: raw is String && raw.isNotEmpty ? base64Decode(raw) : const [],
      checksum: json['checksum'] is String ? json['checksum']! as String : '',
    );
  }
}

class ProfileSyncResult {
  const ProfileSyncResult({
    required this.revision,
    required this.profiles,
    required this.tombstones,
  });

  final int revision;
  final List<RemoteProfile> profiles;
  final List<String> tombstones;

  static ProfileSyncResult? fromJson(Map<String, Object?>? json) {
    if (json == null) return null;
    final revision = json['revision'];
    if (revision is! int) return null;
    final profiles = <RemoteProfile>[];
    final raw = json['upserts'];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map<String, Object?>) {
          final profile = RemoteProfile.fromJson(item);
          if (profile != null) profiles.add(profile);
        }
      }
    }
    final tombstones = <String>[];
    final rawTombstones = json['tombstones'];
    if (rawTombstones is List) {
      for (final item in rawTombstones) {
        if (item is String) tombstones.add(item);
      }
    }
    return ProfileSyncResult(
      revision: revision,
      profiles: profiles,
      tombstones: tombstones,
    );
  }
}
