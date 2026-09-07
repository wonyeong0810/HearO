import 'package:flutter_test/flutter_test.dart';
import 'package:hearo/data/audio/alarm_detector.dart';
import 'package:hearo/domain/entities/emotion_tone.dart';

/// 경보 발령 규칙 테스트.
///
/// 여기서 지키려는 것은 두 가지다.
///   1. 모델 클래스 순서가 바뀌면 **조용히 틀리는 대신 로드가 실패한다**
///   2. 연속 창 수 정책이 측정한 값(심각도 3 은 6창, 나머지 4창) 그대로다
///
/// 추론 자체는 ONNX 세션이 필요해 단위 테스트에서 못 돌린다. 대신 확률
/// 벡터를 직접 밀어 넣어 디바운스만 검증한다 — 실제로 오탐을 막는 부분이
/// 모델이 아니라 이쪽이므로 여기가 더 중요하다.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 모델의 클래스 순서. metadata.json 과 같아야 한다.
  const background = 0;
  const fireAlarm = 1;
  const generalAlarm = 4;

  /// [index] 에 [confidence] 를 몰아준 확률 벡터.
  List<double> probs(int index, double confidence) {
    final rest = (1.0 - confidence) / 4;
    return [for (var i = 0; i < 5; i++) i == index ? confidence : rest];
  }

  late AlarmDetector detector;
  late List<AlarmDetection> fired;

  setUp(() async {
    detector = AlarmDetector();
    await detector.loadMetadataOnly();
    fired = [];
    detector.detections.listen(fired.add);
  });

  tearDown(() => detector.dispose());

  /// 스트림은 비동기라 방출이 도착할 틈을 줘야 한다.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('클래스 매핑', () {
    test('metadata.json 의 클래스를 이름으로 읽는다', () async {
      // 5클래스 모델이고 순서가 위 상수와 맞아야 한다.
      detector.evaluateProbabilities(probs(fireAlarm, 0.9));
      detector.evaluateProbabilities(probs(fireAlarm, 0.9));
      detector.evaluateProbabilities(probs(fireAlarm, 0.9));
      detector.evaluateProbabilities(probs(fireAlarm, 0.9));
      detector.evaluateProbabilities(probs(fireAlarm, 0.9));
      detector.evaluateProbabilities(probs(fireAlarm, 0.9));
      await settle();

      expect(fired, hasLength(1));
      expect(fired.single.type, AlertType.fireAlarm);
      expect(fired.single.rawClass, 'fire_alarm');
    });
  });

  group('연속 창 요구', () {
    test('심각도 3 은 6창을 요구한다 — 5창까지는 울리지 않는다', () async {
      for (var i = 0; i < 5; i++) {
        detector.evaluateProbabilities(probs(fireAlarm, 0.9));
      }
      await settle();
      expect(fired, isEmpty);

      detector.evaluateProbabilities(probs(fireAlarm, 0.9));
      await settle();
      expect(fired, hasLength(1));
      expect(fired.single.consecutiveFrames, 6);
    });

    test('심각도 1 은 4창이면 울린다', () async {
      for (var i = 0; i < 3; i++) {
        detector.evaluateProbabilities(probs(generalAlarm, 0.9));
      }
      await settle();
      expect(fired, isEmpty);

      detector.evaluateProbabilities(probs(generalAlarm, 0.9));
      await settle();
      expect(fired, hasLength(1));
      expect(fired.single.type, AlertType.generalAlarm);
    });

    test('배경이 한 번 끼면 연속이 끊긴다', () async {
      for (var i = 0; i < 5; i++) {
        detector.evaluateProbabilities(probs(fireAlarm, 0.9));
      }
      detector.evaluateProbabilities(probs(background, 0.9));
      for (var i = 0; i < 5; i++) {
        detector.evaluateProbabilities(probs(fireAlarm, 0.9));
      }
      await settle();
      expect(fired, isEmpty, reason: '끊긴 뒤 5창은 6창에 못 미친다');
    });

    test('다른 종류가 끼면 처음부터 다시 센다', () async {
      for (var i = 0; i < 5; i++) {
        detector.evaluateProbabilities(probs(fireAlarm, 0.9));
      }
      // 관측된 오탐의 전형 — 소리가 잠깐 다른 클래스로 튄다.
      detector.evaluateProbabilities(probs(generalAlarm, 0.9));
      detector.evaluateProbabilities(probs(fireAlarm, 0.9));
      await settle();
      expect(fired, isEmpty);
    });

    test('확률이 문턱 아래면 연속으로 치지 않는다', () async {
      for (var i = 0; i < 10; i++) {
        detector.evaluateProbabilities(probs(fireAlarm, 0.5));
      }
      await settle();
      expect(fired, isEmpty);
      expect(detector.threshold, greaterThan(0.5));
    });
  });

  group('민감도', () {
    test('둔감하게 돌리면 문턱이 올라간다', () {
      detector.sensitivity = 0.55;
      expect(detector.threshold, closeTo(0.6, 1e-9));

      detector.sensitivity = 1.0;
      final blunt = detector.threshold;
      detector.sensitivity = 0.0;
      expect(detector.threshold, lessThan(blunt));
    });

    test('슬라이더를 끝까지 밀어도 측정 범위를 벗어나지 않는다', () {
      detector.sensitivity = 0.0;
      expect(detector.threshold, greaterThanOrEqualTo(0.45));
      detector.sensitivity = 1.0;
      expect(detector.threshold, lessThanOrEqualTo(0.75));
    });
  });

  group('쿨다운', () {
    test('한 번 울린 뒤에는 같은 종류가 다시 울리지 않는다', () async {
      for (var i = 0; i < 30; i++) {
        detector.evaluateProbabilities(probs(fireAlarm, 0.9));
      }
      await settle();
      expect(fired, hasLength(1), reason: '30창 내내 잡혀도 발령은 한 번');
    });

    test('쿨다운은 종류별로 따로 돈다', () async {
      for (var i = 0; i < 6; i++) {
        detector.evaluateProbabilities(probs(fireAlarm, 0.9));
      }
      for (var i = 0; i < 4; i++) {
        detector.evaluateProbabilities(probs(generalAlarm, 0.9));
      }
      await settle();
      expect(fired.map((d) => d.type),
          [AlertType.fireAlarm, AlertType.generalAlarm]);
    });
  });
}
