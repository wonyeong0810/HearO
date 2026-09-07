import 'package:flutter/foundation.dart';

import 'caption.dart';
import 'emotion_tone.dart';

/// 대화 세션 요약 (목록 화면용).
@immutable
class ConversationSummary {
  const ConversationSummary({
    required this.id,
    required this.startedAt,
    required this.status,
    this.title,
    this.endedAt,
    this.durationSeconds = 0,
    this.locationLabel,
    this.latitude,
    this.longitude,
    this.isFavorite = false,
    this.utteranceCount = 0,
    this.speakerCount = 0,
    this.previewText,
    this.dominantTone,
  });

  final String id;
  final DateTime startedAt;
  final SessionStatus status;

  final String? title;
  final DateTime? endedAt;
  final double durationSeconds;

  final String? locationLabel;
  final double? latitude;
  final double? longitude;

  final bool isFavorite;
  final int utteranceCount;
  final int speakerCount;
  final String? previewText;
  final EmotionTone? dominantTone;

  Duration get duration => Duration(seconds: durationSeconds.round());

  /// 제목이 없으면 시작 시각으로 대신한다.
  String get displayTitle {
    if (title != null && title!.trim().isNotEmpty) return title!;
    if (locationLabel != null && locationLabel!.trim().isNotEmpty) {
      return '${locationLabel!}에서의 대화';
    }
    return '이름 없는 대화';
  }

  ConversationSummary copyWith({
    String? title,
    bool? isFavorite,
    String? locationLabel,
  }) {
    return ConversationSummary(
      id: id,
      startedAt: startedAt,
      status: status,
      title: title ?? this.title,
      endedAt: endedAt,
      durationSeconds: durationSeconds,
      locationLabel: locationLabel ?? this.locationLabel,
      latitude: latitude,
      longitude: longitude,
      isFavorite: isFavorite ?? this.isFavorite,
      utteranceCount: utteranceCount,
      speakerCount: speakerCount,
      previewText: previewText,
      dominantTone: dominantTone,
    );
  }

  factory ConversationSummary.fromJson(Map<String, dynamic> json) {
    return ConversationSummary(
      id: json['id'] as String,
      startedAt: DateTime.parse(json['started_at'] as String).toLocal(),
      status: SessionStatus.fromWire(json['status'] as String?),
      title: json['title'] as String?,
      endedAt: json['ended_at'] == null
          ? null
          : DateTime.parse(json['ended_at'] as String).toLocal(),
      durationSeconds: (json['duration_seconds'] as num?)?.toDouble() ?? 0,
      locationLabel: json['location_label'] as String?,
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      isFavorite: json['is_favorite'] as bool? ?? false,
      utteranceCount: (json['utterance_count'] as num?)?.toInt() ?? 0,
      speakerCount: (json['speaker_count'] as num?)?.toInt() ?? 0,
      previewText: json['preview_text'] as String?,
      dominantTone: json['dominant_tone'] == null
          ? null
          : EmotionTone.fromWire(json['dominant_tone'] as String?),
    );
  }
}

/// 대화 상세 (자막 전체 포함).
@immutable
class ConversationDetail {
  const ConversationDetail({
    required this.summary,
    required this.speakers,
    required this.captions,
  });

  final ConversationSummary summary;
  final List<Speaker> speakers;
  final List<Caption> captions;

  factory ConversationDetail.fromJson(Map<String, dynamic> json) {
    return ConversationDetail(
      summary: ConversationSummary.fromJson(json),
      speakers: (json['speakers'] as List<dynamic>? ?? [])
          .map((e) => Speaker.fromApiJson(e as Map<String, dynamic>))
          .toList(growable: false),
      captions: (json['utterances'] as List<dynamic>? ?? [])
          .map((e) => Caption.fromApiJson(e as Map<String, dynamic>))
          .toList(growable: false),
    );
  }
}

/// 자막 본문 검색 결과 한 건.
@immutable
class CaptionSearchHit {
  const CaptionSearchHit({
    required this.sessionId,
    required this.sessionStartedAt,
    required this.captionId,
    required this.sequence,
    required this.text,
    required this.startMs,
    required this.tone,
    this.sessionTitle,
    this.speakerLabel,
    this.speakerName,
    this.speakerColor,
  });

