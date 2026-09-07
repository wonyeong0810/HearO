import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

import '../../core/env.dart';

/// 마이크 하나를 두 소비자가 나눠 쓴다.
///
///   마이크 (24kHz PCM16)
///     ├─▶ [pcmStream]     실시간 자막 업로드용 (원본 그대로)
///     └─▶ [alarmStream]   경보음 감지용 (32kHz 4초 창)
///
/// 마이크를 두 번 열면 안 된다 — 대부분의 기기에서 두 번째 열기가 실패하거나,
/// 성공해도 서로 오디오를 빼앗는다. 그래서 한 번만 열고 갈라 쓴다.
///
/// 자막이 꺼져 있어도 경보 감지는 돌아야 하므로, 두 소비자는 독립적으로
/// 붙었다 떨어질 수 있고 마지막 하나가 떨어질 때 마이크가 닫힌다.
///
/// 왜 마이크를 32kHz 로 열지 않는가
/// ────────────────────────────────
/// 백엔드 전사 계약이 24kHz 다. 자막이 이 앱의 본체이므로 그쪽 규격을 경보
/// 감지 때문에 흔들 수는 없다. 대신 24kHz → 32kHz 업샘플로 모델에 먹인다.
/// 24kHz 마이크는 12kHz 위를 못 담고 모델은 15kHz 까지 보도록 학습됐지만,
/// 실제로 재 보니 차이가 없었다 — 창 단위 예측 일치 99.1%, 발령 결과는 동일
/// (공식 음원 + ESC-50 2.67시간 기준). 경보음의 정보는 전부 저역에 있다.
class AudioCapture {
  AudioCapture({AudioRecorder? recorder})
      : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;

  StreamSubscription<Uint8List>? _micSubscription;
  final _pcmController = StreamController<Uint8List>.broadcast();
  final _alarmController = StreamController<Float32List>.broadcast();
  final _levelController = StreamController<double>.broadcast();

  bool _running = false;
  final Set<String> _consumers = {};

  /// 24kHz mono PCM16. 백엔드로 그대로 올린다.
  Stream<Uint8List> get pcmStream => _pcmController.stream;

  /// 32kHz mono float32 창 (경보 모델 입력 규격, 4초 = 128000 샘플).
  /// 0.5초마다 하나씩, 앞 창과 3.5초를 겹쳐 내보낸다.
  Stream<Float32List> get alarmStream => _alarmController.stream;

  /// 0~1 정규화 입력 레벨. 화면의 마이크 레벨 표시에 쓴다.
  Stream<double> get levelStream => _levelController.stream;

  bool get isRunning => _running;

  Future<bool> hasPermission() => _recorder.hasPermission();

