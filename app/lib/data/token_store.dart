import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 인증 토큰 보관소.
///
/// Keychain(iOS) / EncryptedSharedPreferences(Android) 에 넣는다.
/// SharedPreferences 평문에 두면 루팅된 기기나 백업 파일에서 그대로 읽힌다 —
/// 이 앱은 사용자의 사적인 대화 전문을 다루므로 그 위험을 감수할 수 없다.
class TokenStore {
  TokenStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
            );

  final FlutterSecureStorage _storage;

  static const _accessKey = 'hearo.access_token';
  static const _refreshKey = 'hearo.refresh_token';

  // 매번 Keychain 을 때리면 느리다. 메모리에 캐시하고 쓰기 시 동기화한다.
  String? _cachedAccess;
  String? _cachedRefresh;
  bool _loaded = false;

  final _authStateController = StreamController<bool>.broadcast();

  /// 로그인 여부 변화 스트림. 라우터가 이걸 구독해 화면을 전환한다.
  Stream<bool> get authStateChanges => _authStateController.stream;

  Future<void> load() async {
    if (_loaded) return;
    try {
      final all = await _storage.readAll();
      _cachedAccess = all[_accessKey];
      _cachedRefresh = all[_refreshKey];
    } on Exception {
      // 기기 보안 저장소 접근 실패(예: 사용자가 기기 잠금을 해제하지 않음).
      // 로그아웃 상태로 시작하게 두는 편이 안전하다.
      _cachedAccess = null;
      _cachedRefresh = null;
    }
    _loaded = true;
  }

  String? get accessToken => _cachedAccess;
  String? get refreshToken => _cachedRefresh;
  bool get isAuthenticated => _cachedAccess != null;

  Future<void> save({
    required String accessToken,
    required String refreshToken,
  }) async {
    _cachedAccess = accessToken;
    _cachedRefresh = refreshToken;
    _loaded = true;
    await Future.wait([
      _storage.write(key: _accessKey, value: accessToken),
      _storage.write(key: _refreshKey, value: refreshToken),
    ]);
    _authStateController.add(true);
  }

  Future<void> clear() async {
    _cachedAccess = null;
    _cachedRefresh = null;
    _loaded = true;
    await Future.wait([
      _storage.delete(key: _accessKey),
      _storage.delete(key: _refreshKey),
    ]);
    _authStateController.add(false);
  }

  void dispose() => _authStateController.close();
}
