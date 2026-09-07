import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:torch_light/torch_light.dart';
import 'package:vibration/vibration.dart';

import '../../core/providers.dart';
import '../../data/api_client.dart';
import '../../data/audio/alarm_detector.dart';
import '../../data/audio/audio_capture.dart';
import '../../domain/entities/conversation.dart';
import '../../domain/entities/emotion_tone.dart';

/// 경보 감지 → 사용자에게 알리기 → 서버 기록.
///
/// 사용자가 소리를 듣지 못한다는 전제에서, 알림은 **시각 + 촉각** 두 경로로만
/// 전달된다. 하나가 막혀도(주머니 안에 있어 화면이 안 보임 / 진동을 끔) 다른
/// 하나가 도달해야 한다.
///
/// 서버 기록은 실패해도 무시한다. 경보를 알리는 것이 먼저고, 기록은 나중이다.
class AlertService extends StateNotifier<AlertState> {
  AlertService({
    required AlarmDetector detector,
    required AudioCapture capture,
    required ApiClient api,
  })  : _detector = detector,
        _capture = capture,
        _api = api,
        super(const AlertState());

  final AlarmDetector _detector;
  final AudioCapture _capture;
  final ApiClient _api;

  final _notifications = FlutterLocalNotificationsPlugin();

  StreamSubscription<AlarmDetection>? _subscription;
  Timer? _vibrationLoop;
  Timer? _torchLoop;
  Timer? _testTimeout;

  static const _consumerId = 'alarm-detector';
  static const _channelId = 'hearo_emergency';

  /// 알림 테스트 전용 id. `AlertType.index` 와 겹치지 않는 값이어야 한다.
  static const _testNotificationId = 9001;

  /// 서버에 못 올린 경보들. 온라인이 되면 한꺼번에 올린다.
  final List<AlarmDetection> _pendingUploads = [];

  bool _notificationsReady = false;

  // ================================================================ 수명주기

  Future<void> initialize() async {
    await _setupNotifications();
    final loaded = await _detector.load();
    if (!loaded) {
      state = state.copyWith(
        monitoring: false,
        errorMessage: _detector.loadError ??
            '경보 감지 모델을 불러오지 못했습니다. 경보 알림이 동작하지 않습니다.',
      );
    }
  }

  Future<void> _setupNotifications() async {
    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      // 소리 권한은 요청하지 않는다 — 이 앱의 사용자에게 의미가 없고,
      // 불필요한 권한 요청은 신뢰를 깎는다.
      requestSoundPermission: false,
      requestCriticalPermission: true,
    );

