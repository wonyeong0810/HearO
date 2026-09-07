import 'package:flutter/material.dart';

import '../../domain/entities/emotion_tone.dart';

/// 감정을 어떻게 보여줄지 정의한다 (기획 1-3).
///
/// 색 하나로만 감정을 표현하지 않는다. 이 앱의 사용자 중에는 색각이상이 있는
/// 사람도, 미묘한 색차를 구분하기 어려운 저시력 사용자도 있다. 그래서 감정마다
/// **색 + 아이콘 + 움직임 + 한국어 라벨** 네 가지를 함께 준다.
///
/// ## 문구는 단정하지 않는다
///
/// 자막 옆에 `화남` 이라고 뜨면 사용자는 그것을 상대의 감정에 대한 사실로
/// 받아들인다. 실제로는 목소리와 문장에서 뽑아낸 추정이고, 개인차에 약하다 —
/// 원래 목소리가 큰 사람, 사투리, 신나서 흥분한 사람, 말투 특성이 다른 사람,
/// 문화·연령 차이. 소리를 못 듣는 사용자는 이 표시를 **검증할 방법이 없어서**,
/// 틀렸을 때 알아챌 수도 없다.
///
/// 그래서 세 겹으로 추정임을 드러낸다.
///   1. 감정이 아니라 **말투**를 말한다 (`화난 말투`)
///   2. 관찰이라는 걸 문장으로 드러낸다 (`화난 말투로 들림`)
///   3. 확신이 약하면 문구부터 약해진다 (`화난 말투일 수도`) — [EmotionEmphasis]
@immutable
class EmotionStyle {
  const EmotionStyle({
    required this.tone,
    required this.label,
    required this.heardPhrase,
    required this.tentativePhrase,
    required this.icon,
    required this.lightColor,
    required this.darkColor,
    required this.motion,
    required this.description,
  });

  final EmotionTone tone;

  /// 짧은 이름 ("화난 말투"). 목록·필터·통계처럼 여러 건을 묶어 보여주는
  /// 자리에서 쓴다. 그런 화면은 헤더에서 추정임을 한 번 밝히면 충분하다.
  final String label;

  /// 자막 한 줄에 붙는 문구 ("화난 말투로 들림").
  ///
  /// "들림"이 핵심이다. 상대가 화났다는 주장이 아니라, 그렇게 들렸다는 관찰의
  /// 보고다. 배지 너비가 조금 늘어나는 대가로 단정이 사라진다.
  final String heardPhrase;

  /// 신뢰도가 낮을 때의 문구 ("화난 말투일 수도").
  ///
  /// 예전에는 신뢰도가 색 진하기와 움직임으로만 나타났는데, 그건 **옆에 비교할
  /// 자막이 있어야** 읽히는 신호다. 한 줄만 보고도 확신의 정도를 알 수 있어야 한다.
  final String tentativePhrase;

  /// 색을 못 읽는 경우의 대체 단서
  final IconData icon;

  final Color lightColor;
  final Color darkColor;

  /// 텍스트에 입힐 움직임
  final EmotionMotion motion;

  /// 스크린리더 및 접근성 설명
  final String description;

  Color colorOf(Brightness brightness) =>
      brightness == Brightness.dark ? darkColor : lightColor;

  /// 확신 정도에 맞는 문구를 고른다. 자막 배지와 스크린리더가 같이 쓴다.
  String phraseFor(EmotionEmphasis emphasis) =>
      emphasis.isTentative ? tentativePhrase : heardPhrase;

  static EmotionStyle of(EmotionTone tone) => _styles[tone]!;

