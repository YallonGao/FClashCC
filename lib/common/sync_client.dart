import 'dart:io';

import 'package:dio/dio.dart';

/// What went wrong, in terms the UI can act on.
enum SyncFailure {
  offline,
  unauthorized,
  conflict,
  registrationClosed,
  usernameTaken,
  invalidCredentials,
  invalidResponse,
  server,
}

final class SyncException implements Exception {
  const SyncException(
    this.failure, {
    this.statusCode,
    this.message,
    this.remoteRevision,
    this.remoteChecksum,
  });

  final SyncFailure failure;
  final int? statusCode;
  final String? message;
  final int? remoteRevision;
  final String? remoteChecksum;

  @override
  String toString() => 'SyncException(${failure.name}, $statusCode, $message)';
}

class SyncAuthResult {
  const SyncAuthResult({
    required this.username,
    required this.deviceId,
    required this.accessToken,
    required this.refreshToken,
  });

  final String username;
  final String deviceId;
  final String accessToken;
  final String refreshToken;
}

class RemoteSyncState {
  const RemoteSyncState({
    required this.revision,
    required this.checksum,
    required this.size,
  });

  final int revision;
  final String checksum;
  final int size;
}

class PushResult {
  const PushResult({required this.revision, required this.checksum});

  final int revision;
  final String checksum;
}

/// Thin client over the FClashBack API. It holds no state: the notifier owns
/// the tokens and passes them in, so a failed refresh cannot leave this object
/// holding a token the rest of the app believes is gone.
class SyncClient {
  SyncClient({required String baseUrl, Dio? dio})
    : _baseUrl = _normalize(baseUrl.trim()),
      _dio = dio ?? Dio() {
    _dio.options
      ..baseUrl = _baseUrl
      ..connectTimeout = const Duration(seconds: 10)
      ..sendTimeout = const Duration(seconds: 60)
      ..receiveTimeout = const Duration(seconds: 60)
      ..followRedirects = true
      ..validateStatus = (_) => true;
  }

  final String _baseUrl;
  final Dio _dio;

  String get baseUrl => _baseUrl;

  /// Accepts `host:port` too, because that is what people type on a LAN.
  static String _normalize(String raw) {
    if (raw.isEmpty) return raw;
    final withScheme = raw.contains('://') ? raw : 'http://$raw';
    return withScheme.replaceAll(RegExp(r'/+$'), '');
  }

  static String get _api => '/api/v1';

  Map<String, String> _headers(String? token) {
    return {
      if (token != null) 'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };
  }

  Future<SyncAuthResult> authenticate({
    required String username,
    required String password,
    required bool register,
    required String deviceKey,
    required String deviceName,
    required String platform,
  }) async {
    final response = await _send(
      () => _dio.post<Map<String, Object?>>(
        '$_api/auth/${register ? 'register' : 'login'}',
        data: {
          'username': username,
          'password': password,
          'device': {
            'key': deviceKey,
            'name': deviceName,
            'platform': platform,
          },
        },
        options: Options(headers: _headers(null)),
      ),
    );
    final body = response.data;
    final tokens = body?['tokens'];
    final device = body?['device'];
    final user = body?['user'];
    if (tokens is! Map || device is! Map || user is! Map) {
      throw const SyncException(SyncFailure.invalidResponse);
    }
    final access = tokens['access_token'];
    final refresh = tokens['refresh_token'];
    final deviceId = device['id'];
    if (access is! String || refresh is! String || deviceId is! String) {
      throw const SyncException(SyncFailure.invalidResponse);
    }
    return SyncAuthResult(
      username: user['username'] is String
          ? user['username']! as String
          : username,
      deviceId: deviceId,
      accessToken: access,
      refreshToken: refresh,
    );
  }

  Future<SyncAuthResult> refresh({
    required String username,
    required String refreshToken,
    required String deviceId,
  }) async {
    final response = await _send(
      () => _dio.post<Map<String, Object?>>(
        '$_api/auth/refresh',
        data: {'refresh_token': refreshToken},
        options: Options(headers: _headers(null)),
      ),
    );
    final body = response.data;
    final access = body?['access_token'];
    final refresh = body?['refresh_token'];
    if (access is! String || refresh is! String) {
      throw const SyncException(SyncFailure.invalidResponse);
    }
    return SyncAuthResult(
      username: username,
      deviceId: deviceId,
      accessToken: access,
      refreshToken: refresh,
    );
  }

  Future<RemoteSyncState> state(String token) async {
    final response = await _send(
      () => _dio.get<Map<String, Object?>>(
        '$_api/sync/state',
        options: Options(headers: _headers(token)),
      ),
    );
    final body = response.data;
    final revision = body?['revision'];
    final checksum = body?['checksum'];
    final size = body?['size'];
    if (revision is! int) {
      throw const SyncException(SyncFailure.invalidResponse);
    }
    return RemoteSyncState(
      revision: revision,
      checksum: checksum is String ? checksum : '',
      size: size is int ? size : 0,
    );
  }

  Future<PushResult> upload({
    required String token,
    required List<int> bytes,
    required int baseRevision,
  }) async {
    final response = await _send(
      () => _dio.put<Map<String, Object?>>(
        '$_api/sync/snapshot',
        queryParameters: {'base_revision': baseRevision},
        data: Stream.fromIterable([bytes]),
        options: Options(
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/octet-stream',
            'Content-Length': bytes.length,
          },
        ),
      ),
      conflictAware: true,
    );
    final body = response.data;
    final revision = body?['revision'];
    final checksum = body?['checksum'];
    if (revision is! int) {
      throw const SyncException(SyncFailure.invalidResponse);
    }
    return PushResult(
      revision: revision,
      checksum: checksum is String ? checksum : '',
    );
  }

