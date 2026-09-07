import 'dart:async';

import 'package:dio/dio.dart';

import '../core/env.dart';
import '../domain/entities/caption.dart';
import '../domain/entities/conversation.dart';
import '../domain/entities/emotion_tone.dart';
import 'api_exception.dart';
import 'token_store.dart';

/// HearO 백엔드 클라이언트.
///
/// 액세스 토큰이 만료되면 자동으로 리프레시하고 원래 요청을 재시도한다.
/// 동시에 여러 요청이 401 을 받아도 리프레시는 한 번만 일어난다 — 그러지 않으면
/// 리프레시 토큰 회전 때문에 서로가 서로를 무효화해 전부 로그아웃된다.
class ApiClient {
  ApiClient({required TokenStore tokenStore, Dio? dio})
      : _tokens = tokenStore,
        _dio = dio ?? Dio() {
    _configure();
  }

  final TokenStore _tokens;
  final Dio _dio;

  /// 로그인이 완전히 만료되었을 때 호출된다 (라우터가 로그인 화면으로 보낸다).
  void Function()? onAuthenticationLost;

  Completer<bool>? _refreshInFlight;

  void _configure() {
    _dio.options = BaseOptions(
      baseUrl: '${Env.apiBaseUrl}/api/v1',
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 20),
      sendTimeout: const Duration(seconds: 20),
      headers: {'Content-Type': 'application/json'},
      // 상태 코드로 던지지 않고 우리가 직접 판단한다.
      validateStatus: (status) => status != null && status < 500,
    );

    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final token = _tokens.accessToken;
          if (token != null && options.extra['skipAuth'] != true) {
            options.headers['Authorization'] = 'Bearer $token';
          }
          handler.next(options);
        },
        onResponse: (response, handler) {
          // validateStatus 를 넓혀 두었으므로 4xx 를 여기서 예외로 바꾼다.
          final status = response.statusCode ?? 0;
          if (status >= 400) {
            handler.reject(
              DioException(
                requestOptions: response.requestOptions,
                response: response,
                type: DioExceptionType.badResponse,
              ),
              true,
            );
            return;
          }
          handler.next(response);
        },
        onError: (error, handler) async {
          final shouldRefresh = error.response?.statusCode == 401 &&
              error.requestOptions.extra['retried'] != true &&
              error.requestOptions.extra['skipAuth'] != true &&
              _tokens.refreshToken != null;

          if (!shouldRefresh) {
            handler.next(error);
            return;
          }

          final refreshed = await _refreshTokens();
          if (!refreshed) {
            await _tokens.clear();
            onAuthenticationLost?.call();
            handler.next(error);
            return;
          }

          // 갱신된 토큰으로 원래 요청을 한 번만 다시 시도한다.
          try {
            final options = error.requestOptions;
            options.extra['retried'] = true;
            options.headers['Authorization'] = 'Bearer ${_tokens.accessToken}';
            final response = await _dio.fetch<dynamic>(options);
            handler.resolve(response);
          } on DioException catch (retryError) {
            handler.next(retryError);
          }
        },
      ),
    );
  }

  /// 리프레시를 한 번만 수행하고, 그 사이 들어온 요청들은 결과를 기다린다.
  Future<bool> _refreshTokens() async {
    if (_refreshInFlight != null) return _refreshInFlight!.future;

    final completer = Completer<bool>();
    _refreshInFlight = completer;

    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/auth/refresh',
        data: {'refresh_token': _tokens.refreshToken},
        options: Options(extra: {'skipAuth': true, 'retried': true}),
      );
      final data = response.data;
      if (data == null) {
        completer.complete(false);
      } else {
        await _tokens.save(
          accessToken: data['access_token'] as String,
          refreshToken: data['refresh_token'] as String,
        );
        completer.complete(true);
      }
    } on Object {
      completer.complete(false);
    } finally {
      _refreshInFlight = null;
    }

    return completer.future;
  }

  // ================================================================ helpers

  Future<T> _request<T>(
    Future<Response<dynamic>> Function() send,
    T Function(dynamic data) parse,
  ) async {
    try {
      final response = await send();
      return parse(response.data);
    } on DioException catch (error) {
      throw ApiException.fromDioException(error);
    }
  }

  Map<String, dynamic> _asMap(dynamic data) {
    if (data is Map<String, dynamic>) return data;
    throw const ApiException(
      code: 'BAD_RESPONSE',
      message: '서버 응답 형식이 올바르지 않습니다.',
    );
  }

  // ================================================================ 인증

  Future<AuthResult> register({
    required String email,
    required String password,
    required String displayName,
  }) {
    return _request(
      () => _dio.post<dynamic>(
        '/auth/register',
        data: {
          'email': email,
          'password': password,
          'display_name': displayName,
        },
        options: Options(extra: {'skipAuth': true}),
      ),
      (data) => AuthResult.fromJson(_asMap(data)),
    );
  }

  Future<AuthResult> login({
    required String email,
    required String password,
  }) {
    return _request(
      () => _dio.post<dynamic>(
        '/auth/login',
        data: {'email': email, 'password': password},
        options: Options(extra: {'skipAuth': true}),
      ),
      (data) => AuthResult.fromJson(_asMap(data)),
    );
  }

  Future<void> logout() async {
    try {
      await _dio.post<dynamic>(
        '/auth/logout',
        data: {'refresh_token': _tokens.refreshToken},
      );
    } on DioException {
      // 서버에 못 알려도 로컬 토큰은 반드시 지운다. 사용자가 "로그아웃" 을
      // 눌렀는데 네트워크 때문에 로그인 상태로 남는 것이 가장 나쁘다.
    }
  }

  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) {
    return _request(
      () => _dio.post<dynamic>(
        '/auth/change-password',
        data: {
          'current_password': currentPassword,
          'new_password': newPassword,
        },
      ),
      (_) {},
    );
  }

  Future<void> deleteAccount(String password) {
    return _request(
      () => _dio.delete<dynamic>('/auth/me', data: {'password': password}),
      (_) {},
    );
  }

  /// 라이브 WebSocket 접속용 1회용 티켓.
  Future<String> issueWebSocketTicket() {
    return _request(
      () => _dio.post<dynamic>('/auth/ws-ticket'),
      (data) => _asMap(data)['ticket'] as String,
    );
  }

  // ================================================================ 세션

  Future<ConversationSummary> createSession({
    String? title,
    String? locationLabel,
    double? latitude,
    double? longitude,
    String? contextHint,
  }) {
    return _request(
      () => _dio.post<dynamic>(
        '/sessions',
        data: {
          if (title != null) 'title': title,
          if (locationLabel != null) 'location_label': locationLabel,
          if (latitude != null) 'latitude': latitude,
          if (longitude != null) 'longitude': longitude,
          if (contextHint != null) 'context_hint': contextHint,
        },
      ),
      (data) => ConversationSummary.fromJson(_asMap(data)),
    );
  }

  Future<void> importSession(
    String sessionId, {
    required List<Map<String, dynamic>> speakers,
    required List<Map<String, dynamic>> utterances,
  }) {
    return _request(
      () => _dio.post<dynamic>(
        '/sessions/$sessionId/import',
        data: {'speakers': speakers, 'utterances': utterances},
      ),
      (_) {},
    );
  }

  Future<Paged<ConversationSummary>> listSessions({
    String? query,
    DateTime? dateFrom,
    DateTime? dateTo,
    String? location,
    String? speakerName,
    bool favoritesOnly = false,
    EmotionTone? tone,
    String sort = 'started_at',
    String order = 'desc',
    int limit = 20,
    int offset = 0,
  }) {
    return _request(
      () => _dio.get<dynamic>(
        '/sessions',
        queryParameters: {
          if (query != null && query.isNotEmpty) 'q': query,
          if (dateFrom != null) 'date_from': dateFrom.toUtc().toIso8601String(),
          if (dateTo != null) 'date_to': dateTo.toUtc().toIso8601String(),
          if (location != null && location.isNotEmpty) 'location': location,
          if (speakerName != null && speakerName.isNotEmpty)
            'speaker_name': speakerName,
          if (favoritesOnly) 'favorites_only': true,
          if (tone != null) 'tone': tone.wireValue,
          'sort': sort,
          'order': order,
          'limit': limit,
          'offset': offset,
        },
      ),
      (data) => Paged.fromJson(_asMap(data), ConversationSummary.fromJson),
    );
  }

  Future<ConversationDetail> getSession(String sessionId) {
    return _request(
      () => _dio.get<dynamic>('/sessions/$sessionId'),
      (data) => ConversationDetail.fromJson(_asMap(data)),
    );
  }

  Future<ConversationSummary> updateSession(
    String sessionId, {
    String? title,
    bool? isFavorite,
    String? locationLabel,
  }) {
    return _request(
      () => _dio.patch<dynamic>(
        '/sessions/$sessionId',
        data: {
          if (title != null) 'title': title,
          if (isFavorite != null) 'is_favorite': isFavorite,
          if (locationLabel != null) 'location_label': locationLabel,
        },
      ),
      (data) => ConversationSummary.fromJson(_asMap(data)),
    );
  }

  Future<void> deleteSession(String sessionId) {
    return _request(
      () => _dio.delete<dynamic>('/sessions/$sessionId'),
      (_) {},
    );
  }

  Future<Paged<CaptionSearchHit>> searchCaptions(
    String query, {
    int limit = 50,
    int offset = 0,
  }) {
    return _request(
      () => _dio.get<dynamic>(
        '/sessions/search/utterances',
        queryParameters: {'q': query, 'limit': limit, 'offset': offset},
      ),
      (data) => Paged.fromJson(_asMap(data), CaptionSearchHit.fromJson),
    );
  }

  Future<Paged<CaptionSearchHit>> listBookmarks({
    int limit = 50,
    int offset = 0,
  }) {
    return _request(
      () => _dio.get<dynamic>(
        '/sessions/bookmarks',
        queryParameters: {'limit': limit, 'offset': offset},
      ),
      (data) => Paged.fromJson(_asMap(data), CaptionSearchHit.fromJson),
    );
  }

  Future<Speaker> updateSpeaker(
    String sessionId,
    String speakerId, {
    String? displayName,
    String? colorHex,
  }) {
    return _request(
      () => _dio.patch<dynamic>(
        '/sessions/$sessionId/speakers/$speakerId',
        data: {
          if (displayName != null) 'display_name': displayName,
          if (colorHex != null) 'color_hex': colorHex,
        },
      ),
      (data) => Speaker.fromApiJson(_asMap(data)),
    );
  }

  Future<Caption> updateCaption(
    String sessionId,
    String captionId, {
    bool? isBookmarked,
    String? text,
  }) {
    return _request(
      () => _dio.patch<dynamic>(
        '/sessions/$sessionId/utterances/$captionId',
        data: {
          if (isBookmarked != null) 'is_bookmarked': isBookmarked,
          if (text != null) 'text': text,
        },
      ),
      (data) => Caption.fromApiJson(_asMap(data)),
    );
  }

  // ================================================================ 경보

  /// 경보 한 건 기록. 서버가 중복으로 판단하면 null 을 돌려준다.
  Future<AlertRecord?> recordAlert({
    required AlertType type,
    required double confidence,
    required DateTime detectedAt,
    String? rawClass,
    int consecutiveFrames = 1,
    String? sessionId,
    double? latitude,
    double? longitude,
    String? locationLabel,
  }) {
    return _request(
      () => _dio.post<dynamic>(
        '/alerts',
        data: {
          'alert_type': type.wireValue,
          'confidence': confidence,
          'detected_at': detectedAt.toUtc().toIso8601String(),
          if (rawClass != null) 'raw_class': rawClass,
          'consecutive_frames': consecutiveFrames,
          if (sessionId != null) 'session_id': sessionId,
          if (latitude != null) 'latitude': latitude,
          if (longitude != null) 'longitude': longitude,
          if (locationLabel != null) 'location_label': locationLabel,
        },
      ),
      (data) {
        final map = _asMap(data);
        // 중복이면 MessageResponse 가 온다.
        if (!map.containsKey('id')) return null;
        return AlertRecord.fromJson(map);
      },
    );
  }

  /// 오프라인 동안 쌓인 경보 일괄 업로드.
  Future<int> recordAlertsBatch(List<Map<String, dynamic>> alerts) {
    return _request(
      () => _dio.post<dynamic>('/alerts/batch', data: {'alerts': alerts}),
      (data) => (_asMap(data)['total'] as num?)?.toInt() ?? 0,
    );
  }

  Future<Paged<AlertRecord>> listAlerts({
    AlertType? type,
    bool unacknowledgedOnly = false,
    int limit = 50,
    int offset = 0,
  }) {
    return _request(
      () => _dio.get<dynamic>(
        '/alerts',
        queryParameters: {
          if (type != null) 'alert_type': type.wireValue,
          if (unacknowledgedOnly) 'unacknowledged_only': true,
          'limit': limit,
          'offset': offset,
        },
      ),
      (data) => Paged.fromJson(_asMap(data), AlertRecord.fromJson),
    );
  }

  Future<AlertRecord> updateAlert(
    String alertId, {
    bool? acknowledged,
    bool? isFalsePositive,
  }) {
    return _request(
      () => _dio.patch<dynamic>(
        '/alerts/$alertId',
        data: {
          if (acknowledged != null) 'acknowledged': acknowledged,
          if (isFalsePositive != null) 'is_false_positive': isFalsePositive,
        },
      ),
      (data) => AlertRecord.fromJson(_asMap(data)),
    );
  }

  /// 미확인 경보를 모두 확인 처리한다. 처리한 건수를 안내 문구로 돌려준다.
  Future<String> acknowledgeAllAlerts() {
    return _request(
      () => _dio.post<dynamic>('/alerts/acknowledge-all'),
      (data) => _asMap(data)['message'] as String? ?? '확인 처리했습니다.',
    );
  }

  Future<int> unacknowledgedAlertCount() {
    return _request(
      () => _dio.get<dynamic>('/alerts/unacknowledged-count'),
      (data) => (_asMap(data)['count'] as num?)?.toInt() ?? 0,
    );
  }

  // ================================================================ 설정

  Future<AppSettings> getSettings() {
    return _request(
      () => _dio.get<dynamic>('/settings'),
      (data) => AppSettings.fromJson(_asMap(data)),
    );
  }

  Future<AppSettings> updateSettings(Map<String, dynamic> changes) {
    return _request(
      () => _dio.patch<dynamic>('/settings', data: changes),
      (data) => AppSettings.fromJson(_asMap(data)),
    );
  }

  Future<Map<String, dynamic>> getStats() {
    return _request(
      () => _dio.get<dynamic>('/settings/stats'),
      (data) => _asMap(data),
    );
  }

  Future<String> purgeLogs() {
    return _request(
      () => _dio.post<dynamic>('/settings/purge-logs'),
      (data) => _asMap(data)['message'] as String? ?? '삭제했습니다.',
    );
  }
}

/// 로그인/가입 결과.
class AuthResult {
  const AuthResult({
    required this.userId,
    required this.email,
    required this.displayName,
    required this.accessToken,
    required this.refreshToken,
  });

  final String userId;
  final String email;
  final String displayName;
  final String accessToken;
  final String refreshToken;

  factory AuthResult.fromJson(Map<String, dynamic> json) {
    final user = json['user'] as Map<String, dynamic>;
    final tokens = json['tokens'] as Map<String, dynamic>;
    return AuthResult(
      userId: user['id'] as String,
      email: user['email'] as String,
      displayName: user['display_name'] as String,
      accessToken: tokens['access_token'] as String,
      refreshToken: tokens['refresh_token'] as String,
    );
  }
}
