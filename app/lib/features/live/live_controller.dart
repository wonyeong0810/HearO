import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/api_client.dart';
import '../../data/api_exception.dart';
import '../../data/audio/audio_capture.dart';
import '../../data/live_session_client.dart';
import '../../domain/entities/caption.dart';
import '../../domain/entities/emotion_tone.dart';
import 'demo_script.dart';

/// 라이브 자막 화면의 상태.
@immutable
class LiveState {
  const LiveState({
    this.phase = LivePhase.idle,
    this.captions = const [],
    this.speakers = const [],
    this.partialText = '',
    this.sessionId,
    this.errorMessage,
    this.statusMessage,
    this.micLevel = 0,
    this.isReconnecting = false,
    this.elapsed = Duration.zero,
    this.isDemo = false,
  });

  final LivePhase phase;

  /// 확정된 자막들 (오래된 것 → 최신)
  final List<Caption> captions;

  /// 지금까지 등장한 화자들. 색상 범례에 쓴다.
  final List<Speaker> speakers;

  /// 실시간 트랙의 잠정 텍스트. 확정되면 [captions] 로 옮겨간다.
  final String partialText;

  final String? sessionId;
  final String? errorMessage;
  final String? statusMessage;

  /// 0~1 마이크 입력 레벨
  final double micLevel;

  final bool isReconnecting;
  final Duration elapsed;

  /// 체험 모드로 돌고 있는지. 예시 자막이므로 화면에 반드시 밝혀야 한다 —
  /// 실제로 들린 말이라고 오해하면 그게 이 앱에서 가장 나쁜 오류다.
  final bool isDemo;

  bool get isRunning =>
      phase == LivePhase.listening || phase == LivePhase.starting;

  bool get hasContent => captions.isNotEmpty || partialText.isNotEmpty;

  /// 아직 화자가 확정되지 않은 자막 수. UI 가 "화자 확인 중" 안내에 쓴다.
  int get pendingSpeakerCount =>
      captions.where((c) => c.isAwaitingSpeaker).length;

  LiveState copyWith({
    LivePhase? phase,
    List<Caption>? captions,
    List<Speaker>? speakers,
    String? partialText,
    String? sessionId,
    String? errorMessage,
    bool clearError = false,
    String? statusMessage,
    bool clearStatus = false,
    double? micLevel,
    bool? isReconnecting,
    Duration? elapsed,
    bool? isDemo,
  }) {
    return LiveState(
      phase: phase ?? this.phase,
      captions: captions ?? this.captions,
      speakers: speakers ?? this.speakers,
      partialText: partialText ?? this.partialText,
      sessionId: sessionId ?? this.sessionId,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      statusMessage: clearStatus ? null : (statusMessage ?? this.statusMessage),
      micLevel: micLevel ?? this.micLevel,
      isReconnecting: isReconnecting ?? this.isReconnecting,
      elapsed: elapsed ?? this.elapsed,
      isDemo: isDemo ?? this.isDemo,
    );
  }
}

enum LivePhase { idle, starting, listening, stopping, ended, failed }

/// 라이브 자막 컨트롤러.
///
/// 하는 일: 세션 생성 → 티켓 발급 → WS 연결 → 마이크 오디오 펌핑 →
/// 서버 이벤트를 자막 목록에 반영.
class LiveController extends StateNotifier<LiveState> {
  LiveController({
    required ApiClient api,
    required AudioCapture capture,
  })  : _api = api,
        _capture = capture,
        super(const LiveState());

  final ApiClient _api;
  final AudioCapture _capture;

  LiveSessionClient? _client;
  StreamSubscription<Uint8List>? _audioSubscription;
  StreamSubscription<LiveEvent>? _eventSubscription;
  StreamSubscription<double>? _levelSubscription;
  Timer? _elapsedTimer;
  DateTime? _startedAt;

  static const _consumerId = 'live-captions';

  /// 자막이 너무 많이 쌓이면 메모리와 렌더링이 무거워진다. 화면에는 최근
  /// 것만 두고, 전체는 서버에 저장되어 있으므로 기록 화면에서 볼 수 있다.
  static const _maxCaptionsInMemory = 500;

