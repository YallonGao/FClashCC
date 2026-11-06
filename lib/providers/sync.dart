import 'dart:async';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Keeps this device's subscriptions in step with the account on the server.
///
/// The unit is one subscription, not one archive: every device sends the rows
/// it added or changed and the ids it removed, and applies whatever the server
/// has seen since its last revision. A delete travels as a tombstone, so the
/// next device that syncs removes the row instead of pushing it back.
final syncProvider = NotifierProvider<SyncNotifier, SyncState>(
  SyncNotifier.new,
);

class SyncNotifier extends Notifier<SyncState> {
  static const debounce = Duration(seconds: 3);
  static const heartbeatInterval = Duration(minutes: 2);

  Timer? _debounceTimer;
  Timer? _heartbeat;
  SyncClient? _client;
  bool _applyingRemote = false;
  bool _syncing = false;

  @override
  SyncState build() {
    ref.onDispose(() {
      _debounceTimer?.cancel();
      _heartbeat?.cancel();
      _client?.close();
    });
    ref.listen(profilesProvider, (previous, next) {
      if (previous == null || _applyingRemote) return;
      _scheduleSync();
    });
    unawaited(_restore());
    return const SyncState();
  }

  Future<void> _restore() async {
    final session = SyncSession.fromJson(await preferences.getSyncSessionMap());
    if (session == null) return;
    _client = SyncClient(baseUrl: session.baseUrl);
    state = state.copyWith(session: session);
    // Until the server answers, a local edit could be one the other devices
    // never see, so the gate starts closed.
    SyncGuard.setReadOnly(true);
    await syncNow();
    if (state.session != null) {
      _startHeartbeat();
    }
  }

  /// The reconnect action on the settings page.
  Future<void> refreshRemoteState() => syncNow();

  /// One pass in both directions.
  ///
  /// The local diff is computed and sent before anything from the server is
  /// applied: pulling first would overwrite an edit made while offline, and
  /// the diff that follows would then be empty, losing it for good. The push
  /// response already carries everything changed since our revision, so one
  /// call is enough when there is something to send.
  Future<void> syncNow() async {
    final session = state.session;
    if (session == null || _client == null || _syncing) return;
    _syncing = true;
    state = state.copyWith(busy: true, clearError: true);
    try {
      final local = await _collectLocal();
      final snapshot = await preferences.getSyncSnapshot();
      final plan = planProfileSync(local: local, snapshot: snapshot);

      final result = plan.isEmpty
          ? await _withAuth(
              (token) => _client!.pullProfiles(token, session.revision),
            )
          : await _withAuth(
              (token) => _client!.pushProfiles(
                token: token,
                since: session.revision,
                upserts: plan.upserts,
                deletes: plan.deletes,
              ),
            );

      _applyingRemote = true;
      try {
        await _applyRemote(result);
      } finally {
        _applyingRemote = false;
      }

      final merged = await _collectLocal();
      await preferences.saveSyncSnapshot(snapshotOf(merged.values));
      await _saveSession(
        state.session!.copyWith(
          revision: result.revision,
          lastSyncAt: DateTime.now(),
        ),
      );
      state = state.copyWith(busy: false, online: true, clearError: true);
      SyncGuard.setReadOnly(false);
    } on SyncException catch (error) {
      state = state.copyWith(busy: false);
      _handleFailure(error);
    } catch (error) {
      state = state.copyWith(busy: false, error: compactError(error));
    } finally {
      _syncing = false;
    }
  }

  Future<void> signIn({
    required String baseUrl,
    required String username,
    required String password,
  }) async {
    if (state.busy) return;
    state = state.copyWith(busy: true, clearError: true);
    final deviceKey = await preferences.getOrCreateSyncDeviceKey();
    final client = SyncClient(baseUrl: baseUrl);
    try {
      final auth = await client.authenticate(
        username: username,
        password: password,
        register: false,
        deviceKey: deviceKey,
        deviceName: _deviceName,
        platform: Platform.operatingSystem,
      );
      _client?.close();
      _client = client;
      final session = SyncSession(
        baseUrl: client.baseUrl,
        username: auth.username,
        deviceKey: deviceKey,
        deviceName: _deviceName,
        deviceId: auth.deviceId,
        accessToken: auth.accessToken,
        refreshToken: auth.refreshToken,
      );
      await _saveSession(session);
      await preferences.clearSyncSnapshot();
      state = state.copyWith(session: session, busy: false, online: true);
      SyncGuard.setReadOnly(false);
      _startHeartbeat();
      // A fresh login merges whatever this device already had with the
      // account's copy: nothing local is dropped on the way in.
      await syncNow();
    } on SyncException catch (error) {
      client.close();
      state = state.copyWith(
        busy: false,
        online: false,
        error: error.failure.name,
      );
      SyncGuard.setReadOnly(false);
    }
  }