  Future<int> download({
    required String token,
    required String destinationPath,
  }) async {
    final response = await _send(
      () => _dio.get<List<int>>(
        '$_api/sync/snapshot',
        options: Options(
          headers: {'Authorization': 'Bearer $token'},
          responseType: ResponseType.bytes,
        ),
      ),
    );
    final bytes = response.data;
    if (bytes == null) {
      throw const SyncException(SyncFailure.invalidResponse);
    }
    await File(destinationPath).writeAsBytes(bytes, flush: true);
    return int.tryParse(response.headers.value('X-Revision') ?? '') ?? 0;
  }

  void close() {
    _dio.close(force: true);
  }

  Future<Response<T>> _send<T>(
    Future<Response<T>> Function() request, {
    bool conflictAware = false,
  }) async {
    final Response<T> response;
    try {
      response = await request();
    } on DioException catch (error) {
      final kind = error.type;
      if (kind == DioExceptionType.connectionError ||
          kind == DioExceptionType.connectionTimeout ||
          kind == DioExceptionType.sendTimeout ||
          kind == DioExceptionType.receiveTimeout) {
        throw const SyncException(SyncFailure.offline);
      }
      throw SyncException(
        SyncFailure.server,
        message: '${kind.name}: ${error.error ?? error.message}',
      );
    }

    final status = response.statusCode ?? 0;
    if (status >= 200 && status < 300) {
      return response;
    }
    if (status == 401) {
      throw const SyncException(SyncFailure.unauthorized, statusCode: 401);
    }
    if (status == 409 && conflictAware) {
      final detail = response.data;
      final map = detail is Map ? detail['detail'] : null;
      if (map is Map) {
        final revision = map['current_revision'];
        throw SyncException(
          SyncFailure.conflict,
          statusCode: 409,
          remoteRevision: revision is int ? revision : null,
          remoteChecksum: map['current_checksum'] is String
              ? map['current_checksum']! as String
              : null,
        );
      }
      throw const SyncException(SyncFailure.conflict, statusCode: 409);
    }

    final data = response.data;
    final detail = data is Map ? data['detail'] : null;
    if (detail == 'registration_closed') {
      throw const SyncException(
        SyncFailure.registrationClosed,
        statusCode: 403,
      );
    }
    if (detail == 'username_taken') {
      throw const SyncException(SyncFailure.usernameTaken, statusCode: 409);
    }
    if (detail == 'invalid_credentials') {
      throw const SyncException(
        SyncFailure.invalidCredentials,
        statusCode: 401,
      );
    }
    throw SyncException(
      SyncFailure.server,
      statusCode: status,
      message: detail is String ? detail : null,
    );
  }
}
