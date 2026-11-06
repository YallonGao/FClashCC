import 'dart:async';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The account, the connection to its server, and the revision both sides
/// agree on.
///
/// Auto-push is driven from a listener on [profilesProvider] rather than from
/// each action: every profile mutation already lands there, including the ones
/// the editor and the proxy list make, so one listener covers them all.
final syncProvider = NotifierProvider<SyncNotifier, SyncState>(
  SyncNotifier.new,
);

class SyncNotifier extends Notifier<SyncState> {
  static const pushDebounce = Duration(seconds: 4);
  static const heartbeatInterval = Duration(minutes: 2);

  Timer? _pushTimer;
  Timer? _heartbeat;
  SyncClient? _client;
  bool _applyingRemote = false;

  @override
  SyncState build() {
    ref.onDispose(() {
      _pushTimer?.cancel();
      _heartbeat?.cancel();
      _client?.close();
    });
    ref.listen(profilesProvider, (previous, next) {
      if (previous == null || _applyingRemote) return;
      _schedulePush();
    });
    unawaited(_restore());
    return const SyncState();
  }

  Future<void> _restore() async {
    final session = SyncSession.fromJson(await preferences.getSyncSessionMap());
    if (session == null) return;
    _client = SyncClient(baseUrl: session.baseUrl);
    state = state.copyWith(session: session);
    // Until the server answers, the account is treated as offline: a stale
    // local edit is worse than a rejected one.
    SyncGuard.setReadOnly(true);
    await refreshRemoteState();
    if (state.session != null) {
      _startHeartbeat();
    }
  }

  Future<void> signIn({
    required String baseUrl,
    required String username,
    required String password,
    required bool register,
  }) async {
    if (state.busy) return;
    state = state.copyWith(busy: true, clearError: true, clearConflict: true);
    final deviceKey = await preferences.getOrCreateSyncDeviceKey();
    final client = SyncClient(baseUrl: baseUrl);
    try {
      final auth = await client.authenticate(
        username: username,
        password: password,
        register: register,
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
      state = state.copyWith(
        session: session,
        busy: false,
        online: true,
        clearError: true,
      );
      SyncGuard.setReadOnly(false);
      _startHeartbeat();
      unawaited(_adoptRemote(session));
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

  /// A new device takes the server's copy when there is one, and seeds the
  /// server with its own when there is not.
  Future<void> _adoptRemote(SyncSession session) async {
    final remote = await _guard(
      () => _withAuth((token) => _client!.state(token)),
    );
    if (remote == null) return;
    state = state.copyWith(remoteRevision: remote.revision);
    if (remote.revision == 0) {
      await push();
      return;
    }
    await pull();
  }

  Future<void> signOut() async {
    _pushTimer?.cancel();
    _heartbeat?.cancel();
    _client?.close();
    _client = null;
    await preferences.clearSyncSession();
    SyncGuard.setReadOnly(false);
    state = const SyncState();
  }

  Future<void> refreshRemoteState() async {
    final session = state.session;
    if (session == null || _client == null) return;
    try {
      final remote = await _withAuth((token) => _client!.state(token));
      state = state.copyWith(
        online: true,
        remoteRevision: remote.revision,
        clearError: true,
      );
      SyncGuard.setReadOnly(false);
    } on SyncException catch (error) {
      _handleFailure(error);
    }
  }

  Future<void> push({bool force = false}) async {
    final session = state.session;
    if (session == null || _client == null) return;
    if (state.busy || (state.conflict != null && !force)) return;
    state = state.copyWith(busy: true);
    final base = force
        ? (state.remoteRevision ?? session.revision)
        : session.revision;
    try {
      await ref.read(backupActionProvider.notifier).backup((archivePath) async {
        final bytes = await File(archivePath).readAsBytes();
        final result = await _withAuth(
          (token) =>
              _client!.upload(token: token, bytes: bytes, baseRevision: base),
        );
        await _saveSession(
          state.session!.copyWith(
            revision: result.revision,
            lastSyncAt: DateTime.now(),
          ),
        );
        state = state.copyWith(
          busy: false,
          online: true,
          remoteRevision: result.revision,
          clearConflict: true,
          clearError: true,
        );
        return true;
      });
    } on SyncException catch (error) {
      state = state.copyWith(busy: false);
      _handleFailure(error, baseRevision: base);
    } catch (error) {
      state = state.copyWith(busy: false, error: compactError(error));
    }
  }

  Future<void> pull() async {
    final session = state.session;
    if (session == null || _client == null || state.busy) return;
    state = state.copyWith(busy: true, clearConflict: true, clearError: true);
    var revision = session.revision;
    _applyingRemote = true;
    try {
      await ref.read(backupActionProvider.notifier).restore(RestoreOption.all, (
        downloadPath,
      ) async {
        revision = await _withAuth(
          (token) =>
              _client!.download(token: token, destinationPath: downloadPath),
        );
        return downloadPath;
      });
      await _saveSession(
        state.session!.copyWith(revision: revision, lastSyncAt: DateTime.now()),
      );
      state = state.copyWith(
        busy: false,
        online: true,
        remoteRevision: revision,
        clearConflict: true,
        clearError: true,
      );
      SyncGuard.setReadOnly(false);
    } on SyncException catch (error) {
      state = state.copyWith(busy: false);
      _handleFailure(error);
    } catch (error) {
      state = state.copyWith(busy: false, error: compactError(error));
    } finally {
      _applyingRemote = false;
    }
  }

  /// Keeps this device's copy and overwrites the server's.
  Future<void> useLocal() => push(force: true);

  Future<void> useRemote() => pull();

  void _schedulePush() {
    if (!state.isSignedIn || state.conflict != null || _applyingRemote) return;
    _pushTimer?.cancel();
    _pushTimer = Timer(pushDebounce, () {
      if (state.online) {
        unawaited(push());
      }
    });
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(heartbeatInterval, (_) {
      unawaited(refreshRemoteState());
    });
  }

  void _handleFailure(SyncException error, {int? baseRevision}) {
    switch (error.failure) {
      case SyncFailure.offline:
        state = state.copyWith(online: false, error: error.failure.name);
        SyncGuard.setReadOnly(true);
      case SyncFailure.conflict:
        state = state.copyWith(
          online: true,
          conflict: SyncConflict(
            remoteRevision: error.remoteRevision ?? 0,
            localRevision: baseRevision ?? state.session?.revision ?? 0,
            remoteChecksum: error.remoteChecksum ?? '',
          ),
          clearError: true,
        );
      case SyncFailure.unauthorized:
        // The refresh token is dead too. Keep the account so the address and
        // user name survive, but stay read-only until it signs in again.
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

  Future<T?> _guard<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on SyncException catch (error) {
      _handleFailure(error);
      return null;
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