  final String sessionId;
  final DateTime sessionStartedAt;
  final String captionId;
  final int sequence;
  final String text;
  final int startMs;
  final EmotionTone tone;
  final String? sessionTitle;
  final String? speakerLabel;
  final String? speakerName;
  final String? speakerColor;

  String get speakerDisplay =>
      speakerName ?? (speakerLabel == null ? '화자 미상' : '화자 $speakerLabel');

  factory CaptionSearchHit.fromJson(Map<String, dynamic> json) {
    return CaptionSearchHit(
      sessionId: json['session_id'] as String,
      sessionStartedAt:
          DateTime.parse(json['session_started_at'] as String).toLocal(),
      captionId: json['utterance_id'] as String,
      sequence: (json['sequence'] as num?)?.toInt() ?? 0,
      text: json['text'] as String? ?? '',
      startMs: (json['start_ms'] as num?)?.toInt() ?? 0,
      tone: EmotionTone.fromWire(json['tone'] as String?),
      sessionTitle: json['session_title'] as String?,
      speakerLabel: json['speaker_label'] as String?,
      speakerName: json['speaker_name'] as String?,
      speakerColor: json['speaker_color'] as String?,
    );
  }
}

/// 경보 기록 한 건.
@immutable
class AlertRecord {
  const AlertRecord({
    required this.id,
    required this.type,
    required this.confidence,
    required this.detectedAt,
    this.sessionId,
    this.locationLabel,
    this.latitude,
    this.longitude,
    this.acknowledgedAt,
    this.isFalsePositive = false,
    this.consecutiveFrames = 1,
    this.rawClass,
  });

  final String id;
  final AlertType type;
  final double confidence;
  final DateTime detectedAt;
  final String? sessionId;
  final String? locationLabel;
  final double? latitude;
  final double? longitude;
  final DateTime? acknowledgedAt;
  final bool isFalsePositive;
  final int consecutiveFrames;
  final String? rawClass;

  bool get isAcknowledged => acknowledgedAt != null;

  factory AlertRecord.fromJson(Map<String, dynamic> json) {
    return AlertRecord(
      id: json['id'] as String,
      type: AlertType.fromWire(json['alert_type'] as String?),
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
      detectedAt: DateTime.parse(json['detected_at'] as String).toLocal(),
      sessionId: json['session_id'] as String?,
      locationLabel: json['location_label'] as String?,
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      acknowledgedAt: json['acknowledged_at'] == null
          ? null
          : DateTime.parse(json['acknowledged_at'] as String).toLocal(),
      isFalsePositive: json['is_false_positive'] as bool? ?? false,
      consecutiveFrames: (json['consecutive_frames'] as num?)?.toInt() ?? 1,
      rawClass: json['raw_class'] as String?,
    );
  }
}

/// 페이지 응답 래퍼.
@immutable
class Paged<T> {
  const Paged({
    required this.items,
    required this.total,
    required this.limit,
    required this.offset,
  });

  final List<T> items;
  final int total;
  final int limit;
  final int offset;

  bool get hasMore => offset + items.length < total;
  int get nextOffset => offset + items.length;

  factory Paged.fromJson(
    Map<String, dynamic> json,
    T Function(Map<String, dynamic>) parse,
  ) {
    return Paged(
      items: (json['items'] as List<dynamic>? ?? [])
          .map((e) => parse(e as Map<String, dynamic>))
          .toList(growable: false),
      total: (json['total'] as num?)?.toInt() ?? 0,
      limit: (json['limit'] as num?)?.toInt() ?? 20,
      offset: (json['offset'] as num?)?.toInt() ?? 0,
    );
  }

  static const Paged<Never> empty =
      Paged<Never>(items: [], total: 0, limit: 20, offset: 0);
}

/// 사용자 설정.
@immutable
class AppSettings {
  const AppSettings({
    this.logRetentionDays = 90,
    this.autoDeleteEnabled = true,
    this.captionTextScale = 1.0,
    this.loudnessScalingEnabled = true,
    this.emotionAnimationEnabled = true,
    this.highContrastMode = false,
    this.alertsEnabled = true,
    this.alertVibrationEnabled = true,
    this.alertFlashEnabled = true,
    this.alertTorchStrobeEnabled = false,
    this.alertSensitivity = 0.55,
    this.locationTaggingEnabled = false,
  });

