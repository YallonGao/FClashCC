import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Knows which local items the cloud already holds, and uploads on request.
///
/// Nothing is pushed automatically: the cloud is a place the owner puts things
/// into, not a mirror of whatever the device happens to have. Presence is
/// decided by checksum, so a rule or a DNS block needs no id to be compared.
final syncProvider = NotifierProvider<SyncNotifier, SyncState>(
  SyncNotifier.new,
);

class SyncNotifier extends Notifier<SyncState> {
  static const heartbeatInterval = Duration(minutes: 2);

  Timer? _heartbeat;
  SyncClient? _client;
  bool _busy = false;

  @override
  SyncState build() {
    ref.onDispose(() {
      _heartbeat?.cancel();
      _client?.close();
    });
    unawaited(_restore());
    return const SyncState();
  }

  Future<void> _restore() async {
    final session = SyncSession.fromJson(await preferences.getSyncSessionMap());
    if (session == null) return;
    _client = SyncClient(baseUrl: session.baseUrl);
    state = state.copyWith(session: session);
    await refreshCloud();
    if (state.session != null) {
      _startHeartbeat();
    }
  }

  /// Recomputes local checksums and asks the cloud which of them it has.
  Future<void> refreshCloud() async {
    final session = state.session;
    if (session == null || _client == null || _busy) return;
    _busy = true;
    state = state.copyWith(busy: true, clearError: true);
    try {
      final hashes = await _localHashes();
      final present = await _withAuth(
        (token) => _client!.checkCloud(
          token,
          kind: 'profile',
          checksums: hashes.values.toList(),
        ),
      );
      state = state.copyWith(
        profileHashes: hashes,
        cloudPresent: present,
        busy: false,
        online: true,
        clearError: true,
      );
    } on SyncException catch (error) {
      state = state.copyWith(busy: false);
      _handleFailure(error);
    } catch (error) {
      state = state.copyWith(busy: false, error: compactError(error));
    } finally {
      _busy = false;
    }
  }

  /// Uploads one profile, content first: its id is its checksum.
  Future<void> uploadProfile(Profile profile) async {
    final session = state.session;
    if (session == null || _client == null) return;
    final content = await _readProfileBytes(profile.id);
    final checksum = cloudChecksum(title: profile.label, content: content);
    state = state.copyWith(busy: true, clearError: true);
    try {
      await _withAuth(
        (token) => _client!.uploadCloud(
          token,
          kind: 'profile',
          checksum: checksum,
          title: profile.label,
          content: content,
        ),
      );
      await _saveSession(state.session!.copyWith(lastUploadAt: DateTime.now()));
      state = state.copyWith(
        busy: false,
        online: true,
        cloudPresent: {...state.cloudPresent, checksum},
      );
      await refreshCloud();
    } on SyncException catch (error) {
      state = state.copyWith(busy: false);
      _handleFailure(error);
    } catch (error) {
      state = state.copyWith(busy: false, error: compactError(error));
    }
  }

  Future<List<CloudItem>> listCloud(String kind) async {
    final session = state.session;
    if (session == null || _client == null) return const [];
    try {
      return await _withAuth((token) => _client!.listCloud(token, kind: kind));
    } on SyncException catch (error) {
      _handleFailure(error);
      return const [];
    }
  }

  /// Writes one cloud item back into this device's own storage.
  Future<void> addFromCloud(CloudItem item) async {
    switch (item.kind) {
      case 'profile':
        await _addProfileFromCloud(item);
      case 'rule':
        await _addRuleFromCloud(item);
      case 'script':
        await _addScriptFromCloud(item);
    }
  }

