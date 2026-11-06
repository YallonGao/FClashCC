import 'dart:convert';

/// Which server a snapshot came from, and how far the two sides agree.
///
/// This is persisted with the account so a restart knows the last revision it
/// saw. Without it the first push after a restart would carry revision 0 and
/// look stale to the server.
class SyncSession {
  const SyncSession({
    required this.baseUrl,
    required this.username,
    required this.deviceKey,
    required this.deviceName,
    required this.deviceId,
    required this.accessToken,
    required this.refreshToken,
    this.accessExpiresAt,
    this.revision = 0,
    this.lastSyncAt,
  });

  final String baseUrl;
  final String username;
  final String deviceKey;
  final String deviceName;
  final String deviceId;
  final String accessToken;
  final String refreshToken;
  final DateTime? accessExpiresAt;
  final int revision;
  final DateTime? lastSyncAt;

  SyncSession copyWith({
    String? baseUrl,
    String? username,
    String? deviceKey,
    String? deviceName,
    String? deviceId,
    String? accessToken,
    String? refreshToken,
    DateTime? accessExpiresAt,
    int? revision,
    DateTime? lastSyncAt,
  }) {
    return SyncSession(
      baseUrl: baseUrl ?? this.baseUrl,
      username: username ?? this.username,
      deviceKey: deviceKey ?? this.deviceKey,
      deviceName: deviceName ?? this.deviceName,
      deviceId: deviceId ?? this.deviceId,
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      accessExpiresAt: accessExpiresAt ?? this.accessExpiresAt,
      revision: revision ?? this.revision,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'baseUrl': baseUrl,
      'username': username,
      'deviceKey': deviceKey,
      'deviceName': deviceName,
      'deviceId': deviceId,
      'accessToken': accessToken,
      'refreshToken': refreshToken,
      'accessExpiresAt': accessExpiresAt?.toIso8601String(),
      'revision': revision,
      'lastSyncAt': lastSyncAt?.toIso8601String(),
    };
  }

  static SyncSession? fromJson(Map<String, Object?>? json) {
    if (json == null) return null;
    final baseUrl = json['baseUrl'];
    final accessToken = json['accessToken'];
    final refreshToken = json['refreshToken'];
    if (baseUrl is! String ||
        accessToken is! String ||
        refreshToken is! String) {
      return null;
    }
    final revision = json['revision'];
    return SyncSession(
      baseUrl: baseUrl,
      username: json['username'] is String ? json['username']! as String : '',
      deviceKey: json['deviceKey'] is String
          ? json['deviceKey']! as String
          : '',
      deviceName: json['deviceName'] is String
          ? json['deviceName']! as String
          : '',
      deviceId: json['deviceId'] is String ? json['deviceId']! as String : '',
      accessToken: accessToken,
      refreshToken: refreshToken,
      accessExpiresAt: _parseDate(json['accessExpiresAt']),
      revision: revision is int ? revision : 0,
      lastSyncAt: _parseDate(json['lastSyncAt']),
    );
  }

  static DateTime? _parseDate(Object? value) {
    return value is String ? DateTime.tryParse(value) : null;
  }

  static Map<String, Object?>? decode(String? source) {
    if (source == null || source.isEmpty) return null;
    try {
      final decoded = json.decode(source);
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    }
  }
}

/// A push was refused because the server had moved on.
class SyncConflict {
  const SyncConflict({
    required this.remoteRevision,
    required this.localRevision,
    this.remoteChecksum = '',
  });

  final int remoteRevision;
  final int localRevision;
  final String remoteChecksum;
}

class SyncState {
  const SyncState({
    this.session,
    this.online = false,
    this.busy = false,
    this.conflict,
    this.error,
    this.remoteRevision,
  });

  final SyncSession? session;

  /// Whether the last request reached the server. A signed-in account that
  /// cannot reach it is read-only, which is the rule this feature exists for.
  final bool online;
  final bool busy;
  final SyncConflict? conflict;
  final String? error;

  /// The server's revision as of the last successful call, which can be ahead
  /// of [session.revision] when another device pushed.
  final int? remoteRevision;

  bool get isSignedIn => session != null;

  bool get isReadOnly => isSignedIn && !online;

  bool get hasRemoteUpdate =>
      session != null &&
      remoteRevision != null &&
      remoteRevision! > session!.revision;

  SyncState copyWith({
    SyncSession? session,
    bool? online,
    bool? busy,
    SyncConflict? conflict,
    String? error,
    int? remoteRevision,
    bool clearConflict = false,
    bool clearError = false,
    bool clearSession = false,
  }) {
    return SyncState(
      session: clearSession ? null : (session ?? this.session),
      online: online ?? this.online,
      busy: busy ?? this.busy,
      conflict: clearConflict ? null : (conflict ?? this.conflict),
      error: clearError ? null : (error ?? this.error),
      remoteRevision: remoteRevision ?? this.remoteRevision,
    );
  }
}
