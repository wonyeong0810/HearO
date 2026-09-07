import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearo/domain/entities/caption.dart';
import 'package:hearo/domain/entities/conversation.dart';
import 'package:hearo/domain/entities/emotion_tone.dart';

void main() {
  group('EmotionTone 직렬화', () {
    test('백엔드 값과 왕복한다', () {
      for (final tone in EmotionTone.values) {
        expect(EmotionTone.fromWire(tone.wireValue), tone);
      }
    });

    test('알 수 없는 값은 neutral 로 떨어진다', () {
      // 백엔드에 새 감정이 추가되어도 구버전 앱이 죽으면 안 된다.
      expect(EmotionTone.fromWire('surprised'), EmotionTone.neutral);
      expect(EmotionTone.fromWire(null), EmotionTone.neutral);
      expect(EmotionTone.fromWire(''), EmotionTone.neutral);
    });
  });

  group('AlertType', () {
    test('백엔드 값과 왕복한다', () {
      for (final type in AlertType.values) {
        expect(AlertType.fromWire(type.wireValue), type);
      }
    });

    test('화재·민방위가 가장 높은 심각도를 가진다', () {
      expect(AlertType.fireAlarm.severity, 3);
      expect(AlertType.smokeDetector.severity, 3);
      expect(AlertType.civilDefenseSiren.severity, 3);
      expect(
        AlertType.emergencyVehicle.severity,
        lessThan(AlertType.fireAlarm.severity),
      );
    });

    test('모든 경보에 행동 지침이 있다', () {
      // 소리를 못 듣는 상황에서는 "무슨 소리인가"보다 "어떻게 해야 하나"가 중요하다.
      for (final type in AlertType.values) {
        expect(type.guidance, isNotEmpty);
        expect(type.labelKo, isNotEmpty);
      }
    });
  });

  group('Speaker', () {
    test('라이브 JSON 을 파싱한다', () {
      final speaker = Speaker.fromLiveJson(const {
        'key': 'S1',
        'label': 'A',
        'color_hex': '#2563EB',
        'display_name': null,
      });

      expect(speaker.key, 'S1');
      expect(speaker.label, 'A');
      expect(speaker.color, const Color(0xFF2563EB));
    });

    test('이름이 없으면 "화자 A" 로 표시한다', () {
      const speaker = Speaker(key: 'S1', label: 'A', colorHex: '#2563EB');
      expect(speaker.displayLabel, '화자 A');
    });

    test('사용자가 붙인 이름이 우선한다', () {
      const speaker = Speaker(
        key: 'S1',
        label: 'A',
        colorHex: '#2563EB',
        displayName: '엄마',
      );
      expect(speaker.displayLabel, '엄마');
    });

    test('잘못된 색상값에도 죽지 않는다', () {
      const speaker = Speaker(key: 'S1', label: 'A', colorHex: 'not-a-color');
      expect(speaker.color, const Color(0xFF5F6368));
    });
  });

  group('Caption', () {
    test('라이브 JSON 을 파싱한다', () {
      final caption = Caption.fromLiveJson(const {
        'id': 'abc',
        'sequence': 3,
        'text': '안녕하세요',
        'start_ms': 1000,
        'end_ms': 2500,
        'intensity': 0.8,
        'tone': 'happy',
        'tone_confidence': 0.72,
        'speaker': {
          'key': 'S1',
          'label': 'A',
          'color_hex': '#2563EB',
        },
        'speaker_resolved': true,
      });

      expect(caption.text, '안녕하세요');
      expect(caption.tone, EmotionTone.happy);
      expect(caption.intensity, 0.8);
      expect(caption.speaker?.key, 'S1');
      expect(caption.speakerResolved, isTrue);
    });

    test('화자 없이 도착한 자막은 "확인 중" 상태다', () {
      const caption = Caption(sequence: 1, text: '테스트');
      expect(caption.isAwaitingSpeaker, isTrue);
    });

    test('화자를 특정하지 못한 채 판정이 끝나면 확인 중이 아니다', () {
      // 2트랙 파이프라인에서 화자분리가 실패한 경우 — 영원히 회색으로
      // 남지 않고 "화자 미상"으로 확정되어야 한다.
      const caption =
          Caption(sequence: 1, text: '테스트', speakerResolved: true);
      expect(caption.isAwaitingSpeaker, isFalse);
    });

    test('copyWith 로 화자를 지울 수 있다', () {
      const caption = Caption(
        sequence: 1,
        text: '테스트',
        speaker: Speaker(key: 'S1', label: 'A', colorHex: '#2563EB'),
      );
      final cleared = caption.copyWith(clearSpeaker: true);
      expect(cleared.speaker, isNull);
    });

    test('누락된 필드에 기본값을 쓴다', () {
      final caption = Caption.fromLiveJson(const {});
      expect(caption.text, '');
      expect(caption.tone, EmotionTone.neutral);
      expect(caption.intensity, 0.5);
    });
  });

  group('ConversationSummary', () {
    Map<String, dynamic> baseJson() => {
          'id': 'session-1',
          'started_at': '2026-08-06T10:00:00Z',
          'status': 'ended',
          'utterance_count': 12,
        };

    test('제목이 없으면 위치로 대신한다', () {
      final summary = ConversationSummary.fromJson({
        ...baseJson(),
        'location_label': '병원',
      });
      expect(summary.displayTitle, '병원에서의 대화');
    });

    test('제목도 위치도 없으면 기본 문구를 쓴다', () {
      final summary = ConversationSummary.fromJson(baseJson());
      expect(summary.displayTitle, '이름 없는 대화');
    });

    test('제목이 있으면 그대로 쓴다', () {
      final summary = ConversationSummary.fromJson({
        ...baseJson(),
        'title': '팀 회의',
        'location_label': '회사',
      });
      expect(summary.displayTitle, '팀 회의');
    });
  });

  group('Paged', () {
    test('다음 페이지가 있는지 계산한다', () {
      const page = Paged<String>(items: ['a', 'b'], total: 10, limit: 2, offset: 0);
      expect(page.hasMore, isTrue);
      expect(page.nextOffset, 2);
    });

    test('마지막 페이지를 알아본다', () {
      const page = Paged<String>(items: ['a'], total: 3, limit: 2, offset: 2);
      expect(page.hasMore, isFalse);
    });
  });

  group('AppSettings', () {
    test('JSON 왕복', () {
      const original = AppSettings(
        captionTextScale: 1.4,
        alertSensitivity: 0.4,
        highContrastMode: true,
        logRetentionDays: 30,
      );
      final restored = AppSettings.fromJson(original.toJson());

      expect(restored.captionTextScale, 1.4);
      expect(restored.alertSensitivity, 0.4);
      expect(restored.highContrastMode, isTrue);
      expect(restored.logRetentionDays, 30);
    });

    test('빈 JSON 에서 안전한 기본값을 쓴다', () {
      final settings = AppSettings.fromJson(const {});
      expect(settings.alertsEnabled, isTrue, reason: '경보는 기본으로 켜져 있어야 한다');
      expect(settings.alertVibrationEnabled, isTrue);
      expect(settings.locationTaggingEnabled, isFalse,
          reason: '위치 수집은 명시적 동의가 있어야 한다');
    });
  });
}
