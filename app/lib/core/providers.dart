import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/api_client.dart';
import '../data/audio/alarm_detector.dart';
import '../data/audio/audio_capture.dart';
import '../data/token_store.dart';
import '../domain/entities/conversation.dart';

/// 앱 전역 의존성.
///
/// 마이크와 ONNX Runtime 세션처럼 기기 자원을 잡는 객체는 반드시 단일
/// 인스턴스여야 한다 (`keepAlive` 성격). Riverpod 의 자동 폐기에 맡기면
/// 화면 전환마다 마이크가 열렸다 닫혀 오디오가 끊긴다.

final tokenStoreProvider = Provider<TokenStore>((ref) {
  final store = TokenStore();
  ref.onDispose(store.dispose);
  return store;
});

final apiClientProvider = Provider<ApiClient>((ref) {
  return ApiClient(tokenStore: ref.watch(tokenStoreProvider));
});

final audioCaptureProvider = Provider<AudioCapture>((ref) {
  final capture = AudioCapture();
  ref.onDispose(capture.dispose);
  return capture;
});

final alarmDetectorProvider = Provider<AlarmDetector>((ref) {
  final detector = AlarmDetector();
  ref.onDispose(detector.dispose);
  return detector;
});

/// 로그인 상태. 라우터의 리다이렉트 판단에 쓴다.
final authStateProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  return AuthNotifier(
    tokenStore: ref.watch(tokenStoreProvider),
    api: ref.watch(apiClientProvider),
  );
});

@immutable
class AuthState {
  const AuthState({
    required this.status,
    this.displayName,
    this.email,
    this.errorMessage,
  });

  final AuthStatus status;
  final String? displayName;
  final String? email;
  final String? errorMessage;

  bool get isAuthenticated => status == AuthStatus.authenticated;

  const AuthState.unknown()
      : status = AuthStatus.unknown,
        displayName = null,
        email = null,
        errorMessage = null;
}

enum AuthStatus { unknown, authenticated, unauthenticated, busy }

class AuthNotifier extends StateNotifier<AuthState> {
  AuthNotifier({required TokenStore tokenStore, required ApiClient api})
      : _tokens = tokenStore,
        _api = api,
        super(const AuthState.unknown()) {
    // 토큰이 완전히 만료되면 API 클라이언트가 알려준다.
    _api.onAuthenticationLost = () {
      state = const AuthState(status: AuthStatus.unauthenticated);
    };
    _restore();
  }

  final TokenStore _tokens;
  final ApiClient _api;

  Future<void> _restore() async {
    await _tokens.load();
    state = AuthState(
      status: _tokens.isAuthenticated
          ? AuthStatus.authenticated
          : AuthStatus.unauthenticated,
    );
  }

  Future<void> login({required String email, required String password}) async {
    state = const AuthState(status: AuthStatus.busy);
    final result = await _api.login(email: email, password: password);
    await _tokens.save(
      accessToken: result.accessToken,
      refreshToken: result.refreshToken,
    );
    state = AuthState(
      status: AuthStatus.authenticated,
      displayName: result.displayName,
      email: result.email,
    );
  }

  Future<void> register({
    required String email,
    required String password,
    required String displayName,
  }) async {
    state = const AuthState(status: AuthStatus.busy);
    final result = await _api.register(
      email: email,
      password: password,
      displayName: displayName,
    );
    await _tokens.save(
      accessToken: result.accessToken,
      refreshToken: result.refreshToken,
    );
    state = AuthState(
      status: AuthStatus.authenticated,
      displayName: result.displayName,
      email: result.email,
    );
  }

  Future<void> logout() async {
    await _api.logout();
    await _tokens.clear();
    state = const AuthState(status: AuthStatus.unauthenticated);
  }

  void markUnauthenticated() {
    state = const AuthState(status: AuthStatus.unauthenticated);
  }
}

/// 사용자 설정. 서버가 원본이고, 로컬은 캐시다.
final settingsProvider =
    StateNotifierProvider<SettingsNotifier, AsyncValue<AppSettings>>((ref) {
  return SettingsNotifier(ref.watch(apiClientProvider), ref);
});

class SettingsNotifier extends StateNotifier<AsyncValue<AppSettings>> {
  SettingsNotifier(this._api, this._ref) : super(const AsyncValue.loading()) {
    // 로그인 상태가 되면 불러온다.
    _ref.listen<AuthState>(authStateProvider, (previous, next) {
      if (next.isAuthenticated && previous?.isAuthenticated != true) {
        load();
      }
    });
  }

  final ApiClient _api;
  final Ref _ref;

  Future<void> load() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(_api.getSettings);
  }

  /// 설정을 바꾼다. 화면이 즉시 반응하도록 낙관적으로 먼저 반영하고,
  /// 서버 저장이 실패하면 되돌린다.
  Future<void> update(
    AppSettings Function(AppSettings current) mutate,
    Map<String, dynamic> payload,
  ) async {
    final current = state.valueOrNull;
    if (current == null) return;

    final optimistic = mutate(current);
    state = AsyncValue.data(optimistic);

    try {
      final saved = await _api.updateSettings(payload);
      state = AsyncValue.data(saved);
    } on Object {
      state = AsyncValue.data(current);
      rethrow;
    }
  }
}

/// 시스템 접근성 설정 — "동작 줄이기"가 켜져 있으면 감정 애니메이션을 끈다.
final reduceMotionProvider = Provider<bool>((ref) {
  final views = WidgetsBinding.instance.platformDispatcher.views;
  if (views.isEmpty) return false;
  return MediaQueryData.fromView(views.first).disableAnimations;
});

/// 말투 표시가 추정이라는 안내를 사용자가 이미 봤는지.
///
/// 자막 옆의 "화난 말투로 들림" 은 배지 하나짜리 표시라, 처음 보는 사람은 그게
/// 측정값인지 짐작인지 알 수 없다. 그래서 첫 세션에는 화면 위에 한 번 명시하고,
/// 사용자가 닫으면 다시 띄우지 않는다 — 매번 띄우면 읽지 않고 넘기게 되고,
/// 그러면 안내가 아니라 장식이 된다.
///
/// 서버가 아니라 기기에 저장한다. 계정이 아니라 "이 화면을 본 적 있는 사람"
/// 에 대한 사실이고, 로그인 전에도 체험 모드로 자막 화면을 볼 수 있다.
final toneDisclaimerProvider =
    AsyncNotifierProvider<ToneDisclaimerNotifier, bool>(
  ToneDisclaimerNotifier.new,
);

class ToneDisclaimerNotifier extends AsyncNotifier<bool> {
  // 문구를 크게 고치면 v2 로 올려 다시 보여준다.
  static const _key = 'tone_disclaimer_dismissed_v1';

  @override
  Future<bool> build() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_key) ?? false;
  }

  Future<void> dismiss() async {
    // 화면에서 먼저 치운다. 디스크 쓰기를 기다리면 탭이 씹힌 것처럼 느껴진다.
    state = const AsyncValue.data(true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, true);
  }
}

/// 미확인 경보 개수 (앱 배지).
final unacknowledgedAlertCountProvider = FutureProvider<int>((ref) async {
  final auth = ref.watch(authStateProvider);
  if (!auth.isAuthenticated) return 0;
  return ref.watch(apiClientProvider).unacknowledgedAlertCount();
});