  Future<void> signOut() async {
    _debounceTimer?.cancel();
    _heartbeat?.cancel();
    _client?.close();
    _client = null;
    await preferences.clearSyncSession();
    await preferences.clearSyncSnapshot();
    SyncGuard.setReadOnly(false);
    state = const SyncState();
  }

  Future<bool> testConnection(String baseUrl) async {
    final client = SyncClient(baseUrl: baseUrl);
    try {
      return await client.ping();
    } finally {
      client.close();
    }
  }

  Future<void> _applyRemote(ProfileSyncResult result) async {
    final profiles = ref.read(profilesProvider.notifier);
    for (final id in result.tombstones) {
      final profileId = int.tryParse(id);
      if (profileId == null) continue;
      if (ref.read(profilesProvider).getProfile(profileId) != null) {
        await profiles.del(profileId, force: true);
      }
    }
    for (final remote in result.profiles) {
      final profileId = int.tryParse(remote.id);
      if (profileId == null) continue;
      if (remote.content.isNotEmpty) {
        final path = await appPath.getProfilePath(remote.id);
        await File(path).safeWriteAsBytes(remote.content);
      }
      final type = ProfileType.values.firstWhere(
        (value) => value.name == remote.type,
        orElse: () => ProfileType.file,
      );
      final existing = ref.read(profilesProvider).getProfile(profileId);
      final next =
          (existing ??
                  Profile(
                    id: profileId,
                    type: type,
                    autoUpdateDuration: defaultUpdateDuration,
                    lastUpdateDate: DateTime.now(),
                  ))
              .copyWith(label: remote.label, url: remote.url, type: type);
      profiles.put(next, force: true);
    }
  }

  /// Only subscriptions can travel; a custom profile is compiled from the
  /// rules and proxies that live in this device's database.
  Future<Map<String, SyncProfile>> _collectLocal() async {
    final collected = <String, SyncProfile>{};
    for (final profile in ref.read(profilesProvider)) {
      if (profile.type == ProfileType.custom) continue;
      final path = await appPath.getProfilePath('${profile.id}');
      final file = File(path);
      final content = await file.exists() ? await file.readAsBytes() : <int>[];
      collected['${profile.id}'] = SyncProfile(
        id: '${profile.id}',
        label: profile.label,
        url: profile.url,
        type: profile.type.name,
        content: content,
      );
    }
    return collected;
  }

  void _scheduleSync() {
    if (!state.isSignedIn) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () {
      unawaited(syncNow());
    });
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(heartbeatInterval, (_) {
      unawaited(syncNow());
    });
  }

  void _handleFailure(SyncException error) {
    switch (error.failure) {
      case SyncFailure.offline:
        state = state.copyWith(online: false, error: error.failure.name);
        SyncGuard.setReadOnly(true);
      case SyncFailure.unauthorized:
        state = state.copyWith(online: false, error: error.failure.name);
        SyncGuard.setReadOnly(true);
      default:
        state = state.copyWith(online: true, error: error.failure.name);
    }
  }

  Future<T> _withAuth<T>(Future<T> Function(String token) run) async {
    final session = state.session!;
    try {
      return await run(session.accessToken);
    } on SyncException catch (error) {
      if (error.failure != SyncFailure.unauthorized) rethrow;
      final refreshed = await _client!.refresh(
        username: session.username,
        refreshToken: session.refreshToken,
        deviceId: session.deviceId,
      );
      await _saveSession(
        state.session!.copyWith(
          accessToken: refreshed.accessToken,
          refreshToken: refreshed.refreshToken,
        ),
      );
      return run(refreshed.accessToken);
    }
  }

  Future<void> _saveSession(SyncSession session) async {
    state = state.copyWith(session: session);
    await preferences.saveSyncSessionMap(session.toJson());
  }

  String get _deviceName {
    try {
      return Platform.localHostname;
    } catch (_) {
      return Platform.operatingSystem;
    }
  }
}