  static const _demoCaptionLagMs = 310;

  // ================================================================ 시작

  Future<void> start({String? title, String? contextHint}) async {
    if (state.isRunning) return;

    state = const LiveState(phase: LivePhase.starting);

    try {
      // 1) 마이크 권한을 먼저 확인한다. 세션을 만들어 놓고 권한이 없으면
      //    빈 세션이 서버에 남는다.
      if (!await _capture.hasPermission()) {
        state = state.copyWith(
          phase: LivePhase.failed,
          errorMessage: '마이크 권한이 필요합니다. 설정에서 권한을 허용해 주세요.',
        );
        return;
      }

      // 2) 세션 생성
      final session = await _api.createSession(
        title: title,
        contextHint: contextHint,
      );

      // 3) WS 티켓 발급 (60초 유효)
      final ticket = await _api.issueWebSocketTicket();

      // 4) 연결
      final client = LiveSessionClient();
      await client.connect(sessionId: session.id, ticket: ticket);
      _client = client;

      _eventSubscription = client.events.listen(_onEvent);

      // 5) 마이크 → WS 펌핑
      await _capture.start(_consumerId);
      _audioSubscription = _capture.pcmStream.listen(
        client.sendAudio,
        onError: (Object error) {
          debugPrint('[Live] 오디오 오류: $error');
        },
      );
      _levelSubscription = _capture.levelStream.listen((level) {
        // 레벨은 초당 수십 번 오므로 상태를 매번 갱신하면 낭비다.
        // 눈에 띄게 변할 때만 반영한다.
        if ((level - state.micLevel).abs() > 0.04) {
          state = state.copyWith(micLevel: level);
        }
      });

      _startedAt = DateTime.now();
      _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        final started = _startedAt;
        if (started == null) return;
        state = state.copyWith(elapsed: DateTime.now().difference(started));
      });

