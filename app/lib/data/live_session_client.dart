import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

import '../core/env.dart';
import '../domain/entities/caption.dart';

/// 라이브 자막 WebSocket 클라이언트.
///
/// 백엔드 프로토콜은 `backend/app/api/v1/live.py` 상단 주석에 정의되어 있다.
/// 이 클래스는 그 프로토콜을 앱이 다루기 좋은 타입 이벤트로 바꾼다.
class LiveSessionClient {
  LiveSessionClient();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  final _events = StreamController<LiveEvent>.broadcast();
  Timer? _keepAlive;

  bool _closedByUs = false;
  bool get isConnected => _channel != null;

  Stream<LiveEvent> get events => _events.stream;

  /// 서버로 실제 전송된 오디오 바이트. 진단 표시에 쓴다.
  int bytesSent = 0;

  // ================================================================ 연결

  Future<void> connect({
    required String sessionId,
    required String ticket,
  }) async {
    if (_channel != null) {
      throw StateError('이미 연결되어 있습니다.');
    }
    _closedByUs = false;
    bytesSent = 0;

    final uri = Uri.parse(
      '${Env.wsBaseUrl}/api/v1/live/$sessionId/ws?ticket=$ticket',
    );

    try {
      final channel = WebSocketChannel.connect(uri);
      // ready 를 기다려야 연결 실패를 여기서 잡을 수 있다. 안 기다리면
      // 실패가 스트림 에러로만 나와 호출부가 성공한 줄 안다.
      await channel.ready.timeout(const Duration(seconds: 15));
      _channel = channel;
    } on TimeoutException {
      throw const LiveConnectionException('서버 연결이 지연되고 있습니다.');
    } on Object catch (error) {
      throw LiveConnectionException('실시간 자막 서버에 연결하지 못했습니다: $error');
    }

    _subscription = _channel!.stream.listen(
      _onMessage,
      onError: (Object error, StackTrace stack) {
        debugPrint('[LiveSession] 스트림 오류: $error');
        _events.add(
          LiveEvent.error(
            code: 'CONNECTION_ERROR',
            message: '실시간 자막 연결이 끊어졌습니다.',
          ),
        );
      },
      onDone: _onDone,
      cancelOnError: false,
    );

    // 오디오를 보내지 않는 조용한 구간에도 연결을 살려 둔다.
    _keepAlive = Timer.periodic(
      const Duration(seconds: 25),
      (_) => _sendControl({'type': 'ping'}),
    );
  }

  void _onMessage(dynamic raw) {
    if (raw is! String) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      final event = LiveEvent.fromJson(decoded);
      if (event != null) _events.add(event);
    } on FormatException catch (error) {
      debugPrint('[LiveSession] JSON 파싱 실패: $error');
    }
  }

  void _onDone() {
    final code = _channel?.closeCode;
    _cleanupTimers();

    if (_closedByUs) {
      _events.add(const LiveEvent.closed(graceful: true));
      return;
    }

    // 서버가 사설 코드로 이유를 알려준다 (live.py 참고).
    final message = switch (code) {
      4001 => '인증이 만료되었습니다. 다시 시도해 주세요.',
      4004 => '대화 세션을 찾을 수 없습니다.',
      4029 => '동시에 열 수 있는 실시간 자막 수를 초과했습니다.',
      4408 => '오디오 입력이 없어 자막이 종료되었습니다.',
      4409 => '최대 녹음 시간에 도달했습니다.',
      4500 => '서버 오류로 자막이 중단되었습니다.',
      _ => null,
    };

    if (message != null) {
      _events.add(LiveEvent.error(code: 'CLOSED_$code', message: message));
    }
    _events.add(const LiveEvent.closed(graceful: false));
  }

  // ================================================================ 송신

  /// PCM16 오디오 청크 전송.
  void sendAudio(Uint8List pcm) {
    final channel = _channel;
    if (channel == null || pcm.isEmpty) return;
    try {
      channel.sink.add(pcm);
      bytesSent += pcm.lengthInBytes;
    } on Object catch (error) {
      debugPrint('[LiveSession] 오디오 전송 실패: $error');
    }
  }

  void renameSpeaker(String key, String name) =>
      _sendControl({'type': 'rename_speaker', 'key': key, 'name': name});

  void recolorSpeaker(String key, String colorHex) =>
      _sendControl({'type': 'recolor_speaker', 'key': key, 'color': colorHex});

  void _sendControl(Map<String, dynamic> message) {
    final channel = _channel;
    if (channel == null) return;
    try {
      channel.sink.add(jsonEncode(message));
    } on Object catch (error) {
      debugPrint('[LiveSession] 제어 메시지 전송 실패: $error');
    }
  }

  // ================================================================ 종료

  /// 정상 종료. 서버가 남은 오디오를 마저 처리하고 세션을 확정한다.
  Future<void> stop() async {
    if (_channel == null) return;
    _closedByUs = true;
    _sendControl({'type': 'stop'});

    // 서버가 session.ended 를 보낼 시간을 준다. 바로 끊으면 마지막 자막과
    // 세션 요약이 저장되지 않는다.
    await _events.stream
        .firstWhere((event) => event.type == LiveEventType.sessionEnded)
        .timeout(const Duration(seconds: 8))
        .catchError((_) => const LiveEvent.closed(graceful: true));

    await _close(ws_status.normalClosure);
  }

  /// 즉시 종료 (화면 이탈 등).
  Future<void> abort() async {
    _closedByUs = true;
    await _close(ws_status.goingAway);
  }

  Future<void> _close(int code) async {
    _cleanupTimers();
    await _subscription?.cancel();
    _subscription = null;
    try {
      await _channel?.sink.close(code);
    } on Object {
      // 이미 끊긴 소켓을 닫는 것은 오류가 아니다.
    }
    _channel = null;
  }

  void _cleanupTimers() {
    _keepAlive?.cancel();
    _keepAlive = null;
  }

  Future<void> dispose() async {
    await abort();
    await _events.close();
  }
}