    try {
      await _notifications.initialize(
        const InitializationSettings(
          android: androidSettings,
          iOS: iosSettings,
        ),
      );

      // Android 는 채널을 미리 만들어야 중요도가 적용된다.
      final android = _notifications.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await android?.createNotificationChannel(
        const AndroidNotificationChannel(
          _channelId,
          '위급 상황 알림',
          description: '화재경보, 사이렌 등 위급한 소리를 감지했을 때 알립니다.',
          importance: Importance.max,
          // 소리는 쓰지 않는다. 진동과 화면이 전부다.
          playSound: false,
          enableVibration: true,
          enableLights: true,
        ),
      );
      await android?.requestNotificationsPermission();
      _notificationsReady = true;
    } on Object catch (error) {
      debugPrint('[AlertService] 알림 초기화 실패: $error');
      _notificationsReady = false;
    }
  }

  /// 경보 감시 시작. 자막을 켜지 않아도 독립적으로 돌 수 있다.
  Future<void> startMonitoring({AppSettings? settings}) async {
    if (state.monitoring) return;
    if (settings != null && !settings.alertsEnabled) return;

    if (!_detector.isReady && !await _detector.load()) {
      state = state.copyWith(
        errorMessage: _detector.loadError ?? '경보 감지를 시작할 수 없습니다.',
      );
      return;
    }

    if (settings != null) {
      _detector.sensitivity = settings.alertSensitivity;
    }

    try {
      await _capture.start(_consumerId);
    } on MicrophonePermissionDenied {
      state = state.copyWith(errorMessage: '경보 감지를 하려면 마이크 권한이 필요합니다.');
      return;
    }

    _detector.attach(_capture.alarmStream);
    _subscription = _detector.detections.listen(_onDetection);

    state = state.copyWith(monitoring: true, clearError: true);
  }

  Future<void> stopMonitoring() async {
    await _subscription?.cancel();
    _subscription = null;
    await _detector.detach();
    await _capture.stop(_consumerId);
    _stopFeedback();
    state = state.copyWith(monitoring: false);
  }

  void updateSensitivity(double sensitivity) {
    _detector.sensitivity = sensitivity;
  }

  // ================================================================ 알림 테스트

  /// 사용자가 설정에서 실행하는 알림 테스트.
  ///
  /// 이 앱에서 진동·손전등·전체화면은 **위험을 전달하는 유일한 통로**다. 그런데
  /// 실제로 동작하는지는 화재경보가 울릴 때 처음 알게 되는데, 그때는 이미 늦다.
  /// 게다가 못 울리는 이유는 대개 기기 쪽이다 — 진동 모터가 없는 태블릿,
  /// 손전등 권한 거부, 알림 채널 차단, 절전 모드. 앱은 이걸 미리 알 수 없다.
  ///
  /// 그래서 사용자가 직접 한 번 울려 보고 확인할 수 있어야 한다.
  ///
  /// **감지 모델은 지나가지 않는다.** 마이크 → 모델 → 디바운스 경로는
  /// `integration_test/alarm_model_test.dart` 가 실기기에서 실제 음원으로
  /// 검증한다. 여기서 확인하는 것은 "감지된 다음에 무슨 일이 일어나는가"다.
  Future<void> runSelfTest(AlertType type) async {
    // 진짜 경보가 떠 있으면 테스트가 덮지 않는다.
    if (state.active != null) return;

    final detection = AlarmDetection(
      type: type,
      confidence: 0.93,
      rawClass: 'self_test',
      detectedAt: DateTime.now(),
      consecutiveFrames: 0,
      isTest: true,
    );

    state = state.copyWith(active: detection);
    await _fireFeedback(detection);

    // 서버에 기록하지 않는다 — 경보 이력과 오탐 통계가 오염된다.

    // 테스트가 무한정 이어지지 않게 한다. 심각도 3은 확인할 때까지 진동을
    // 반복하는데(_vibrate), 진짜 경보라면 그게 맞지만 테스트는 아니다.
    _testTimeout?.cancel();
    _testTimeout = Timer(const Duration(seconds: 20), () {
      if (state.active?.isTest ?? false) unawaited(acknowledge());
    });
  }

  // ================================================================ 감지 처리

  Future<void> _onDetection(AlarmDetection detection) async {
    // 이미 다른 경보가 화면에 떠 있으면, 더 심각한 것만 덮어쓴다.
    final active = state.active;
    if (active != null && active.type.severity >= detection.type.severity) {
      return;
    }

    state = state.copyWith(active: detection);

    // 알리는 것이 최우선. 서버 기록은 그 다음.
    await _fireFeedback(detection);
    unawaited(_report(detection));
  }

  Future<void> _fireFeedback(AlarmDetection detection) async {
    final settings = state.settings;
    final severity = detection.type.severity;

    // ---- 진동 ----
    if (settings?.alertVibrationEnabled ?? true) {
      unawaited(_vibrate(severity));
    }

    // ---- 손전등 점멸 ----
    // 화면을 보고 있지 않을 때(주머니, 책상 위 엎어둠) 주변 벽에 빛이 번쩍여
    // 시야 주변으로 들어온다. 기본은 꺼져 있고, 켠 사용자에게만 동작한다.
    if ((settings?.alertTorchStrobeEnabled ?? false) && severity >= 3) {
      unawaited(_strobeTorch());
    }

    // ---- 시스템 알림 ----
    // 앱이 백그라운드일 때의 유일한 통로.
    if (_notificationsReady) {
      unawaited(_notify(detection));
    }
  }

  Future<void> _vibrate(int severity) async {
    try {
      // 플러그인 버전에 따라 bool 또는 bool? 를 돌려준다. 둘 다 안전한 비교.
      final hasVibrator = await Vibration.hasVibrator();
      if (hasVibrator != true) return;

      // 심각도별로 패턴을 다르게 준다. 사용자가 화면을 안 봐도 진동만으로
      // "화재인지 사이렌인지" 구분할 수 있어야 한다.
      final pattern = switch (severity) {
        // 화재/민방위 — 길고 강한 연속 패턴
        3 => [0, 600, 200, 600, 200, 600, 200, 900],
        // 긴급차량 — 짧게 세 번
        2 => [0, 250, 150, 250, 150, 250],
        // 일반 경보 — 두 번
        _ => [0, 200, 200, 200],
      };

      _vibrationLoop?.cancel();
      await Vibration.vibrate(pattern: pattern, intensities: []);

      // 심각한 경보는 사용자가 확인할 때까지 반복한다.
      if (severity >= 3) {
        _vibrationLoop = Timer.periodic(
          const Duration(seconds: 4),
          (_) => Vibration.vibrate(pattern: pattern, intensities: []),
        );
      }
    } on Object catch (error) {
      debugPrint('[AlertService] 진동 실패: $error');
      // 진동이 안 되면 최소한 햅틱이라도.
      unawaited(HapticFeedback.heavyImpact());
    }
  }

  Future<void> _strobeTorch() async {
    try {
      if (!await TorchLight.isTorchAvailable()) return;

      var on = false;
      _torchLoop?.cancel();
      _torchLoop = Timer.periodic(const Duration(milliseconds: 350), (_) async {
        on = !on;
        try {
          if (on) {
            await TorchLight.enableTorch();
          } else {
            await TorchLight.disableTorch();
          }
        } on Object {
          _torchLoop?.cancel();
        }
      });
    } on Object catch (error) {
      debugPrint('[AlertService] 손전등 사용 불가: $error');
    }
  }

  Future<void> _notify(AlarmDetection detection) async {
    // 테스트는 알림 id 를 따로 쓴다. 같은 id 를 쓰면 아직 남아 있는 진짜 경보
    // 알림을 테스트가 조용히 덮어쓴다.
    final id = detection.isTest ? _testNotificationId : detection.type.index;

    final title = detection.isTest
        ? '🔔 알림 테스트 — ${detection.type.labelKo}'
        : '⚠️ ${detection.type.labelKo} 감지';
    final body = detection.isTest
        ? '실제 경보가 아닙니다. 진동·화면·손전등이 제대로 동작하는지 확인하세요.'
        : detection.type.guidance;

    try {
      await _notifications.show(
        id,
        title,
        body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            '위급 상황 알림',
            importance: Importance.max,
            priority: Priority.max,
            category: AndroidNotificationCategory.alarm,
            playSound: false,
            enableVibration: true,
            // 잠금화면에도 전체 내용을 보여준다 — 가려지면 의미가 없다.
            visibility: NotificationVisibility.public,
            fullScreenIntent: detection.type.severity >= 3,
            styleInformation: BigTextStyleInformation(
              body,
              contentTitle: title,
            ),
            color: const Color(0xFFD32029),
            colorized: true,
            // 테스트 알림은 사용자가 직접 지울 수 있어야 한다. 진짜 경보만
            // 확인 전까지 남는다.
            ongoing: !detection.isTest && detection.type.severity >= 3,
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: false,
            interruptionLevel: detection.type.severity >= 3
                ? InterruptionLevel.critical
                : InterruptionLevel.timeSensitive,
          ),
        ),
      );
    } on Object catch (error) {
      debugPrint('[AlertService] 알림 표시 실패: $error');
    }
  }

  void _stopFeedback() {
    _vibrationLoop?.cancel();
    _vibrationLoop = null;
    _torchLoop?.cancel();
    _torchLoop = null;
    _testTimeout?.cancel();
    _testTimeout = null;
    unawaited(Vibration.cancel().catchError((_) {}));
    unawaited(TorchLight.disableTorch().catchError((_) {}));
    // 테스트 알림은 화면을 닫을 때 같이 치운다. 진짜 경보 알림은 사용자가
    // 나중에 다시 확인할 수 있게 그대로 둔다.
    unawaited(_notifications.cancel(_testNotificationId).catchError((_) {}));
  }

  // ================================================================ 서버 기록

  Future<void> _report(AlarmDetection detection, {String? sessionId}) async {
    try {
      final record = await _api.recordAlert(
        type: detection.type,
        confidence: detection.confidence,
        detectedAt: detection.detectedAt,
        rawClass: detection.rawClass,
        consecutiveFrames: detection.consecutiveFrames,
        sessionId: sessionId,
      );
      if (record != null) {
        state = state.copyWith(lastRecordId: record.id);
      }
    } on Object catch (error) {
      // 오프라인이면 큐에 넣어 두었다가 나중에 올린다.
      debugPrint('[AlertService] 경보 기록 실패, 큐에 보관: $error');
      _pendingUploads.add(detection);
    }
  }

  /// 온라인 복귀 시 밀린 경보를 올린다.
  Future<void> flushPendingUploads() async {
    if (_pendingUploads.isEmpty) return;

    final batch = _pendingUploads
        .map((d) => {
              'alert_type': d.type.wireValue,
              'confidence': d.confidence,
              'detected_at': d.detectedAt.toUtc().toIso8601String(),
              'raw_class': d.rawClass,
              'consecutive_frames': d.consecutiveFrames,
            })
        .toList(growable: false);

    try {
      await _api.recordAlertsBatch(batch);
      _pendingUploads.clear();
    } on Object catch (error) {
      debugPrint('[AlertService] 큐 업로드 실패: $error');
    }
  }

  // ================================================================ 사용자 조작

  /// 사용자가 경고를 확인했다. 진동·점멸을 멈추고 화면을 닫는다.
  Future<void> acknowledge({bool falsePositive = false}) async {
    _stopFeedback();

    final recordId = state.lastRecordId;
    state = state.copyWith(clearActive: true, clearRecordId: true);

    if (recordId == null) return;
    try {
      await _api.updateAlert(
        recordId,
        acknowledged: true,
        isFalsePositive: falsePositive ? true : null,
      );
    } on Object catch (error) {
      debugPrint('[AlertService] 경보 확인 처리 실패: $error');
    }
  }

  void applySettings(AppSettings settings) {
    state = state.copyWith(settings: settings);
    _detector.sensitivity = settings.alertSensitivity;

    if (!settings.alertsEnabled && state.monitoring) {
      unawaited(stopMonitoring());
    }
  }

  @override
  void dispose() {
    _stopFeedback();
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}

