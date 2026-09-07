import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import '../../core/env.dart';
import '../../domain/entities/emotion_tone.dart';

/// 온디바이스 경보음 감지 (기획 2. 위급 상황 감지).
///
/// 한국 경보음으로 직접 학습시킨 모델(EfficientAT `mn10_as` 파인튜닝)을
/// ONNX Runtime 으로 돌린다. 서버로 보내지 않는 이유는 명확하다 — 화재경보를
/// 네트워크 상태에 걸어 둘 수 없다. 지하실에서, 비행기 모드에서, 서버가
/// 죽었을 때도 경보는 울려야 한다.
///
/// 입력은 32kHz mono float32 4초 창이고, 전처리(로그멜)까지 ONNX 그래프
/// 안에 들어 있다. Dart 쪽에 STFT/멜 구현을 두지 않는 것이 중요하다 —
/// 학습 때와 조금만 어긋나도 "모델은 멀쩡한데 앱에서만 성능이 나쁜",
/// 원인 찾기 가장 어려운 형태의 버그가 된다.
///
/// 오탐 억제
/// ─────────
/// 단일 창 확률만 보면 폭죽, 새소리, 알람시계에도 경보가 뜬다. 실제로 재 보니
/// 진짜 경보는 최소 8창(4초) 이상 이어지고 오탐은 3창을 넘지 못했다 — 둘이
/// 겹치지 않는다. 그래서 세 가지를 겹쳐 건다.
///   1. 확률 임계값 ([sensitivity] 로 조절, 측정 기준점 0.6)
///   2. 연속 창 요구 — 같은 종류가 N창 연속이어야 인정 ([requiredFramesFor])
///   3. 쿨다운 — 한 번 울리면 [cooldown] 동안 같은 종류는 다시 울리지 않음
///
/// 이 설정에서 ESC-50 2.67시간 배경 소음 중 오발령 0건, 경보 4종 재현율
/// 100%, 알람시계를 화재경보로 승격하는 오류 0% 였다.
/// (0건은 "0회/시간"이 아니라 95% 상한 약 1.1회/시간이라는 뜻이다.)
class AlarmDetector {
  AlarmDetector({
    this.sensitivity = 0.55,
    this.cooldown = const Duration(seconds: 20),
  });

  /// 0(민감) ~ 1(둔감). 설정 화면에서 조절한다.
  double sensitivity;

  /// 같은 종류의 경보를 다시 울리기까지의 최소 간격.
  final Duration cooldown;

  OrtSession? _session;
  List<String> _classNames = const [];
  List<AlertType?> _classToAlert = const [];
  String? _inputName;
  String? _outputName;

  final _detections = StreamController<AlarmDetection>.broadcast();
  Stream<AlarmDetection> get detections => _detections.stream;

  StreamSubscription<Float32List>? _subscription;

  // ---- 연속 창 상태 ----
  // 창마다 최상위 클래스 하나만 본다. 종류별로 따로 세면 서로 다른 경보가
  // 번갈아 잡히는 구간에서도 각각 카운터가 쌓여 오발령이 늘어난다.
  AlertType? _runType;
  int _runLength = 0;
  final Map<AlertType, DateTime> _lastFired = {};

  bool _loading = false;
  bool _busy = false;

  /// 추론이 밀려 건너뛴 창 수. 계속 늘어나면 기기가 감당을 못 하고 있는 것이라
  /// 발령이 그만큼 늦어진다.
  int droppedWindows = 0;

  bool get isReady => _session != null;

  /// 모델 로드 실패 사유. UI 가 사용자에게 알려야 한다 —
  /// 경보 기능이 조용히 꺼져 있는 것이 가장 위험하다.
  String? loadError;

  // ================================================================ 로드

  Future<bool> load() async {
    if (isReady || _loading) return isReady;
    _loading = true;

    try {
      await _loadMetadata();

      final session = await OnnxRuntime().createSessionFromAsset(
        _modelAsset,
        options: OrtSessionOptions(intraOpNumThreads: 2, interOpNumThreads: 1),
      );

      // 입출력 이름을 하드코딩하지 않고 모델에서 읽는다. 모델을 다시
      // 내보냈을 때 이름이 바뀌어도 조용히 실패하지 않도록.
      if (session.inputNames.length != 1 || session.outputNames.length != 1) {
        throw StateError(
          '입출력이 하나씩이어야 합니다 '
          '(입력 ${session.inputNames}, 출력 ${session.outputNames}).',
        );
      }
      _inputName = session.inputNames.first;
      _outputName = session.outputNames.first;
      _session = session;
      loadError = null;
    } on Object catch (error) {
      loadError = '경보 감지 모델을 불러오지 못했습니다: $error';
      debugPrint('[AlarmDetector] $loadError');
      await _session?.close();
      _session = null;
    } finally {
      _loading = false;
    }

    return isReady;
  }

  /// 모델 없이 메타데이터만 읽는다. 클래스 매핑 테스트용.
  @visibleForTesting
  Future<void> loadMetadataOnly() => _loadMetadata();