// ===================================================================== 이벤트

enum LiveEventType {
  sessionStarted,
  captionPartial,
  captionFinal,
  captionUpdated,
  speakerAdded,
  status,
  error,
  sessionEnded,
  closed,
}

@immutable
class LiveEvent {
  // code / graceful 은 각각 .error / .closed 전용이라 여기서는 받지 않는다.
  const LiveEvent._({
    required this.type,
    this.caption,
    this.speaker,
    this.partialText,
    this.sequence,
    this.captionId,
    this.text,
    this.startMs,
    this.tone,
    this.toneConfidence,
    this.toneBasis,
    this.speakerUnknown = false,
    this.message,
    this.state,
    this.summary,
  })  : code = null,
        graceful = false;

  final LiveEventType type;

  /// caption.final
  final Caption? caption;

  /// speaker.added
  final Speaker? speaker;

  /// caption.partial
  final String? partialText;

  /// caption.updated — 어느 줄을 고칠지
  final int? sequence;
  final String? captionId;

  /// caption.updated — 문장 자체가 바뀐 경우에만 실린다.
  ///
  /// 쉬는 텀 없이 화자가 바뀌면 실시간 트랙이 두 사람의 말을 한 줄로 묶는다.
  /// 서버가 나중에 화자분리 결과로 그 줄을 나누면서 첫 조각의 문장을 보낸다.
  final String? text;
  final int? startMs;
  final String? tone;
  final double? toneConfidence;

  /// 톤 판정의 근거. 운율 판정이 LLM 판정으로 올라가면 함께 바뀐다.
  final String? toneBasis;

  /// 화자 판정을 끝냈으나 특정하지 못한 경우
  final bool speakerUnknown;

  /// error
  final String? code;
  final String? message;

  /// status
  final String? state;

  /// session.ended
  final Map<String, dynamic>? summary;

  /// closed
  final bool graceful;

  const LiveEvent.error({required String this.code, required String this.message})
      : type = LiveEventType.error,
        caption = null,
        speaker = null,
        partialText = null,
        sequence = null,
        captionId = null,
        text = null,
        startMs = null,
        tone = null,
        toneConfidence = null,
        toneBasis = null,
        speakerUnknown = false,
        state = null,
        summary = null,
        graceful = false;

  const LiveEvent.closed({required this.graceful})
      : type = LiveEventType.closed,
        caption = null,
        speaker = null,
        partialText = null,
        sequence = null,
        captionId = null,
        text = null,
        startMs = null,
        tone = null,
        toneConfidence = null,
        toneBasis = null,
        speakerUnknown = false,
        code = null,
        message = null,
        state = null,
        summary = null;

  static LiveEvent? fromJson(Map<String, dynamic> json) {
    final rawType = json['type'] as String?;
    final data = json['data'] as Map<String, dynamic>? ?? const {};

    switch (rawType) {
      case 'session.started':
        return const LiveEvent._(type: LiveEventType.sessionStarted);

      case 'caption.partial':
        return LiveEvent._(
          type: LiveEventType.captionPartial,
          partialText: data['text'] as String? ?? '',
          sequence: (data['sequence'] as num?)?.toInt(),
        );

      case 'caption.final':
        return LiveEvent._(
          type: LiveEventType.captionFinal,
          caption: Caption.fromLiveJson(data),
        );

      case 'caption.updated':
        final speakerJson = data['speaker'] as Map<String, dynamic>?;
        return LiveEvent._(
          type: LiveEventType.captionUpdated,
          sequence: (data['sequence'] as num?)?.toInt(),
          captionId: data['id'] as String?,
          // 한 줄에 두 사람이 섞여 있었으면 서버가 줄을 나누면서 이 줄의
          // 문장 자체를 고쳐 보낸다. 화자만 확정하는 patch 에는 없다.
          text: data['text'] as String?,
          startMs: (data['start_ms'] as num?)?.toInt(),
          speaker:
              speakerJson == null ? null : Speaker.fromLiveJson(speakerJson),
          speakerUnknown: data['speaker_unknown'] as bool? ?? false,
          tone: data['tone'] as String?,
          toneConfidence: (data['tone_confidence'] as num?)?.toDouble(),
          toneBasis: data['tone_basis'] as String?,
        );

      case 'speaker.added':
        return LiveEvent._(
          type: LiveEventType.speakerAdded,
          speaker: Speaker.fromLiveJson(data),
        );

      case 'status':
        return LiveEvent._(
          type: LiveEventType.status,
          state: data['state'] as String?,
          message: data['message'] as String?,
        );

      case 'error':
        return LiveEvent.error(
          code: data['code'] as String? ?? 'UNKNOWN',
          message: data['message'] as String? ?? '알 수 없는 오류가 발생했습니다.',
        );

      case 'session.ended':
        return LiveEvent._(
          type: LiveEventType.sessionEnded,
          summary: data,
        );

      default:
        // 서버에 새 이벤트가 생겨도 구버전 앱이 죽지 않아야 한다.
        return null;
    }
  }
}

class LiveConnectionException implements Exception {
  const LiveConnectionException(this.message);
  final String message;

  @override
  String toString() => message;
}
