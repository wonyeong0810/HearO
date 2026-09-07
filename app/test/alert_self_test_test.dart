import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearo/data/api_client.dart';
import 'package:hearo/data/audio/alarm_detector.dart';
import 'package:hearo/data/audio/audio_capture.dart';
import 'package:hearo/data/token_store.dart';
import 'package:hearo/domain/entities/emotion_tone.dart';
import 'package:hearo/features/alert/alert_overlay.dart';
import 'package:hearo/features/alert/alert_service.dart';

/// 알림 테스트(설정 → 알림 테스트) 검증.
///
/// 이 기능이 위험해질 수 있는 지점은 하나다 — **테스트가 진짜 경보처럼 보이는
/// 것.** 화면에는 `화재경보` 가 46pt 로 뜨고 그 아래에 "즉시 밖으로 대피하세요"
/// 가 붙는다. 테스트 표시가 약하면 옆 사람이 진짜로 받아들이고, 서버에 올라가면
/// 경보 이력과 오탐 통계가 오염된다.
///
/// 그래서 여기서 확인하는 것은 "테스트가 동작하는가"보다 **"테스트가 테스트로
/// 보이는가"** 쪽에 가깝다.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // AudioRecorder 는 생성자에서 네이티브 인스턴스를 만든다. 호스트에는 그
    // 구현이 없어서, 막아 두지 않으면 발판을 세우다가 깨진다. 이 테스트는
    // 마이크를 쓰지 않으므로 빈 응답이면 충분하다.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.llfbandit.record/messages'),
      (call) async => null,
    );
  });

  group('AlertService.runSelfTest', () {
    late _Harness h;

    setUp(() => h = _Harness());
    tearDown(() => h.dispose());

    test('테스트 표식이 붙은 경보를 화면에 올린다', () async {
      await h.service.runSelfTest(AlertType.fireAlarm);

      final active = h.state.active;
      expect(active, isNotNull);
      expect(active!.type, AlertType.fireAlarm);
      expect(active.isTest, isTrue);
      // 오탐 분석에서 테스트를 골라낼 수 있게 원천을 남긴다.
      expect(active.rawClass, 'self_test');
    });

    test('서버로 아무것도 보내지 않는다', () async {
      // 테스트가 `POST /alerts` 로 올라가면 경보 이력에 있지도 않았던 화재가
      // 남고, 오탐 통계(4-5절의 근거)가 오염된다.
      await h.service.runSelfTest(AlertType.civilDefenseSiren);
      await pumpEventQueue();

      expect(h.requests, isEmpty);
      expect(h.state.lastRecordId, isNull);
    });

    test('이미 경보가 떠 있으면 덮지 않는다', () async {
      // 진짜 화재경보가 떠 있는데 테스트가 그 위를 덮으면, 사용자는 진짜
      // 경보를 테스트로 알고 닫는다.
      await h.service.runSelfTest(AlertType.fireAlarm);
      final first = h.state.active;

      await h.service.runSelfTest(AlertType.generalAlarm);

      expect(h.state.active, same(first));
    });

    test('확인하면 화면이 닫히고, 확인 처리도 서버로 가지 않는다', () async {
      await h.service.runSelfTest(AlertType.emergencyVehicle);
      await h.service.acknowledge();
      await pumpEventQueue();

      expect(h.state.active, isNull);
      expect(h.requests, isEmpty);
    });
  });

  group('경고 화면 — 테스트임을 드러낸다', () {
    AlarmDetection detection({required bool isTest}) => AlarmDetection(
          type: AlertType.fireAlarm,
          confidence: 0.93,
          rawClass: isTest ? 'self_test' : 'fire_alarm',
          detectedAt: DateTime(2026, 8, 29, 14, 3, 7),
          consecutiveFrames: isTest ? 0 : 6,
          isTest: isTest,
        );

    Future<void> pump(WidgetTester tester, {required bool isTest}) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: AlertOverlay(detection: detection(isTest: isTest)),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('화면이 진짜 경보와 똑같이 보인다', (tester) async {
      await pump(tester, isTest: true);

      expect(find.text('위급 상황'), findsOneWidget);
      expect(find.text('확인했습니다'), findsOneWidget);
      expect(find.textContaining('테스트'), findsNothing);
    });

    testWidgets('진짜 경보는 신뢰도를 그대로 적는다', (tester) async {
      await pump(tester, isTest: false);

      expect(find.textContaining('감지 신뢰도 93%'), findsOneWidget);
    });

    testWidgets('테스트에는 "잘못된 감지였어요"가 없다', (tester) async {
      // 사용자가 직접 띄운 화면이라 오탐일 수가 없고, 눌러도 서버에 올릴
      // 기록이 없다. 남겨 두면 누른 사람은 신고했다고 믿는다.
      await pump(tester, isTest: true);

      expect(find.text('잘못된 감지였어요'), findsNothing);
      expect(find.text('확인했습니다'), findsOneWidget);
    });

    testWidgets('진짜 경보에는 오탐 신고와 확인 버튼이 그대로 있다', (tester) async {
      await pump(tester, isTest: false);

      expect(find.text('확인했습니다'), findsOneWidget);
      expect(find.text('잘못된 감지였어요'), findsOneWidget);
    });

    testWidgets('테스트에도 행동 지침은 그대로 보여준다', (tester) async {
      // 지침이 읽히는지까지가 확인 대상이다. 여기서 빼 버리면 정작 진짜
      // 경보에서 처음 보게 된다.
      await pump(tester, isTest: true);

      expect(find.textContaining('즉시 밖으로 대피'), findsOneWidget);
    });
  });
}

/// 플러그인 없이 [AlertService] 하나만 세워 두는 발판.
///
/// Riverpod 그래프를 통째로 만들면 인증·보안저장소까지 딸려 와서, 정작 보려는
/// 것과 상관없는 곳에서 깨진다. 여기서는 서비스가 실제로 의존하는 세 개만 준다.
class _Harness {
  _Harness() {
    final dio = Dio()..httpClientAdapter = _RecordingAdapter(requests);
    service = AlertService(
      detector: AlarmDetector(),
      capture: AudioCapture(),
      api: ApiClient(tokenStore: TokenStore(), dio: dio),
    );
    _removeListener = service.addListener((s) => state = s);
  }

  late final AlertService service;
  late final RemoveListener _removeListener;

  /// 서비스가 실제로 보낸 HTTP 요청. 알림 테스트에서는 비어 있어야 한다.
  final requests = <String>[];

  /// `StateNotifier.state` 는 protected 라 리스너로 받아 둔다.
  AlertState state = const AlertState();

  void dispose() {
    _removeListener();
    service.dispose();
  }
}

class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.calls);

  final List<String> calls;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls.add('${options.method} ${options.path}');
    return ResponseBody.fromString('{}', 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}
