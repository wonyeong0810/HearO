import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hearo/core/env.dart';
import 'package:hearo/data/audio/alarm_detector.dart';
import 'package:integration_test/integration_test.dart';

/// 실제 기기에서 ONNX 모델이 제대로 도는지 확인한다.
///
/// 단위 테스트로는 여기까지 못 온다. ONNX Runtime 은 네이티브 라이브러리라
/// 호스트에서 도는 `flutter test` 에는 올라오지 않고, 결국 "PC 에서는 맞았는데
/// 폰에서 틀린" 경우를 못 잡는다. 그건 배포 후에야 드러난다.
///
/// 마이크는 쓰지 않는다. 에뮬레이터의 가상 마이크는 호스트 녹음 장치에 의존해
/// 환경마다 결과가 달라지고, 그러면 실패해도 모델 탓인지 오디오 장치 탓인지
/// 구분할 수 없다. 대신 학습에 쓰지 않은 한국 공식 음원을 모델 입력 규격
/// (32kHz mono float32) 그대로 넣는다.
///
/// 준비:
///   scripts/push_alarm_fixtures.sh 참고 — 음원을 기기로 밀어 넣어야 한다.
///
/// 실행:
///   flutter test integration_test/alarm_model_test.dart -d `기기ID`
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // 앱 전용 외부 디렉터리를 쓰면 안 된다 — 테스트 실행이 앱을 다시 설치하면서
  // 그 디렉터리를 통째로 지운다. /data/local/tmp 는 재설치를 타지 않는다.
  const fixtureDir = '/data/local/tmp/hearo_fixtures';

  late AlarmDetector detector;

  setUpAll(() async {
    detector = AlarmDetector();
    final loaded = await detector.load();
    expect(loaded, isTrue, reason: '모델 로드 실패: ${detector.loadError}');
  });

  tearDownAll(() => detector.dispose());

  /// 4초 창을 0.5초 간격으로 밀며 최빈 클래스를 찾는다.
  Future<Map<String, double>> classify(String name) async {
    final file = File('$fixtureDir/$name.f32');
    expect(file.existsSync(), isTrue,
        reason: '음원이 없습니다: ${file.path} — push_alarm_fixtures.sh 를 먼저 실행하세요');

    final bytes = await file.readAsBytes();
    final audio = Float32List.sublistView(bytes);
    expect(audio.length, greaterThanOrEqualTo(Env.alarmWindowSamples));

    final counts = <String, int>{};
    var total = 0;
    for (var start = 0;
        start + Env.alarmWindowSamples <= audio.length;
        start += Env.alarmHopSamples) {
      final window = Float32List.sublistView(
        audio,
        start,
        start + Env.alarmWindowSamples,
      );
      final probs = await detector.inferWindow(window);
      expect(probs, isNotNull);
      expect(probs!.length, detector.classNames.length);

      var best = 0;
      for (var i = 1; i < probs.length; i++) {
        if (probs[i] > probs[best]) best = i;
      }
      counts[detector.classNames[best]] =
          (counts[detector.classNames[best]] ?? 0) + 1;
      total++;
    }

    expect(total, greaterThan(0));
    return counts.map((k, v) => MapEntry(k, v / total));
  }

  testWidgets('민방위 파상음을 민방위 경보로 판정한다', (tester) async {
    final result = await classify('civil_defense');
    // ignore: avoid_print
    print('민방위 파상음 → $result');
    expect(result['civil_defense_siren'] ?? 0, greaterThan(0.8));
  });

  testWidgets('구급차 사이렌을 긴급차량으로 판정한다', (tester) async {
    final result = await classify('emergency_vehicle');
    // ignore: avoid_print
    print('구급차 사이렌 → $result');
    expect(result['emergency_vehicle_siren'] ?? 0, greaterThan(0.8));
  });

  testWidgets('경보가 아닌 소리는 배경으로 둔다', (tester) async {
    final result = await classify('background');
    // ignore: avoid_print
    print('핑크 노이즈 → $result');
    expect(result['background'] ?? 0, greaterThan(0.9),
        reason: '오탐이 나면 사용자가 기능을 꺼버린다');
  });

  testWidgets('추론이 실시간을 따라간다', (tester) async {
    final file = File('$fixtureDir/civil_defense.f32');
    final audio = Float32List.sublistView(await file.readAsBytes());
    final window =
        Float32List.sublistView(audio, 0, Env.alarmWindowSamples);

    await detector.inferWindow(window); // 워밍업
    final sw = Stopwatch()..start();
    const runs = 10;
    for (var i = 0; i < runs; i++) {
      await detector.inferWindow(window);
    }
    sw.stop();

    final perWindow = sw.elapsedMilliseconds / runs;
    // ignore: avoid_print
    print('추론 지연: ${perWindow.toStringAsFixed(1)} ms / 4초창');
    // 0.5초마다 한 창을 처리해야 하므로 500ms 를 넘으면 감지가 밀린다.
    expect(perWindow, lessThan(500));
  });
}
