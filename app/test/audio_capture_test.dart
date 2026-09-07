import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hearo/core/env.dart';
import 'package:hearo/data/audio/audio_capture.dart';
import 'package:mocktail/mocktail.dart';
import 'package:record/record.dart';

/// 마이크(24kHz) → 경보 모델 입력(32kHz 4초 창) 변환 테스트.
///
/// 이 경로가 어긋나면 모델은 멀쩡한데 앱에서만 경보를 못 잡는다. 그리고
/// 그런 고장은 로그에 아무것도 남기지 않는다 — 그냥 조용히 안 울린다.
/// 그래서 창 길이·간격·샘플레이트 변환을 숫자로 못박아 둔다.
class _MockRecorder extends Mock implements AudioRecorder {}

void main() {
  setUpAll(() => registerFallbackValue(const RecordConfig()));

  late _MockRecorder recorder;
  late StreamController<Uint8List> mic;
  late AudioCapture capture;

  setUp(() {
    recorder = _MockRecorder();
    mic = StreamController<Uint8List>();

    when(() => recorder.hasPermission()).thenAnswer((_) async => true);
    when(() => recorder.isRecording()).thenAnswer((_) async => true);
    when(() => recorder.stop()).thenAnswer((_) async => null);
    when(() => recorder.dispose()).thenAnswer((_) async {});
    when(() => recorder.startStream(any()))
        .thenAnswer((_) async => mic.stream);

    capture = AudioCapture(recorder: recorder);
  });

  tearDown(() async {
    await mic.close();
    await capture.dispose();
  });

  /// 24kHz mono PCM16 청크를 만든다. [frequency] 가 0 이면 무음.
  Uint8List pcm(int samples, {double frequency = 0, int phase = 0}) {
    final data = Int16List(samples);
    for (var i = 0; i < samples; i++) {
      data[i] = frequency == 0
          ? 0
          : (math.sin(2 * math.pi * frequency * (phase + i) / Env.sampleRate) *
                  16000)
              .round();
    }
    return data.buffer.asUint8List();
  }

  test('마이크를 24kHz PCM16 으로 연다 — 백엔드 전사 계약', () async {
    await capture.start('test');
    final config =
        verify(() => recorder.startStream(captureAny())).captured.single
            as RecordConfig;

    expect(config.sampleRate, 24000);
    expect(config.numChannels, 1);
    expect(config.encoder, AudioEncoder.pcm16bits);
    // 자동 이득 조절은 "말의 크기" 자체가 표시할 정보라 반드시 꺼져 있어야 한다.
    expect(config.autoGain, isFalse);
    expect(config.echoCancel, isFalse);
  });

  test('4초가 다 차기 전에는 창을 내보내지 않는다', () async {
    final windows = <Float32List>[];
    capture.alarmStream.listen(windows.add);
    await capture.start('test');

    // 3.9초치. 앞을 0 으로 채워 넘기면 모델이 학습 때 본 적 없는 입력이 된다.
    mic.add(pcm((Env.sampleRate * 3.9).round()));
    await pumpEventQueue();

    expect(windows, isEmpty);
  });

  test('4초가 차면 창이 나오고, 이후 0.5초마다 하나씩 나온다', () async {
    final windows = <Float32List>[];
    capture.alarmStream.listen(windows.add);
    await capture.start('test');

    mic.add(pcm(Env.sampleRate * 4));
    await pumpEventQueue();
    expect(windows, hasLength(1));
    expect(windows.single.length, Env.alarmWindowSamples);
    expect(windows.single.length, 128000, reason: '32kHz × 4초');

    // 이후 2초 → 0.5초 간격이면 4개가 더 나와야 한다.
    mic.add(pcm(Env.sampleRate * 2));
    await pumpEventQueue();
    expect(windows, hasLength(5));

    for (final window in windows) {
      expect(window.length, Env.alarmWindowSamples);
    }
  });

  test('청크 경계와 무관하게 같은 개수가 나온다', () async {
    final windows = <Float32List>[];
    capture.alarmStream.listen(windows.add);
    await capture.start('test');

    // 실제 마이크는 100ms 씩 잘라서 준다. 리샘플러 위상이 청크마다
    // 초기화되면 여기서 개수가 어긋난다.
    const chunk = 2400; // 100ms @ 24kHz
    for (var i = 0; i < 60; i++) {
      mic.add(pcm(chunk));
    }
    await pumpEventQueue();

    // 6초 = 4초 채우고 남은 2초 동안 0.5초마다 → 1 + 4 = 5개
    expect(windows, hasLength(5));
  });

  test('24kHz 신호를 32kHz 로 올려도 주파수가 유지된다', () async {
    final windows = <Float32List>[];
    capture.alarmStream.listen(windows.add);
    await capture.start('test');

    const frequency = 1000.0;
    // 위상을 이어 붙여야 청크 경계에서 파형이 끊기지 않는다.
    const chunk = 2400;
    for (var i = 0; i < 40; i++) {
      mic.add(pcm(chunk, frequency: frequency, phase: i * chunk));
    }
    await pumpEventQueue();
    expect(windows, isNotEmpty);

    // 영교차 수로 주파수를 센다. 32kHz 4초에 1kHz 면 8000회.
    final window = windows.first;
    var crossings = 0;
    for (var i = 1; i < window.length; i++) {
      if ((window[i - 1] < 0) != (window[i] < 0)) crossings++;
    }
    expect(crossings / 2 / 4.0, closeTo(frequency, 5),
        reason: '리샘플이 주파수를 바꾸면 모델이 다른 소리로 본다');

    // 진폭도 살아 있어야 한다 (16000/32768 ≈ 0.488).
    final peak = window.reduce((a, b) => math.max(a.abs(), b.abs()));
    expect(peak, closeTo(0.488, 0.02));
  });

  test('연속한 두 창은 3.5초를 겹친다', () async {
    final windows = <Float32List>[];
    capture.alarmStream.listen(windows.add);
    await capture.start('test');

    const chunk = 2400;
    for (var i = 0; i < 50; i++) {
      mic.add(pcm(chunk, frequency: 700, phase: i * chunk));
    }
    await pumpEventQueue();
    expect(windows.length, greaterThanOrEqualTo(2));

    // 두 번째 창의 앞부분 = 첫 창의 0.5초 이후 부분.
    final first = windows[0];
    final second = windows[1];
    const hop = 16000; // 0.5초 @ 32kHz
    for (var i = 0; i < 1000; i++) {
      expect(second[i], closeTo(first[hop + i], 1e-6));
    }
  });

  test('홀수 오프셋 뷰로 들어와도 죽지 않는다', () async {
    // record 플러그인이 큰 버퍼의 홀수 위치를 가리키는 뷰를 줄 때가 있다.
    // 그대로 asInt16List 를 부르면 정렬 오류로 오디오 경로가 통째로 죽는다.
    // 실제로 에뮬레이터에서 이걸로 앱이 무너졌다.
    final windows = <Float32List>[];
    capture.alarmStream.listen(windows.add);
    await capture.start('test');

    const chunk = 2400;
    for (var i = 0; i < 50; i++) {
      final aligned = pcm(chunk, frequency: 700, phase: i * chunk);
      // 앞에 1바이트를 덧대 홀수 오프셋 뷰를 만든다.
      final padded = Uint8List(aligned.length + 1)
        ..setRange(1, aligned.length + 1, aligned);
      mic.add(Uint8List.sublistView(padded, 1));
    }
    await pumpEventQueue();

    expect(windows.length, greaterThanOrEqualTo(2));
    final peak = windows.first.reduce((a, b) => math.max(a.abs(), b.abs()));
    expect(peak, closeTo(0.488, 0.02), reason: '샘플이 깨지지 않아야 한다');
  });

  test('길이가 홀수인 청크가 와도 바이트 경계가 밀리지 않는다', () async {
    // 남는 바이트를 버리면 이후 모든 샘플이 한 칸씩 밀려 잡음이 된다.
    // 예외가 안 나서 눈치채기 가장 어려운 형태의 고장이다.
    final windows = <Float32List>[];
    capture.alarmStream.listen(windows.add);
    await capture.start('test');

    var phase = 0;
    for (var i = 0; i < 120; i++) {
      final samples = i.isEven ? 1201 : 1199; // 홀수 바이트가 되도록
      final full = pcm(samples, frequency: 700, phase: phase);
      phase += samples;
      // 마지막 1바이트를 잘라 홀수 길이 청크로 만든다.
      mic.add(Uint8List.sublistView(full, 0, full.length - 1));
      mic.add(Uint8List.sublistView(full, full.length - 1));
    }
    await pumpEventQueue();

    expect(windows, isNotEmpty);
    final window = windows.first;
    var crossings = 0;
    for (var i = 1; i < window.length; i++) {
      if ((window[i - 1] < 0) != (window[i] < 0)) crossings++;
    }
    expect(crossings / 2 / 4.0, closeTo(700, 10),
        reason: '경계가 밀리면 주파수가 엉망이 된다');
  });

  test('소비자가 없으면 창을 만들지 않는다', () async {
    await capture.start('test');
    mic.add(pcm(Env.sampleRate * 5));
    await pumpEventQueue();
    // 리스너가 붙은 뒤에야 버퍼가 차기 시작한다.
    final windows = <Float32List>[];
    capture.alarmStream.listen(windows.add);
    mic.add(pcm((Env.sampleRate * 3.9).round()));
    await pumpEventQueue();
    expect(windows, isEmpty);
  });
}