  final int logRetentionDays;
  final bool autoDeleteEnabled;
  final double captionTextScale;
  final bool loudnessScalingEnabled;
  final bool emotionAnimationEnabled;
  final bool highContrastMode;
  final bool alertsEnabled;
  final bool alertVibrationEnabled;
  final bool alertFlashEnabled;
  final bool alertTorchStrobeEnabled;
  final double alertSensitivity;
  final bool locationTaggingEnabled;

  AppSettings copyWith({
    int? logRetentionDays,
    bool? autoDeleteEnabled,
    double? captionTextScale,
    bool? loudnessScalingEnabled,
    bool? emotionAnimationEnabled,
    bool? highContrastMode,
    bool? alertsEnabled,
    bool? alertVibrationEnabled,
    bool? alertFlashEnabled,
    bool? alertTorchStrobeEnabled,
    double? alertSensitivity,
    bool? locationTaggingEnabled,
  }) {
    return AppSettings(
      logRetentionDays: logRetentionDays ?? this.logRetentionDays,
      autoDeleteEnabled: autoDeleteEnabled ?? this.autoDeleteEnabled,
      captionTextScale: captionTextScale ?? this.captionTextScale,
      loudnessScalingEnabled:
          loudnessScalingEnabled ?? this.loudnessScalingEnabled,
      emotionAnimationEnabled:
          emotionAnimationEnabled ?? this.emotionAnimationEnabled,
      highContrastMode: highContrastMode ?? this.highContrastMode,
      alertsEnabled: alertsEnabled ?? this.alertsEnabled,
      alertVibrationEnabled:
          alertVibrationEnabled ?? this.alertVibrationEnabled,
      alertFlashEnabled: alertFlashEnabled ?? this.alertFlashEnabled,
      alertTorchStrobeEnabled:
          alertTorchStrobeEnabled ?? this.alertTorchStrobeEnabled,
      alertSensitivity: alertSensitivity ?? this.alertSensitivity,
      locationTaggingEnabled:
          locationTaggingEnabled ?? this.locationTaggingEnabled,
    );
  }

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    return AppSettings(
      logRetentionDays: (json['log_retention_days'] as num?)?.toInt() ?? 90,
      autoDeleteEnabled: json['auto_delete_enabled'] as bool? ?? true,
      captionTextScale:
          (json['caption_text_scale'] as num?)?.toDouble() ?? 1.0,
      loudnessScalingEnabled:
          json['loudness_scaling_enabled'] as bool? ?? true,
      emotionAnimationEnabled:
          json['emotion_animation_enabled'] as bool? ?? true,
      highContrastMode: json['high_contrast_mode'] as bool? ?? false,
      alertsEnabled: json['alerts_enabled'] as bool? ?? true,
      alertVibrationEnabled: json['alert_vibration_enabled'] as bool? ?? true,
      alertFlashEnabled: json['alert_flash_enabled'] as bool? ?? true,
      alertTorchStrobeEnabled:
          json['alert_torch_strobe_enabled'] as bool? ?? false,
      alertSensitivity: (json['alert_sensitivity'] as num?)?.toDouble() ?? 0.55,
      locationTaggingEnabled:
          json['location_tagging_enabled'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
        'log_retention_days': logRetentionDays,
        'auto_delete_enabled': autoDeleteEnabled,
        'caption_text_scale': captionTextScale,
        'loudness_scaling_enabled': loudnessScalingEnabled,
        'emotion_animation_enabled': emotionAnimationEnabled,
        'high_contrast_mode': highContrastMode,
        'alerts_enabled': alertsEnabled,
        'alert_vibration_enabled': alertVibrationEnabled,
        'alert_flash_enabled': alertFlashEnabled,
        'alert_torch_strobe_enabled': alertTorchStrobeEnabled,
        'alert_sensitivity': alertSensitivity,
        'location_tagging_enabled': locationTaggingEnabled,
      };
}