  /// 추론 결과를 직접 밀어 넣는다. 디바운스 정책 테스트용 —
  /// ONNX 세션 없이 연속 창 규칙만 검증할 수 있다.
  @visibleForTesting
  void evaluateProbabilities(List<double> probabilities) =>
      _evaluate(probabilities);

  /// 창 하나를 추론해 확률만 돌려준다. 기기에서 모델이 제대로 도는지
  /// 확인하는 integration test 용 (마이크 없이 검증할 수 있다).
  @visibleForTesting
  Future<List<double>?> inferWindow(Float32List window) => _infer(window);

  /// 모델 클래스 이름. 테스트가 인덱스를 다시 하드코딩하지 않도록 노출한다.
  @visibleForTesting
  List<String> get classNames => _classNames;

  /// 클래스 이름을 메타데이터에서 읽는다.
  ///
  /// 예전에는 클래스 인덱스를 코드에 박아 두었는데, 모델을 새로 내보내
  /// 순서가 한 칸만 밀려도 화재경보 자리에 엉뚱한 소리가 들어온다. 생명에
  /// 직결되는 부분이라 이름으로 맞추고, 모르는 이름이 나오면 로드를 실패시킨다.
  Future<void> _loadMetadata() async {
    final raw = await rootBundle.loadString(_metadataAsset);
    final meta = jsonDecode(raw) as Map<String, dynamic>;

    final names = (meta['class_names'] as List<dynamic>).cast<String>();
    if (names.isEmpty) throw StateError('class_names 가 비어 있습니다.');

    // 입력 규격이 Env 와 다르면 오디오 파이프라인이 엉뚱한 걸 먹이고 있다.
    final input = meta['input'] as Map<String, dynamic>;
    final sampleRate = (input['sample_rate'] as num).toInt();
    final windowSamples =
        (sampleRate * (input['clip_seconds'] as num).toDouble()).round();
    if (sampleRate != Env.alarmSampleRate ||
        windowSamples != Env.alarmWindowSamples) {
      throw StateError(
        '모델 입력 규격이 Env 와 다릅니다: '
        '모델 ${sampleRate}Hz/$windowSamples샘플, '
        'Env ${Env.alarmSampleRate}Hz/${Env.alarmWindowSamples}샘플',
      );
    }

    _classNames = names;
    _classToAlert = names.map(_alertTypeFor).toList(growable: false);
  }

  /// 모델 클래스명 → 앱의 경보 종류. `null` 은 경보가 아니라는 뜻이다.
  static AlertType? _alertTypeFor(String className) => switch (className) {
        'background' => null,
        'fire_alarm' => AlertType.fireAlarm,
        'smoke_detector' => AlertType.smokeDetector,
        'civil_defense_siren' => AlertType.civilDefenseSiren,
        'emergency_vehicle_siren' => AlertType.emergencyVehicle,
        'general_alarm' => AlertType.generalAlarm,
        _ => throw StateError(
            '모르는 클래스 "$className". 모델을 바꿨다면 이 매핑도 함께 고쳐야 합니다.',
          ),
      };

  // ================================================================ 실행

  /// [windows] 는 32kHz mono float32, [Env.alarmWindowSamples] 짜리 창
  /// 스트림이어야 한다 (`AudioCapture.alarmStream`).
  void attach(Stream<Float32List> windows) {
    _subscription?.cancel();
    _resetRun();
    droppedWindows = 0;
    _subscription = windows.listen(
      _onWindow,
      onError: (Object error) => debugPrint('[AlarmDetector] $error'),
      cancelOnError: false,
    );
  }

  Future<void> detach() async {
    await _subscription?.cancel();
    _subscription = null;
    _resetRun();
  }

  void _resetRun() {
    _runType = null;
    _runLength = 0;
  }

  void _onWindow(Float32List window) {
    if (!isReady) return;
    if (window.length != Env.alarmWindowSamples) return;

    // 앞 추론이 안 끝났으면 이번 창은 버린다. 큐에 쌓으면 지연이 계속
    // 벌어져 "3초 전에 울린 경보"를 뒤늦게 알리게 된다. 건너뛴 창은 연속
    // 카운터를 끊지 않으므로 발령이 느려질 뿐 놓치지는 않는다.
    if (_busy) {
      droppedWindows++;
      if (droppedWindows % 20 == 1) {
        debugPrint('[AlarmDetector] 추론이 밀려 창 $droppedWindows개를 건너뛰었습니다.');
      }
      return;
    }

    _busy = true;
    unawaited(
      _infer(window).then(_evaluate).catchError((Object error) {
        debugPrint('[AlarmDetector] 추론 실패: $error');
      }).whenComplete(() => _busy = false),
    );
  }