      state = state.copyWith(
        phase: LivePhase.listening,
        sessionId: session.id,
        clearError: true,
      );
    } on MicrophonePermissionDenied {
      await _teardown();
      state = state.copyWith(
        phase: LivePhase.failed,
        errorMessage: '마이크 권한이 필요합니다.',
      );
    } on ApiException catch (error) {
      await _teardown();
      state = state.copyWith(
        phase: LivePhase.failed,
        errorMessage: error.message,
      );
    } on LiveConnectionException catch (error) {
      await _teardown();
      state = state.copyWith(
        phase: LivePhase.failed,
        errorMessage: error.message,
      );
    } on Object catch (error) {
      await _teardown();
      state = state.copyWith(
        phase: LivePhase.failed,
        errorMessage: '자막을 시작하지 못했습니다: $error',
      );
    }
  }

  // ================================================================ 체험 모드

  /// 마이크도 서버도 쓰지 않고 예시 대화를 재생한다.
  ///
  /// 왜 필요한가: 이 앱의 사용자는 소리를 못 듣는다. 자기 목소리로 시험해
  /// 보기도 어렵고, 옆에 말해 줄 사람이 늘 있는 것도 아니다. 그러면 "화면에
  /// 뭐가 어떻게 나오는지"를 실제 상황에서 처음 겪게 되는데, 그때는 이미
  /// 대화를 따라가느라 화면을 뜯어볼 여유가 없다.
  ///
  /// 권한 요청 전에 돌아가야 하므로 마이크를 건드리지 않고, 저장할 것도
  /// 없으므로 세션도 만들지 않는다.
  Future<void> startDemo() async {
    if (state.isRunning) return;

    _demoRun++;
    final run = _demoRun;

    state = const LiveState(phase: LivePhase.listening, isDemo: true);
    _startedAt = DateTime.now();
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final started = _startedAt;
      if (started == null) return;
      state = state.copyWith(elapsed: DateTime.now().difference(started));
    });

    final content = await loadDemoContent();
    if (!mounted || _demoRun != run) return;
    await _playDemo(run, content);
  }

  Future<void> _playDemo(int run, DemoContent content) async {
    /// 취소·화면 이탈·재시작 중 하나라도 있으면 즉시 멈춘다.
    bool alive() => mounted && _demoRun == run && state.isDemo;

    var sequence = 0;
    var elapsedMs = 0;
    final clock = Stopwatch()..start();

    for (final line in content.lines) {
      if (!alive()) return;
      final startMs = line.startMs;
      if (startMs != null) {
        final wait = startMs + _demoCaptionLagMs - clock.elapsedMilliseconds;
        if (wait > 0) await Future<void>.delayed(Duration(milliseconds: wait));
      } else {
        await Future<void>.delayed(line.pauseBefore);
      }
      if (!alive()) return;

      final speaker =
          content.speakers.firstWhere((s) => s.key == line.speakerKey);

      // 화자가 늦게 붙는 줄이 아니면 말하기 전에 범례에 올린다.
      if (!line.speakerLate) _upsertSpeaker(speaker);

      final lineStart = line.startMs ?? elapsedMs;
      final durationMs = line.endMs != null
          ? line.endMs! - lineStart
          : 400 + line.text.length * 90;

      await _typeOut(line, alive, clock, durationMs);
      if (!alive()) return;

      final caption = Caption(
        sequence: sequence,
        text: line.text,
        startMs: lineStart,
        endMs: lineStart + durationMs,
        tone: line.tone,
        toneConfidence: line.toneConfidence,
        toneBasis: line.toneBasis,
        intensity: line.intensity,
        speaker: line.speakerLate ? null : speaker,
        speakerResolved: !line.speakerLate,
      );
      _appendCaption(caption);
      elapsedMs = lineStart + durationMs + line.pauseBefore.inMilliseconds;

      // 3) 화자분리 트랙이 뒤늦게 따라붙는 경우
      if (line.speakerLate) {
        final target = sequence;
        unawaited(
          Future<void>.delayed(const Duration(milliseconds: 1600), () {
            if (!alive()) return;
            _upsertSpeaker(speaker);
            final index =
                state.captions.indexWhere((c) => c.sequence == target);
            if (index < 0) return;
            final updated = [...state.captions];
            updated[index] = updated[index]
                .copyWith(speaker: speaker, speakerResolved: true);
            state = state.copyWith(captions: updated);
          }),
        );
      }

      sequence++;
    }

    if (!alive()) return;
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
    _startedAt = null;
    state = state.copyWith(
      phase: LivePhase.ended,
      partialText: '',
      micLevel: 0,
    );

    unawaited(_saveDemoSession(content));
  }

  Future<void> _saveDemoSession(DemoContent content) async {
    final captions = state.captions;
    if (captions.isEmpty) return;

    try {
      final session = await _api.createSession();
      await _api.importSession(
        session.id,
        speakers: [
          for (final speaker in content.speakers)
            {
              'label': speaker.label,
              'color_hex': speaker.colorHex,
            },
        ],
        utterances: [
          for (final caption in captions)
            {
              'sequence': caption.sequence,
              'text': caption.text,
              'start_ms': caption.startMs,
              'end_ms': caption.endMs,
              if (caption.speaker != null)
                'speaker_label': caption.speaker!.label,
              'tone': caption.tone.wireValue,
              'tone_confidence': caption.toneConfidence,
              'tone_basis': caption.toneBasis.wireValue,
              'intensity': caption.intensity,
            },
        ],
      );
    } on Object catch (error) {
      debugPrint('[Live] 체험 기록 저장 실패: $error');
    }
  }

  /// 글자가 흘러나오는 단계를 흉내 낸다. 실시간 트랙은 어절 단위로 갱신되고
  /// 확정 전까지 계속 바뀐다 — 그 "확정되지 않은 글자"의 생김새를 미리
  /// 보여 주는 것이 이 단계의 목적이다.
  Future<void> _typeOut(
    DemoLine line,
    bool Function() alive,
    Stopwatch clock,
    int durationMs,
  ) async {
    final timed = line.words;
    final buffer = StringBuffer();

    void reveal(String word) {
      buffer.write(buffer.isEmpty ? word : ' $word');
      state = state.copyWith(
        partialText: buffer.toString(),
        micLevel: (line.intensity * (0.7 + _demoRandom.nextDouble() * 0.6))
            .clamp(0.05, 1.0),
      );
    }

    if (timed != null) {
      for (final word in timed) {
        if (!alive()) return;
        final wait = word.atMs + _demoCaptionLagMs - clock.elapsedMilliseconds;
        if (wait > 0) await Future<void>.delayed(Duration(milliseconds: wait));
        if (!alive()) return;
        reveal(word.text);
      }
      state = state.copyWith(micLevel: 0.08);
      return;
    }

    final words = line.text.split(' ');
    final weights = words.map((w) => w.runes.length + 1).toList();
    final total = weights.fold<int>(0, (sum, w) => sum + w);
    final start = clock.elapsedMilliseconds;
    var spent = 0;

    for (var i = 0; i < words.length; i++) {
      if (!alive()) return;
      reveal(words[i]);
      spent += (durationMs * weights[i] / total).round();
      final wait = start + spent - clock.elapsedMilliseconds;
      if (wait > 0) await Future<void>.delayed(Duration(milliseconds: wait));
    }
    state = state.copyWith(micLevel: 0.08);
  }

  /// 체험 모드를 끝낸다. 저장할 것도 끊을 것도 없다.
  void stopDemo() {
    _demoRun++;
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
    _startedAt = null;
    state = const LiveState(phase: LivePhase.idle);
  }

  int _demoRun = 0;
  final _demoRandom = math.Random(7);

  // ================================================================ 종료

  Future<void> stop() async {
    if (state.isDemo) {
      stopDemo();
      return;
    }
    if (!state.isRunning) return;
    state = state.copyWith(phase: LivePhase.stopping);

    // 오디오를 먼저 끊어야 종료 처리 중 새 자막이 끼어들지 않는다.
    await _audioSubscription?.cancel();
    _audioSubscription = null;
    await _capture.stop(_consumerId);

    await _client?.stop();
    await _teardown();

    state = state.copyWith(phase: LivePhase.ended, partialText: '');
  }

  /// 화면을 벗어날 때 등, 저장을 기다리지 않고 즉시 정리.
  Future<void> abort() async {
    await _client?.abort();
    await _teardown();
    if (mounted) {
      state = state.copyWith(phase: LivePhase.ended);
    }
  }

  Future<void> _teardown() async {
    // 진행 중인 체험 재생도 함께 끊는다. 화면을 벗어난 뒤에도 계속 돌면
    // dispose 된 notifier 를 건드려 죽는다.
    _demoRun++;
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
    _startedAt = null;

    await _audioSubscription?.cancel();
    _audioSubscription = null;
    await _levelSubscription?.cancel();
    _levelSubscription = null;
    await _eventSubscription?.cancel();
    _eventSubscription = null;

    await _capture.stop(_consumerId);

    final client = _client;
    _client = null;
    await client?.dispose();
  }

  // ================================================================ 이벤트

  void _onEvent(LiveEvent event) {
    switch (event.type) {
      case LiveEventType.captionPartial:
        state = state.copyWith(partialText: event.partialText ?? '');

      case LiveEventType.captionFinal:
        _appendCaption(event.caption!);

      case LiveEventType.captionUpdated:
        _patchCaption(event);

      case LiveEventType.speakerAdded:
        _upsertSpeaker(event.speaker!);

      case LiveEventType.status:
        final reconnecting = event.state == 'reconnecting';
        state = state.copyWith(
          isReconnecting: reconnecting,
          statusMessage: reconnecting ? event.message : null,
          clearStatus: !reconnecting,
        );

      case LiveEventType.error:
        state = state.copyWith(errorMessage: event.message);

      case LiveEventType.sessionEnded:
        state = state.copyWith(phase: LivePhase.ended, partialText: '');

      case LiveEventType.closed:
        if (state.isRunning) {
          state = state.copyWith(
            phase: event.graceful ? LivePhase.ended : LivePhase.failed,
            errorMessage: event.graceful ? null : '연결이 끊어졌습니다.',
          );
        }

      case LiveEventType.sessionStarted:
        state = state.copyWith(clearError: true);
    }
  }

  void _appendCaption(Caption caption) {
    final updated = [...state.captions];

    // 대개는 맨 뒤에 붙지만 항상 그렇지는 않다. 서버가 한 줄을 화자별로 나누면
    // 이미 나간 줄 **사이에** 새 조각이 끼어든다. 그냥 이어 붙이면 나중에 한
    // 말이 먼저 한 말 위에 오는데, 화면이 유일한 통로인 사용자에게 대화 순서가
    // 뒤바뀌는 것은 내용이 틀린 것만큼 나쁘다.
    var at = updated.length;
    while (at > 0 && updated[at - 1].startMs > caption.startMs) {
      at--;
    }
    updated.insert(at, caption);

    if (updated.length > _maxCaptionsInMemory) {
      updated.removeRange(0, updated.length - _maxCaptionsInMemory);
    }
    state = state.copyWith(captions: updated, partialText: '');
  }

  /// 이미 화면에 나간 자막 줄을 고친다 (화자 확정 / 감정 확정).
  void _patchCaption(LiveEvent event) {
    final sequence = event.sequence;
    if (sequence == null) return;

    final index = state.captions.indexWhere((c) => c.sequence == sequence);
    if (index < 0) return;

    final existing = state.captions[index];
    final patched = existing.copyWith(
      id: event.captionId,
      // 줄을 화자별로 나눈 경우에만 문장이 실려 온다. 없으면 그대로 둔다.
      text: event.text,
      startMs: event.startMs,
      speaker: event.speaker,
      // 화자 확정을 시도했으나 특정하지 못한 경우: 화자 없음으로 확정한다.
      clearSpeaker: event.speakerUnknown,
      speakerResolved:
          event.speaker != null || event.speakerUnknown ? true : null,
      tone: event.tone == null ? null : EmotionTone.fromWire(event.tone),
      toneConfidence: event.toneConfidence,
      // 화자만 확정하는 patch 에는 근거가 안 실린다. 그때 기본값으로 덮으면
      // 이미 문장까지 본 판정이 "목소리만 봤다"로 되돌아간다.
      toneBasis:
          event.toneBasis == null ? null : ToneBasis.fromWire(event.toneBasis),
    );

    final updated = [...state.captions];
    updated[index] = patched;
    state = state.copyWith(captions: updated);
  }

  void _upsertSpeaker(Speaker speaker) {
    final speakers = [...state.speakers];
    final index = speakers.indexWhere((s) => s.key == speaker.key);
    if (index >= 0) {
      speakers[index] = speaker;
    } else {
      speakers.add(speaker);
    }

    // 화자 정보가 바뀌면 이미 그 화자로 표시된 자막들도 함께 갱신한다.
    // (이름이나 색을 바꿨는데 지난 자막은 옛 색으로 남으면 혼란스럽다)
    final captions = state.captions
        .map((c) => c.speaker?.key == speaker.key
            ? c.copyWith(speaker: speaker)
            : c)
        .toList(growable: false);

    state = state.copyWith(speakers: speakers, captions: captions);
  }

  // ================================================================ 화자 편집

  void renameSpeaker(String key, String name) {
    _client?.renameSpeaker(key, name);
    // 서버 응답을 기다리지 않고 즉시 반영한다 — 라이브 중에는 반응성이 중요하다.
    final speaker = state.speakers.firstWhere(
      (s) => s.key == key,
      orElse: () => Speaker(key: key, label: key, colorHex: '#5F6368'),
    );
    _upsertSpeaker(speaker.copyWith(displayName: name));
  }

  void recolorSpeaker(String key, String colorHex) {
    _client?.recolorSpeaker(key, colorHex);
    final speaker = state.speakers.firstWhere(
      (s) => s.key == key,
      orElse: () => Speaker(key: key, label: key, colorHex: colorHex),
    );
    _upsertSpeaker(speaker.copyWith(colorHex: colorHex));
  }

  void clearError() => state = state.copyWith(clearError: true);

  @override
  void dispose() {
    unawaited(_teardown());
    super.dispose();
  }
}

final liveControllerProvider =
    StateNotifierProvider.autoDispose<LiveController, LiveState>((ref) {
  final controller = LiveController(
    api: ref.watch(apiClientProvider),
    capture: ref.watch(audioCaptureProvider),
  );
  // 화면을 벗어나면 마이크와 소켓을 반드시 놓아준다.
  ref.onDispose(controller.dispose);
  return controller;
});
