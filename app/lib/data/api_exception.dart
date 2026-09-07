import 'package:dio/dio.dart';

/// 백엔드가 돌려주는 표준 에러 형식을 앱 예외로 옮긴 것.
///
/// 백엔드 계약:
///   {"error": {"code": "SESSION_NOT_FOUND", "message": "...", "details": {...}}}
///
/// [code] 로 분기하고, [message] 는 그대로 사용자에게 보여줄 수 있는 한국어다.
class ApiException implements Exception {
  const ApiException({
    required this.code,
    required this.message,
    this.statusCode,
    this.details,
  });

  final String code;
  final String message;
  final int? statusCode;
  final Map<String, dynamic>? details;

  /// 재로그인이 필요한 상황인가?
  bool get requiresReauth =>
      code == 'TOKEN_EXPIRED' ||
      code == 'INVALID_TOKEN' ||
      code == 'UNAUTHENTICATED' ||
      statusCode == 401;

  /// 잠시 뒤 재시도하면 될 상황인가?
  bool get isTransient =>
      code == 'RATE_LIMITED' ||
      code == 'NETWORK_ERROR' ||
      code == 'TIMEOUT' ||
      (statusCode != null && statusCode! >= 500);

  /// 네트워크 자체가 안 되는 상황인가? (오프라인 안내 문구를 띄울지 판단)
  bool get isOffline => code == 'NETWORK_ERROR';

  factory ApiException.fromDioException(DioException error) {
    final response = error.response;

    // 서버가 우리 형식으로 답한 경우
    final data = response?.data;
    if (data is Map<String, dynamic>) {
      final payload = data['error'];
      if (payload is Map<String, dynamic>) {
        return ApiException(
          code: payload['code'] as String? ?? 'UNKNOWN',
          message: payload['message'] as String? ?? '알 수 없는 오류가 발생했습니다.',
          statusCode: response?.statusCode,
          details: payload['details'] as Map<String, dynamic>?,
        );
      }
    }

    // 서버에 닿지도 못한 경우
    final (code, message) = switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout =>
        ('TIMEOUT', '서버 응답이 지연되고 있습니다. 잠시 후 다시 시도해 주세요.'),
      DioExceptionType.connectionError =>
        ('NETWORK_ERROR', '네트워크에 연결할 수 없습니다. 연결 상태를 확인해 주세요.'),
      DioExceptionType.badCertificate =>
        ('BAD_CERTIFICATE', '서버 인증서를 확인할 수 없습니다.'),
      DioExceptionType.cancel => ('CANCELLED', '요청이 취소되었습니다.'),
      _ => ('UNKNOWN', '알 수 없는 오류가 발생했습니다.'),
    };

    return ApiException(
      code: code,
      message: message,
      statusCode: response?.statusCode,
    );
  }

  const ApiException.offline()
      : code = 'NETWORK_ERROR',
        message = '네트워크에 연결할 수 없습니다. 연결 상태를 확인해 주세요.',
        statusCode = null,
        details = null;

  /// 폼 검증 실패 시 필드별 메시지. 없으면 빈 맵.
  Map<String, String> get fieldErrors {
    final fields = details?['fields'];
    if (fields is! List) return const {};
    return {
      for (final item in fields)
        if (item is Map && item['field'] is String)
          item['field'] as String: item['reason']?.toString() ?? '올바르지 않습니다.',
    };
  }

  @override
  String toString() => 'ApiException($code): $message';
}