@immutable
class AlertState {
  const AlertState({
    this.monitoring = false,
    this.active,
    this.errorMessage,
    this.settings,
    this.lastRecordId,
  });

  /// 감시 중인지
  final bool monitoring;

  /// 지금 화면에 띄워야 할 경보. null 이면 평상시.
  final AlarmDetection? active;

  final String? errorMessage;
  final AppSettings? settings;

  /// 서버에 기록된 id. 확인 처리에 쓴다.
  final String? lastRecordId;

  AlertState copyWith({
    bool? monitoring,
    AlarmDetection? active,
    bool clearActive = false,
    String? errorMessage,
    bool clearError = false,
    AppSettings? settings,
    String? lastRecordId,
    bool clearRecordId = false,
  }) {
    return AlertState(
      monitoring: monitoring ?? this.monitoring,
      active: clearActive ? null : (active ?? this.active),
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      settings: settings ?? this.settings,
      lastRecordId:
          clearRecordId ? null : (lastRecordId ?? this.lastRecordId),
    );
  }
}

final alertServiceProvider =
    StateNotifierProvider<AlertService, AlertState>((ref) {
  final service = AlertService(
    detector: ref.watch(alarmDetectorProvider),
    capture: ref.watch(audioCaptureProvider),
    api: ref.watch(apiClientProvider),
  );

  // 설정이 바뀌면 즉시 반영한다 (민감도, 진동 on/off 등).
  ref.listen<AsyncValue<AppSettings>>(settingsProvider, (previous, next) {
    final settings = next.valueOrNull;
    if (settings != null) service.applySettings(settings);
  });

  return service;
});
