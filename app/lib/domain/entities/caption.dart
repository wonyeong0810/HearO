import 'package:flutter/material.dart';

import 'emotion_tone.dart';

/// 화자. 세션 안에서만 유효한 식별자를 가진다.
@immutable
class Speaker {
  const Speaker({
    required this.key,
    required this.label,
    required this.colorHex,
    this.id,
    this.displayName,
    this.utteranceCount = 0,
    this.totalSpeakingSeconds = 0,
  });

  /// 서버 내부 키 ("S1", "S2"). 라이브 중 화자 지정에 쓴다.
  final String key;

  /// 화면 기본 표시 ("A", "B", "C")
  final String label;

  /// "#RRGGBB"
  final String colorHex;

  /// 저장된 세션에서만 존재 (DB PK)
  final String? id;

  /// 사용자가 붙인 이름 ("엄마", "김 선생님")
  final String? displayName;

  final int utteranceCount;
  final double totalSpeakingSeconds;

  /// 화면에 실제로 보여줄 이름. 사용자가 이름을 붙였으면 그것을, 아니면 "화자 A".
  String get displayLabel => displayName ?? '화자 $label';

  Color get color => _parseHex(colorHex);

  Speaker copyWith({
    String? colorHex,
    String? displayName,
    String? id,
    int? utteranceCount,
    double? totalSpeakingSeconds,
  }) {
    return Speaker(
      key: key,
      label: label,
      colorHex: colorHex ?? this.colorHex,
      id: id ?? this.id,
      displayName: displayName ?? this.displayName,
      utteranceCount: utteranceCount ?? this.utteranceCount,
      totalSpeakingSeconds: totalSpeakingSeconds ?? this.totalSpeakingSeconds,
    );
  }

  factory Speaker.fromLiveJson(Map<String, dynamic> json) => Speaker(
        key: json['key'] as String? ?? '',
        label: json['label'] as String? ?? '?',
        colorHex: json['color_hex'] as String? ?? '#5F6368',
        displayName: json['display_name'] as String?,
      );

  factory Speaker.fromApiJson(Map<String, dynamic> json) => Speaker(
        // 저장된 세션에는 서버 내부 키가 없으므로 label 을 키로 쓴다.
        key: json['label'] as String? ?? '?',
        label: json['label'] as String? ?? '?',
        colorHex: json['color_hex'] as String? ?? '#5F6368',
        id: json['id'] as String?,
        displayName: json['display_name'] as String?,
        utteranceCount: (json['utterance_count'] as num?)?.toInt() ?? 0,
        totalSpeakingSeconds:
            (json['total_speaking_seconds'] as num?)?.toDouble() ?? 0,
      );

  @override
  bool operator ==(Object other) =>
      other is Speaker && other.key == key && other.colorHex == colorHex &&
      other.displayName == displayName;

  @override
  int get hashCode => Object.hash(key, colorHex, displayName);
}

/// 자막 한 줄.
///
/// 라이브 중에는 같은 줄이 세 단계를 거친다:
///   1. [isPartial] = true  — 실시간 트랙의 잠정 텍스트, 계속 바뀜
///   2. 확정 텍스트 + 운율 기반 임시 감정
///   3. 화자 확정 + 감정 확정 (백엔드가 patch 로 보냄)
@immutable
class Caption {
  const Caption({
    required this.sequence,
    required this.text,
    this.id,
    this.startMs = 0,
    this.endMs = 0,
    this.tone = EmotionTone.neutral,
    this.toneConfidence = 0,
    this.toneBasis = ToneBasis.voice,
    this.intensity = 0.5,
    this.loudnessDbfs,
    this.speaker,
    this.speakerResolved = false,
    this.isPartial = false,
    this.isBookmarked = false,
  });

  final int sequence;
  final String text;
  final String? id;

  /// 세션 시작 기준 오프셋
  final int startMs;
  final int endMs;

  final EmotionTone tone;
  final double toneConfidence;

  /// 이 톤이 무엇을 근거로 나왔는지. 사용자가 표시를 얼마나 믿을지 정하려면
  /// 결론뿐 아니라 근거를 알아야 한다 — 목소리만 본 판정은 사투리나 평소
  /// 목소리 크기 같은 개인차에 훨씬 약하다.
  final ToneBasis toneBasis;

  /// 0~1. 글자 크기와 굵기를 정하는 값 (기획 1-3 "말의 크기/세기").
  final double intensity;
  final double? loudnessDbfs;