  Future<List<double>?> _infer(Float32List window) async {
    final session = _session;
    if (session == null) return null;

    final input = await OrtValue.fromList(
      window,
      [1, Env.alarmWindowSamples],
    );
    Map<String, OrtValue>? outputs;
    try {
      outputs = await session.run({_inputName!: input});
      final logits = (await outputs[_outputName!]!.asFlattenedList())
          .cast<num>()
          .map((v) => v.toDouble())
          .toList(growable: false);

      if (logits.length != _classNames.length) {
        throw StateError(
          '출력 개수(${logits.length})가 클래스 수(${_classNames.length})와 다릅니다.',
        );
      }
      return _softmax(logits);
    } finally {
      // 네이티브 텐서는 직접 놓아 줘야 한다. 0.5초마다 도는 경로라
      // 한 번만 빠뜨려도 몇 시간 감시하면 눈에 띄게 샌다.
      await input.dispose();
      for (final value in outputs?.values ?? const <OrtValue>[]) {
        await value.dispose();
      }
    }
  }

  static List<double> _softmax(List<double> logits) {
    final max = logits.reduce(math.max);
    final exps = logits.map((v) => math.exp(v - max)).toList(growable: false);
    final sum = exps.reduce((a, b) => a + b);
    return exps.map((v) => v / sum).toList(growable: false);
  }

  void _evaluate(List<double>? probabilities) {
    if (probabilities == null) return;

    // 최상위 클래스 하나만 본다.
    var best = 0;
    for (var i = 1; i < probabilities.length; i++) {
      if (probabilities[i] > probabilities[best]) best = i;
    }

    final type = _classToAlert[best];
    final confidence = probabilities[best];

    // 배경이거나 확신이 약하면 연속 카운터를 끊는다.
    if (type == null || confidence < threshold) {
      _resetRun();
      return;
    }

    _runLength = (type == _runType) ? _runLength + 1 : 1;
    _runType = type;

    if (_runLength < requiredFramesFor(type)) return;

    final now = DateTime.now();
    final last = _lastFired[type];
    if (last != null && now.difference(last) < cooldown) return;

    _lastFired[type] = now;
    _detections.add(
      AlarmDetection(
        type: type,
        confidence: confidence.clamp(0.0, 1.0),
        rawClass: _classNames[best],
        detectedAt: now,
        consecutiveFrames: _runLength,
      ),
    );
  }

  /// 확률 임계값.
  ///
  /// 측정 기준점은 0.6 이다(기본 [sensitivity] 0.55 일 때). 슬라이더는 그
  /// 주변만 움직이게 두었다 — 밖으로 나가면 재 본 적 없는 영역이라 오탐률을
  /// 보증할 수 없다.
  ///
  /// 심각도별로 문턱을 다르게 주지 않는다. 심각도 차이는 [requiredFramesFor]
  /// 의 연속 창 수로만 표현한다. 두 손잡이를 동시에 돌리면 측정한 동작점에서
  /// 얼마나 벗어났는지 알 수 없게 된다.
  double get threshold => (0.6 + (sensitivity - 0.55) * 0.6).clamp(0.45, 0.75);

  /// 발령에 필요한 연속 창 수.
  ///
  /// 심각도가 높을수록 **더 엄격하게** 잡는다. 흔히 하는 반대 선택(화재는
  /// 관대하게)을 하지 않은 이유는 측정 때문이다. 창 수를 4에서 8까지 올려도
  /// 재현율이 100% 로 유지됐다 — 진짜 경보는 수십 초씩 이어지기 때문이다.
  /// 즉 심각도 3에서 창 수를 늘리는 데 드는 비용이 사실상 없고, 반대로
  /// 잘못 뜬 대피 지시는 피해가 가장 크다. 그래서 여유를 이쪽에 몰아준다.
  ///
  ///   심각도 3 → 6창 = 6.5초 (관측된 최대 오탐 연속 3창의 두 배)
  ///   그 외    → 4창 = 5.5초
  int requiredFramesFor(AlertType type) => type.severity >= 3 ? 6 : 4;

  Future<void> dispose() async {
    await detach();
    await _session?.close();
    _session = null;
    await _detections.close();
  }
}

/// 감지 결과 한 건.
@immutable
class AlarmDetection {
  const AlarmDetection({
    required this.type,
    required this.confidence,
    required this.rawClass,
    required this.detectedAt,
    required this.consecutiveFrames,
    this.isTest = false,
  });

  final AlertType type;
  final double confidence;

  /// 모델이 실제로 뱉은 클래스명. 오탐 분석에 쓴다.
  final String rawClass;

  final DateTime detectedAt;

  /// 몇 창 연속으로 잡혔는지 (디바운스 근거).
  final int consecutiveFrames;

  /// 사용자가 설정에서 직접 실행한 알림 테스트인지.
  ///
  /// 화면 문구와 서버 기록이 여기서 갈린다. 테스트를 실제 경보와 똑같이
  /// 보여주면 **옆 사람이 진짜 화재로 오해**하고, 서버에 기록하면 오탐 통계와
  /// 경보 이력이 오염된다. 둘 다 사용자가 알아채기 어려운 종류의 오류다.
  final bool isTest;
}

const String _modelAsset = 'assets/models/emergency_sound.onnx';
const String _metadataAsset = 'assets/models/emergency_sound_metadata.json';
