import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearo/core/theme/app_theme.dart';
import 'package:hearo/core/theme/emotion_style.dart';
import 'package:hearo/domain/entities/emotion_tone.dart';

void main() {
  group('CaptionSizing — 말의 세기를 글자 크기로 (기획 1-3)', () {
    test('크게 말할수록 글자가 커진다', () {
      final quiet = CaptionSizing.resolve(
        intensity: 0.1,
        userScale: 1,
        loudnessScaling: true,
      );
      final normal = CaptionSizing.resolve(
        intensity: 0.5,
        userScale: 1,
        loudnessScaling: true,
      );
      final loud = CaptionSizing.resolve(
        intensity: 0.95,
        userScale: 1,
        loudnessScaling: true,
      );

      expect(quiet, lessThan(normal));
      expect(normal, lessThan(loud));
    });

    test('보통 세기(0.5)는 기준 크기와 같다', () {
      expect(
        CaptionSizing.resolve(
          intensity: 0.5,
          userScale: 1,
          loudnessScaling: true,
        ),
        closeTo(CaptionSizing.base, 0.01),
      );
    });

    test('음량 연동을 끄면 세기와 무관하게 고정된다', () {
      final quiet = CaptionSizing.resolve(
        intensity: 0.05,
        userScale: 1,
        loudnessScaling: false,
      );
      final loud = CaptionSizing.resolve(
        intensity: 0.95,
        userScale: 1,
        loudnessScaling: false,
      );

      expect(quiet, equals(loud));
    });

    test('사용자 배율이 곱해진다', () {
      final base = CaptionSizing.resolve(
        intensity: 0.5,
        userScale: 1,
        loudnessScaling: true,
      );
      final doubled = CaptionSizing.resolve(
        intensity: 0.5,
        userScale: 2,
        loudnessScaling: true,
      );

      expect(doubled, closeTo(base * 2, 0.01));
    });

    test('극단값에서도 읽을 수 있는 범위를 벗어나지 않는다', () {
      // 너무 작으면 저시력 사용자가 못 읽고, 너무 크면 한 줄도 안 들어간다.
      for (final intensity in [0.0, 0.5, 1.0]) {
        for (final scale in [0.5, 1.0, 3.0]) {
          final size = CaptionSizing.resolve(
            intensity: intensity,
            userScale: scale,
            loudnessScaling: true,
          );
          expect(size, greaterThanOrEqualTo(14.0));
          expect(size, lessThanOrEqualTo(80.0));
        }
      }
    });

    test('세기가 클수록 글자가 굵어진다', () {
      expect(
        CaptionSizing.weightFor(0.9).value,
        greaterThan(CaptionSizing.weightFor(0.2).value),
      );
    });
  });

  group('EmotionEmphasis — 신뢰도에 따른 표현 강도', () {
    EmotionEmphasis emphasis(double confidence) =>
        EmotionEmphasis.fromConfidence(
          confidence,
          animationsEnabled: true,
          reduceMotion: false,
        );

    test('신뢰도가 낮으면 감정을 표시하지 않는다', () {
      // 틀린 감정을 자신 있게 보여주는 것이 안 보여주는 것보다 해롭다.
      final result = emphasis(0.2);
      expect(result.showLabel, isFalse);
      expect(result.motionScale, 0);
    });

    test('중간 신뢰도에서는 라벨만 보여주고 움직이지 않는다', () {
      final result = emphasis(0.5);
      expect(result.showLabel, isTrue);
      expect(result.motionScale, 0);
    });

    test('높은 신뢰도에서만 움직임을 준다', () {
      final result = emphasis(0.95);
      expect(result.showLabel, isTrue);
      expect(result.motionScale, greaterThan(0.5));
    });

    test('"동작 줄이기"가 켜져 있으면 신뢰도가 높아도 움직이지 않는다', () {
      final result = EmotionEmphasis.fromConfidence(
        0.95,
        animationsEnabled: true,
        reduceMotion: true,
      );
      expect(result.showLabel, isTrue, reason: '라벨은 계속 보여야 한다');
      expect(result.motionScale, 0);
    });

    test('감정 애니메이션 설정을 끄면 움직이지 않는다', () {
      final result = EmotionEmphasis.fromConfidence(
        0.95,
        animationsEnabled: false,
        reduceMotion: false,
      );
      expect(result.motionScale, 0);
    });
  });

  group('EmotionStyle — 색 이외의 단서', () {
    test('모든 감정에 아이콘과 한국어 라벨이 있다', () {
      // 색각이상 사용자와 흑백 환경에서도 감정이 전달되어야 한다.
      for (final tone in EmotionTone.values) {
        final style = EmotionStyle.of(tone);
        expect(style.label, isNotEmpty);
        expect(style.description, isNotEmpty);
        expect(style.icon, isNotNull);
      }
    });

    test('감정마다 서로 다른 아이콘을 쓴다', () {
      final icons = EmotionTone.values
          .map((tone) => EmotionStyle.of(tone).icon.codePoint)
          .toSet();
      expect(icons.length, EmotionTone.values.length);
    });

    test('라이트/다크 각각에 색이 정의되어 있다', () {
      for (final tone in EmotionTone.values) {
        final style = EmotionStyle.of(tone);
        expect(style.colorOf(Brightness.light), isNot(Colors.transparent));
        expect(style.colorOf(Brightness.dark), isNot(Colors.transparent));
      }
    });
  });

  group('EmotionStyle — 문구가 감정을 단정하지 않는다', () {
    // 사용자는 화면에 뜬 말을 사실로 받아들인다. 그런데 이 판정은 목소리와
    // 문장에서 나온 추정이고, 개인차에 크게 흔들린다 — 원래 목소리가 큰 사람,
    // 사투리, 신나서 흥분한 사람, 말투 특성이 다른 사람, 문화·연령 차이.
    // 소리를 못 듣는 사용자는 이걸 직접 검증할 수도 없다.
    //
    // 그래서 문구가 "상대의 감정"이 아니라 "우리가 관찰한 말투"를 가리켜야 한다.
    // 나중에 누군가 짧게 줄이려고 "화남" 으로 되돌리면 여기서 걸린다.

    /// 사람의 감정 상태를 단정하는 표현들.
    const assertive = ['화남', '기쁨', '슬픔', '격앙됨', '중립', '차분함'];

    test('감정 상태를 단정하는 낱말을 쓰지 않는다', () {
      for (final tone in EmotionTone.values) {
        final style = EmotionStyle.of(tone);
        for (final word in assertive) {
          expect(style.label, isNot(word), reason: '$tone 의 짧은 이름');
          expect(style.heardPhrase, isNot(contains(word)),
              reason: '$tone 의 자막 문구');
        }
      }
    });

    test('중립을 뺀 모든 톤이 관찰 표현("들림")으로 끝난다', () {
      // 중립은 "그렇게 들렸다"가 아니라 "잡히는 특징이 없다"라서 예외다.
      for (final tone in EmotionTone.values) {
        if (tone == EmotionTone.neutral) continue;
        expect(EmotionStyle.of(tone).heardPhrase, endsWith('들림'),
            reason: '$tone');
      }
    });

    test('신뢰도가 낮으면 문구 자체가 약해진다', () {
      // 예전에는 확신의 정도가 색 진하기와 움직임으로만 나타났다. 둘 다 옆에
      // 비교할 자막이 있어야 읽히는 신호이고, 흑백·색각이상·저시력에서는
      // 사라진다. 한 줄만 보고도 알 수 있어야 한다.
      const args = (animationsEnabled: true, reduceMotion: false);
      final tentative = EmotionEmphasis.fromConfidence(0.45,
          animationsEnabled: args.animationsEnabled,
          reduceMotion: args.reduceMotion);
      final confident = EmotionEmphasis.fromConfidence(0.85,
          animationsEnabled: args.animationsEnabled,
          reduceMotion: args.reduceMotion);

      expect(tentative.isTentative, isTrue);
      expect(confident.isTentative, isFalse);

      for (final tone in EmotionTone.values) {
        if (tone == EmotionTone.neutral) continue;
        final style = EmotionStyle.of(tone);
        expect(style.phraseFor(tentative), isNot(style.phraseFor(confident)),
            reason: '$tone — 확신이 달라도 문구가 같으면 구분이 안 된다');
        expect(style.phraseFor(tentative), style.tentativePhrase);
        expect(style.phraseFor(confident), style.heardPhrase);
      }
    });

    test('표시하지 않는 구간은 tentative 로 세지 않는다', () {
      final hidden = EmotionEmphasis.fromConfidence(0.2,
          animationsEnabled: true, reduceMotion: false);
      expect(hidden.showLabel, isFalse);
      expect(hidden.isTentative, isFalse);
    });
  });

  group('ToneBasis', () {
    test('모르는 값과 누락은 약한 쪽(목소리만)으로 떨어진다', () {
      // 근거를 부풀려 말하는 것이 가장 나쁘다. 구버전 서버나 이 필드가 없던
      // 시절의 기록이 "문장까지 봤다"로 보이면 사용자가 과신하게 된다.
      expect(ToneBasis.fromWire(null), ToneBasis.voice);
      expect(ToneBasis.fromWire('nonsense'), ToneBasis.voice);
      expect(ToneBasis.fromWire('voice_text'), ToneBasis.voiceText);
    });

    test('두 근거의 설명이 서로 다르다', () {
      expect(ToneBasis.voice.labelKo, isNot(ToneBasis.voiceText.labelKo));
    });
  });
}