  Future<void> uploadItem({
    required String kind,
    required String title,
    required List<int> content,
  }) async {
    final session = state.session;
    if (session == null || _client == null) return;
    final checksum = cloudChecksum(title: title, content: content);
    state = state.copyWith(busy: true, clearError: true);
    try {
      await _withAuth(
        (token) => _client!.uploadCloud(
          token,
          kind: kind,
          checksum: checksum,
          title: title,
          content: content,
        ),
      );
      await _saveSession(state.session!.copyWith(lastUploadAt: DateTime.now()));
      state = state.copyWith(busy: false, online: true);
      if (kind == 'profile') {
        await refreshCloud();
      }
    } on SyncException catch (error) {
      state = state.copyWith(busy: false);
      _handleFailure(error);
    }
  }

  Future<void> _addProfileFromCloud(CloudItem item) async {
    final id = snowflake.id;
    final path = await appPath.getProfilePath('$id');
    await File(path).safeWriteAsBytes(item.content);
    ref
        .read(profilesProvider.notifier)
        .put(
          Profile(
            id: id,
            type: ProfileType.file,
            label: item.title,
            autoUpdateDuration: defaultUpdateDuration,
            lastUpdateDate: DateTime.now(),
          ),
        );
  }

  Future<void> _addRuleFromCloud(CloudItem item) async {
    final decoded = json.decode(utf8.decode(item.content));
    if (decoded is! Map<String, Object?>) return;
    final rule = Rule.fromJson(decoded);
    ref.read(globalRulesProvider.notifier).put(rule.copyWith(id: snowflake.id));
  }

  Future<void> _addScriptFromCloud(CloudItem item) async {
    final id = snowflake.id;
    final path = await appPath.getScriptPath('$id');
    await File(path).safeWriteAsBytes(item.content);
    ref
        .read(scriptsProvider.notifier)
        .put(Script(id: id, label: item.title, lastUpdateTime: DateTime.now()));
  }

  Future<void> uploadRule(Rule rule) {
    return uploadItem(
      kind: 'rule',
      title: rule.content ?? '${rule.ruleAction.name} ${rule.id}',
      content: utf8.encode(json.encode(rule.toJson())),
    );
  }

  Future<void> uploadScript(Script script) async {
    final path = await appPath.getScriptPath('${script.id}');
    final file = File(path);
    final content = await file.exists()
        ? await file.readAsBytes()
        : const <int>[];
    await uploadItem(kind: 'script', title: script.label, content: content);
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
      await _saveSession(
        SyncSession(
          baseUrl: client.baseUrl,
          username: auth.username,
          deviceKey: deviceKey,
          deviceName: _deviceName,
          deviceId: auth.deviceId,
          accessToken: auth.accessToken,
          refreshToken: auth.refreshToken,
        ),
      );
      state = state.copyWith(busy: false, online: true);
      _startHeartbeat();
      await refreshCloud();
    } on SyncException catch (error) {
      client.close();
      state = state.copyWith(
        busy: false,
        online: false,
        error: error.failure.name,
      );
    }
  }

  Future<void> signOut() async {
    _heartbeat?.cancel();
    _client?.close();
    _client = null;
    await preferences.clearSyncSession();
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

  Future<Map<String, String>> _localHashes() async {
    final hashes = <String, String>{};
    for (final profile in ref.read(profilesProvider)) {
      // A custom profile is compiled from local rules and proxies; it has no
      // single body to compare.
      if (profile.type == ProfileType.custom) continue;
      final content = await _readProfileBytes(profile.id);
      hashes['${profile.id}'] = cloudChecksum(
        title: profile.label,
        content: content,
      );
    }
    return hashes;
  }

  Future<List<int>> _readProfileBytes(int id) async {
    final path = await appPath.getProfilePath('$id');
    final file = File(path);
    return await file.exists() ? await file.readAsBytes() : const [];
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(heartbeatInterval, (_) {
      unawaited(refreshCloud());
    });
  }

  void _handleFailure(SyncException error) {
    switch (error.failure) {
      case SyncFailure.offline:
        state = state.copyWith(online: false, error: error.failure.name);
      case SyncFailure.unauthorized:
        state = state.copyWith(online: false, error: error.failure.name);
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
