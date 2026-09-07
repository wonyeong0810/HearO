import 'package:flutter_test/flutter_test.dart';
import 'package:hearo/core/theme/emotion_style.dart';
import 'package:hearo/domain/entities/emotion_tone.dart';
import 'package:hearo/features/live/demo_script.dart';

/// 체험 모드 대본이 화면에 나올 수 있는 표현을 실제로 다 훑는지 확인한다.
///
/// 대본은 "그냥 예시 문장"이 아니라 **미리보기의 커버리지**다. 여기서 빠진
/// 표현은 사용자가 실제 대화 중에 처음 보게 되는데, 그때는 대화를 따라가느라
/// 화면을 뜯어볼 여유가 없다. 그래서 대본을 고칠 때 빠진 게 생기면 여기서
/// 걸리게 해 둔다.
void main() {
  group('대본 커버리지', () {
    test('감정 6종이 모두 나온다', () {
      final tones = demoScript.map((l) => l.tone).toSet();
      expect(tones, containsAll(EmotionTone.values),
          reason: '빠진 감정: '
              '${EmotionTone.values.toSet().difference(tones)}');
    });

    test('감정마다 정의된 움직임이 최소 한 번씩 실제로 재생된다', () {
      // 신뢰도가 0.6 미만이면 라벨만 붙고 움직이지 않는다. 움직임이 있는
      // 감정인데 대본이 전부 낮은 신뢰도면 그 애니메이션은 영영 안 보인다.
      final moving = <EmotionMotion>{};
      for (final line in demoScript) {
        final emphasis = EmotionEmphasis.fromConfidence(
          line.toneConfidence,
          animationsEnabled: true,
          reduceMotion: false,
        );
        if (emphasis.motionScale > 0) {
          moving.add(EmotionStyle.of(line.tone).motion);
        }
      }
      final expected = EmotionMotion.values.toSet()
        ..remove(EmotionMotion.none);
      expect(moving, containsAll(expected),
          reason: '재생되지 않는 움직임: ${expected.difference(moving)}');
    });

    test('신뢰도 세 구간을 모두 지난다', () {
      final confidences = demoScript.map((l) => l.toneConfidence);
      expect(confidences.any((c) => c < 0.35), isTrue,
          reason: '감정을 표시하지 않는 경우를 보여줘야 한다');
      expect(confidences.any((c) => c >= 0.35 && c < 0.6), isTrue,
          reason: '라벨만 붙고 움직이지 않는 경우를 보여줘야 한다');
      expect(confidences.any((c) => c >= 0.6), isTrue,
          reason: '움직임까지 붙는 경우를 보여줘야 한다');
    });

    test('말의 세기가 눈에 띄게 차이 난다', () {
      final intensities = demoScript.map((l) => l.intensity).toList()..sort();
      expect(intensities.first, lessThan(0.4));
      expect(intensities.last, greaterThan(0.8));
    });

    test('판정 근거 두 가지가 모두 나온다', () {
      // 근거에 따라 배지를 눌렀을 때 나오는 설명이 달라진다. "목소리만 보고
      // 짐작했다"는 말은 사용자가 이 기능을 얼마나 믿을지 정하는 근거인데,
      // 미리보기에서 한 번도 안 보이면 실제 대화에서 처음 만나게 된다.
      final bases = demoScript.map((l) => l.toneBasis).toSet();
      expect(bases, containsAll(ToneBasis.values),
          reason: '빠진 근거: ${ToneBasis.values.toSet().difference(bases)}');
    });

    test('화자가 늦게 확정되는 줄이 있다', () {
      expect(demoScript.any((l) => l.speakerLate), isTrue,
          reason: '"화자 확인 중" 상태를 미리 보여주지 않으면 고장으로 오해한다');
    });

    test('화자가 셋 다 등장하고, 색이 서로 다르다', () {
      final used = demoScript.map((l) => l.speakerKey).toSet();
      expect(used, demoSpeakers.map((s) => s.key).toSet());
      expect(demoSpeakers.map((s) => s.colorHex).toSet().length,
          demoSpeakers.length);
    });

    test('대본의 화자 키가 모두 정의되어 있다', () {
      final known = demoSpeakers.map((s) => s.key).toSet();
      for (final line in demoScript) {
        expect(known, contains(line.speakerKey));
      }
    });
  });

  group('대본 값의 범위', () {
    test('신뢰도와 세기가 0~1 안에 있다', () {
      for (final line in demoScript) {
        expect(line.toneConfidence, inInclusiveRange(0, 1));
        expect(line.intensity, inInclusiveRange(0, 1));
      }
    });

    test('운율 단독 판정이 실제 시스템의 한계를 지킨다', () {
      // 백엔드 `classify_by_prosody` 는 신뢰도를 0.6 으로 묶고, `angry` 는
      // 절대 내지 않는다 (시끄러운 곳에서 크게 말하는 것을 화남으로 읽으면
      // 사용자가 상대의 감정을 완전히 오해한다).
      //
      // 미리보기가 실제로 나올 수 없는 조합을 보여주면, 사용자는 있지도 않은
      // 동작을 학습한다. 특히 "목소리만 보고 화났다고 판단함" 은 우리가 절대
      // 하지 않겠다고 못박은 바로 그 동작이다.
      for (final line in demoScript) {
        if (line.toneBasis != ToneBasis.voice) continue;
        expect(line.toneConfidence, lessThanOrEqualTo(0.6),
            reason: '"${line.text}" — 운율 단독 판정은 0.6 을 넘을 수 없다');
        expect(line.tone, isNot(EmotionTone.angry),
            reason: '"${line.text}" — 운율만으로 화남을 판정하지 않는다');
      }
    });

    test('빈 줄이 없다', () {
      for (final line in demoScript) {
        expect(line.text.trim(), isNotEmpty);
      }
    });

    test('한 번에 다 보기에 지치지 않는 길이다', () {
      // 대사 재생 시간까지 더하면 대략 1분 안쪽이어야 한다.
      final pause = demoScript.fold<int>(
          0, (sum, l) => sum + l.pauseBefore.inMilliseconds);
      final speech = demoScript.fold<int>(
          0, (sum, l) => sum + 400 + l.text.length * 90);
      expect((pause + speech) / 1000, lessThan(75));
    });
  });
}