  /// [consumer] 이름으로 캡처를 요청한다. 이미 돌고 있으면 참조만 늘린다.
  Future<void> start(String consumer) async {
    _consumers.add(consumer);
    if (_running) return;

    if (!await _recorder.hasPermission()) {
      _consumers.remove(consumer);
      throw const MicrophonePermissionDenied();
    }

    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: Env.sampleRate,
        numChannels: Env.channels,
        // 에코 제거는 켜면 원거리 화자 목소리까지 깎아내 화자분리를 망친다.
        echoCancel: false,
        // 자동 이득 조절은 음량 정보를 평탄화한다. 우리는 "말의 크기" 자체가
        // 표시해야 할 정보이므로 반드시 꺼야 한다 (기획 1-3).
        autoGain: false,
        noiseSuppress: false,
      ),
    );

    _running = true;
    _resetResampler();

    _micSubscription = stream.listen(
      _onMicData,
      onError: (Object error, StackTrace stack) {
        _pcmController.addError(error, stack);
        _alarmController.addError(error, stack);
      },
      cancelOnError: false,
    );
  }

  /// [consumer] 가 더 이상 필요 없다고 알린다. 마지막 소비자면 마이크를 닫는다.
  Future<void> stop(String consumer) async {
    _consumers.remove(consumer);
    if (_consumers.isNotEmpty || !_running) return;
    await _shutdown();
  }

  Future<void> stopAll() async {
    _consumers.clear();
    await _shutdown();
  }

  Future<void> _shutdown() async {
    _running = false;
    await _micSubscription?.cancel();
    _micSubscription = null;
    if (await _recorder.isRecording()) {
      await _recorder.stop();
    }
  }

  Future<void> dispose() async {
    await stopAll();
    await _pcmController.close();
    await _alarmController.close();
    await _levelController.close();
    await _recorder.dispose();
  }

  // ================================================================ 처리

  void _onMicData(Uint8List chunk) {
    if (chunk.isEmpty) return;

    // 1) 원본은 그대로 자막 트랙으로
    if (_pcmController.hasListener) {
      _pcmController.add(chunk);
    }

    if (!_levelController.hasListener && !_alarmController.hasListener) return;

    final samples = _decodePcm16(chunk);
    if (samples.isEmpty) return;

    // 2) 레벨 미터
    if (_levelController.hasListener) {
      _levelController.add(_peakLevel(samples));
    }

    // 3) 경보 모델은 32kHz 를 요구한다 → 업샘플 후 4초 창으로 모아 방출
    if (_alarmController.hasListener) {
      _feedAlarm(samples);
    }
  }

  /// 직전 청크에서 넘어온 홀수 바이트 한 개.
  int? _carriedByte;

  /// PCM16 바이트를 샘플로 푼다.
  ///
  /// 그냥 `chunk.buffer.asInt16List(chunk.offsetInBytes, …)` 를 쓰면 안 된다.
  /// 플러그인이 큰 버퍼의 **홀수 위치**를 가리키는 뷰를 줄 때가 있고, 그러면
  /// "Offset (5) must be a multiple of BYTES_PER_ELEMENT" 로 던진다. 실제로
  /// 에뮬레이터에서 이걸로 오디오 파이프라인이 통째로 죽었다.
  ///
  /// 청크 길이가 홀수인 경우도 같이 막는다. 남는 바이트를 그냥 버리면 이후
  /// 모든 샘플의 바이트 경계가 한 칸 밀려 잡음만 남는데, 예외가 안 나므로
  /// 눈치채기 어렵다. 그래서 다음 청크 앞에 붙여 준다.
  Int16List _decodePcm16(Uint8List chunk) {
    final carried = _carriedByte;
    var bytes = chunk;

    if (carried != null) {
      bytes = Uint8List(chunk.length + 1)
        ..[0] = carried
        ..setRange(1, chunk.length + 1, chunk);
      _carriedByte = null;
    }

    if (bytes.length.isOdd) {
      _carriedByte = bytes[bytes.length - 1];
      bytes = Uint8List.sublistView(bytes, 0, bytes.length - 1);
    }
    if (bytes.isEmpty) return Int16List(0);

    // 정렬이 맞을 때만 복사 없이 뷰로 읽는다.
    if (bytes.offsetInBytes.isEven) {
      return bytes.buffer.asInt16List(bytes.offsetInBytes, bytes.length ~/ 2);
    }
    return Int16List.sublistView(Uint8List.fromList(bytes));
  }

  double _peakLevel(Int16List samples) {
    var peak = 0;
    for (final sample in samples) {
      final magnitude = sample < 0 ? -sample : sample;
      if (magnitude > peak) peak = magnitude;
    }
    return (peak / 32768.0).clamp(0.0, 1.0);
  }

  // ---- 24kHz → 32kHz 리샘플 상태 ----
  // 비율이 정확히 3:4 라 위상 누산기로 간단히 처리한다. 입력 3샘플마다
  // 출력 4샘플이 나온다. 평가 스크립트도 같은 선형보간으로 재서 검증했다.
  static const double _resampleStep = Env.sampleRate / Env.alarmSampleRate;

  double _phase = 0;
  int _lastSample = 0;

  /// 4초치 링 버퍼. 매번 List 를 잘라 붙이면 0.5초마다 1MB 씩 옮기게 되므로
  /// 고정 버퍼에 덮어쓰고 방출할 때만 한 번 복사한다.
  final Float32List _ring = Float32List(Env.alarmWindowSamples);
  int _writeIndex = 0;
  int _filled = 0;
  int _sinceEmit = 0;

  void _resetResampler() {
    _phase = 0;
    _lastSample = 0;
    _writeIndex = 0;
    _filled = 0;
    _sinceEmit = 0;
    _carriedByte = null;
  }

  void _feedAlarm(Int16List samples) {
    for (final current in samples) {
      // _phase 가 1 미만인 동안 출력 샘플을 만든다.
      while (_phase < 1.0) {
        // 선형보간. 경보음의 정보는 저역에 있어 이 정도로 충분하다.
        final interpolated = _lastSample + (current - _lastSample) * _phase;
        _push(interpolated / 32768.0);
        _phase += _resampleStep;
      }
      _phase -= 1.0;
      _lastSample = current;
    }
  }

  void _push(double sample) {
    _ring[_writeIndex] = sample;
    _writeIndex = (_writeIndex + 1) % Env.alarmWindowSamples;
    if (_filled < Env.alarmWindowSamples) _filled++;
    _sinceEmit++;

    // 버퍼가 다 차기 전에는 내보내지 않는다. 앞을 0 으로 채워 넘기면
    // 모델이 학습 때 본 적 없는 입력이 되어 첫 몇 초가 통째로 헛돈다.
    if (_filled < Env.alarmWindowSamples) return;
    if (_sinceEmit < Env.alarmHopSamples) return;
    _sinceEmit = 0;

    // 가장 오래된 샘플(= 다음에 덮어쓸 자리)부터 시간 순으로 펴서 복사한다.
    final window = Float32List(Env.alarmWindowSamples);
    final head = Env.alarmWindowSamples - _writeIndex;
    window.setRange(0, head, _ring, _writeIndex);
    window.setRange(head, Env.alarmWindowSamples, _ring, 0);
    _alarmController.add(window);
  }
}

class MicrophonePermissionDenied implements Exception {
  const MicrophonePermissionDenied();

  @override
  String toString() => '마이크 권한이 필요합니다.';
}