  final Speaker? speaker;

  /// 화자분리 트랙이 판정을 마쳤는지. false 면 아직 "확인 중" 상태.
  final bool speakerResolved;

  /// 실시간 트랙의 잠정 텍스트인지
  final bool isPartial;

  final bool isBookmarked;

  Duration get offset => Duration(milliseconds: startMs);

  /// 화자가 아직 안 붙었고 판정도 안 끝난 상태
  bool get isAwaitingSpeaker => speaker == null && !speakerResolved;

  Caption copyWith({
    String? id,
    String? text,
    EmotionTone? tone,
    double? toneConfidence,
    ToneBasis? toneBasis,
    double? intensity,
    Speaker? speaker,
    bool clearSpeaker = false,
    bool? speakerResolved,
    bool? isPartial,
    bool? isBookmarked,
    int? startMs,
    int? endMs,
  }) {
    return Caption(
      sequence: sequence,
      text: text ?? this.text,
      id: id ?? this.id,
      // 서버가 한 줄을 화자별로 나누면 시작 지점도 함께 바뀐다.
      startMs: startMs ?? this.startMs,
      endMs: endMs ?? this.endMs,
      tone: tone ?? this.tone,
      toneConfidence: toneConfidence ?? this.toneConfidence,
      toneBasis: toneBasis ?? this.toneBasis,
      intensity: intensity ?? this.intensity,
      loudnessDbfs: loudnessDbfs,
      speaker: clearSpeaker ? null : (speaker ?? this.speaker),
      speakerResolved: speakerResolved ?? this.speakerResolved,
      isPartial: isPartial ?? this.isPartial,
      isBookmarked: isBookmarked ?? this.isBookmarked,
    );
  }

  factory Caption.fromLiveJson(Map<String, dynamic> json) {
    final speakerJson = json['speaker'] as Map<String, dynamic>?;
    return Caption(
      sequence: (json['sequence'] as num?)?.toInt() ?? 0,
      text: json['text'] as String? ?? '',
      id: json['id'] as String?,
      startMs: (json['start_ms'] as num?)?.toInt() ?? 0,
      endMs: (json['end_ms'] as num?)?.toInt() ?? 0,
      tone: EmotionTone.fromWire(json['tone'] as String?),
      toneConfidence: (json['tone_confidence'] as num?)?.toDouble() ?? 0,
      toneBasis: ToneBasis.fromWire(json['tone_basis'] as String?),
      intensity: (json['intensity'] as num?)?.toDouble() ?? 0.5,
      loudnessDbfs: (json['loudness_dbfs'] as num?)?.toDouble(),
      speaker: speakerJson == null ? null : Speaker.fromLiveJson(speakerJson),
      speakerResolved: json['speaker_resolved'] as bool? ?? false,
    );
  }

  factory Caption.fromApiJson(Map<String, dynamic> json) {
    final label = json['speaker_label'] as String?;
    return Caption(
      sequence: (json['sequence'] as num?)?.toInt() ?? 0,
      text: json['text'] as String? ?? '',
      id: json['id'] as String?,
      startMs: (json['start_ms'] as num?)?.toInt() ?? 0,
      endMs: (json['end_ms'] as num?)?.toInt() ?? 0,
      tone: EmotionTone.fromWire(json['tone'] as String?),
      toneConfidence: (json['tone_confidence'] as num?)?.toDouble() ?? 0,
      toneBasis: ToneBasis.fromWire(json['tone_basis'] as String?),
      intensity: (json['intensity'] as num?)?.toDouble() ?? 0.5,
      loudnessDbfs: (json['loudness_dbfs'] as num?)?.toDouble(),
      speaker: label == null
          ? null
          : Speaker(
              key: label,
              label: label,
              colorHex: json['speaker_color'] as String? ?? '#5F6368',
              id: json['speaker_id'] as String?,
              displayName: json['speaker_name'] as String?,
            ),
      speakerResolved: json['speaker_resolved'] as bool? ?? true,
      isBookmarked: json['is_bookmarked'] as bool? ?? false,
    );
  }
}

Color _parseHex(String hex) {
  final cleaned = hex.replaceFirst('#', '');
  final value = int.tryParse(cleaned, radix: 16);
  if (value == null || cleaned.length != 6) return const Color(0xFF5F6368);
  return Color(0xFF000000 | value);
}