  static const Map<EmotionTone, EmotionStyle> _styles = {
    EmotionTone.calm: EmotionStyle(
      tone: EmotionTone.calm,
      label: '차분한 말투',
      heardPhrase: '차분한 말투로 들림',
      tentativePhrase: '차분한 말투일 수도',
      icon: Icons.spa_outlined,
      lightColor: Color(0xFF00695C),
      darkColor: Color(0xFF4DB6AC),
      motion: EmotionMotion.none,
      description: '차분한 말투로 들림',
    ),
    EmotionTone.excited: EmotionStyle(
      tone: EmotionTone.excited,
      // "격앙"은 부정적으로 읽히기 쉬운데, 이 톤에는 신나서 들뜬 경우가 함께
      // 들어온다. 둘을 아우르면서 감정을 단정하지 않는 말이 "격한 말투"다.
      label: '격한 말투',
      heardPhrase: '격한 말투로 들림',
      tentativePhrase: '격한 말투일 수도',
      icon: Icons.bolt_outlined,
      lightColor: Color(0xFFB25E02),
      darkColor: Color(0xFFFFB74D),
      // 흥분한 말은 떨리듯 흔들린다.
      motion: EmotionMotion.shake,
      description: '격하거나 들뜬 말투로 들림',
    ),
    EmotionTone.angry: EmotionStyle(
      tone: EmotionTone.angry,
      label: '화난 말투',
      heardPhrase: '화난 말투로 들림',
      tentativePhrase: '화난 말투일 수도',
      icon: Icons.local_fire_department_outlined,
      lightColor: Color(0xFFC62828),
      darkColor: Color(0xFFEF9A9A),
      // 화난 말은 강하게 맥동한다.
      motion: EmotionMotion.pulse,
      description: '화난 말투로 들림',
    ),
    EmotionTone.happy: EmotionStyle(
      tone: EmotionTone.happy,
      label: '밝은 말투',
      heardPhrase: '밝은 말투로 들림',
      tentativePhrase: '밝은 말투일 수도',
      icon: Icons.sentiment_very_satisfied_outlined,
      lightColor: Color(0xFF00796B),
      darkColor: Color(0xFF80CBC4),
      // 기쁜 말은 통통 튀어오른다.
      motion: EmotionMotion.bounce,
      description: '밝은 말투로 들림',
    ),
    EmotionTone.sad: EmotionStyle(
      tone: EmotionTone.sad,
      label: '가라앉은 말투',
      heardPhrase: '가라앉은 말투로 들림',
      tentativePhrase: '가라앉은 말투일 수도',
      icon: Icons.sentiment_dissatisfied_outlined,
      lightColor: Color(0xFF37548C),
      darkColor: Color(0xFF9FB3DB),
      // 슬픈 말은 아래로 가라앉는다.
      motion: EmotionMotion.sink,
      description: '가라앉은 말투로 들림',
    ),
    EmotionTone.neutral: EmotionStyle(
      tone: EmotionTone.neutral,
      // 중립은 "감정이 없다"가 아니라 "우리가 못 읽었다"에 가깝다. 그래서
      // 사람의 상태를 말하지 않고 관찰이 비었다는 사실만 적는다.
      label: '특징 없음',
      heardPhrase: '뚜렷한 말투 특징 없음',
      tentativePhrase: '뚜렷한 말투 특징 없음',
      icon: Icons.remove,
      lightColor: Color(0xFF5F6368),
      darkColor: Color(0xFFB0B4BA),
      motion: EmotionMotion.none,
      description: '뚜렷한 말투 특징이 잡히지 않음',
    ),
  };
}

/// 자막에 입힐 움직임 종류.
///
/// 움직임은 신뢰도에 비례해 약해진다 — 확신 없는 감정을 요란하게 표시하면
/// 사용자가 상대의 기분을 오해한다. 그리고 시스템의 "동작 줄이기" 설정이
/// 켜져 있으면 전부 끈다.
enum EmotionMotion {
  none,

  /// 좌우로 미세하게 떨림 (격앙)
  shake,

  /// 크기가 커졌다 작아짐 (화남)
  pulse,

  /// 위아래로 튐 (기쁨)
  bounce,

  /// 아래로 처짐 (슬픔)
  sink,
}

/// 실제 표시할 감정 표현의 세기.
///
/// 백엔드가 준 신뢰도가 낮으면 아무것도 하지 않는 편이 낫다. 감정을 잘못
/// 알려주는 것은 감정을 안 알려주는 것보다 나쁘다.
class EmotionEmphasis {
  const EmotionEmphasis({
    required this.showLabel,
    required this.motionScale,
    required this.colorOpacity,
    this.isTentative = false,
  });

  /// 감정 라벨/아이콘을 붙일지
  final bool showLabel;

  /// 근거가 약한 판정인지. 문구를 약하게 바꾸고(`…일 수도`) 배지를 채움 없이
  /// 테두리만으로 그린다.
  ///
  /// 확신의 정도를 색 진하기로만 나타내면 색각이상·저시력 사용자와 흑백
  /// 환경에서 사라진다. 이 앱에서는 감정 자체가 이미 색 + 아이콘 + 움직임 +
  /// 라벨로 중복 표현되는데, 정작 **얼마나 믿을 만한가**만 색에 걸려 있었다.
  final bool isTentative;

  /// 움직임 강도 배율 (0 = 정지)
  final double motionScale;

  /// 감정 색을 얼마나 진하게 입힐지
  final double colorOpacity;

  static const EmotionEmphasis none = EmotionEmphasis(
    showLabel: false,
    motionScale: 0,
    colorOpacity: 0,
  );

  /// [confidence] 0~1 에서 표현 강도를 정한다.
  ///
  /// - 0.35 미만: 표시하지 않는다. 근거가 너무 약하다.
  /// - 0.35~0.6: 약한 문구(`…일 수도`)만, 움직임 없음.
  /// - 0.6 이상: 관찰 문구(`…로 들림`) + 움직임, 신뢰도에 비례해 강해짐.
  static EmotionEmphasis fromConfidence(
    double confidence, {
    required bool animationsEnabled,
    required bool reduceMotion,
  }) {
    if (confidence < 0.35) return none;

    final allowMotion = animationsEnabled && !reduceMotion;

    if (confidence < 0.6) {
      return EmotionEmphasis(
        showLabel: true,
        motionScale: 0,
        colorOpacity: allowMotion ? 0.55 : 0.7,
        isTentative: true,
      );
    }

    // 0.6 → 0.0, 1.0 → 1.0 으로 선형 증가
    final scale = ((confidence - 0.6) / 0.4).clamp(0.0, 1.0);
    return EmotionEmphasis(
      showLabel: true,
      motionScale: allowMotion ? scale : 0,
      colorOpacity: 0.7 + scale * 0.3,
    );
  }
}
