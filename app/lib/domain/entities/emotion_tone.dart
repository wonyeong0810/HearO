/// 감정·톤 5분류 (+ 판정 보류).
///
/// 백엔드의 `EmotionTone` 과 문자열 값이 정확히 일치해야 한다.
///
/// **표시 문구는 감정이 아니라 "말투"를 가리킨다.** 화면에 `화남` 이라고 쓰면
/// 사용자는 그것을 상대의 감정에 대한 사실로 읽는다. 그런데 우리가 실제로 관찰한
/// 것은 목소리와 문장이지 그 사람의 속마음이 아니고, 둘 사이에는 개인차가 크다 —
/// 원래 목소리가 큰 사람, 사투리, 신나서 흥분한 사람, 말투 특성이 다른 사람
/// (자폐 스펙트럼 등), 문화·연령에 따른 표현 차이가 전부 여기서 갈린다.
///
/// 그래서 `화남` 이 아니라 `화난 말투` 라고 쓴다. 관찰한 것만 말하고, 해석은
/// 사용자에게 남긴다. 자막 옆 배지에는 [EmotionStyle] 이 여기에 "…로 들림"까지
/// 붙여 추정이라는 사실을 한 번 더 드러낸다.
enum EmotionTone {
  calm('calm', '차분한 말투'),
  excited('excited', '격한 말투'),
  angry('angry', '화난 말투'),
  happy('happy', '밝은 말투'),
  sad('sad', '가라앉은 말투'),
  neutral('neutral', '특징 없음');

  const EmotionTone(this.wireValue, this.labelKo);

  /// API 로 오가는 값
  final String wireValue;

  /// 화면에 표시할 한국어. 목록·필터·통계처럼 **여러 건을 묶어 보여주는 자리**
  /// 에서 쓴다. 자막 한 줄에 붙일 때는 [EmotionStyle.heardPhrase] 를 쓴다.
  final String labelKo;

  /// 알 수 없는 값이 오면 neutral 로 떨어뜨린다. 백엔드에 새 감정이 추가되어도
  /// 구버전 앱이 깨지지 않아야 한다.
  static EmotionTone fromWire(String? value) {
    if (value == null) return EmotionTone.neutral;
    for (final tone in EmotionTone.values) {
      if (tone.wireValue == value) return tone;
    }
    return EmotionTone.neutral;
  }
}

/// 톤 판정이 **무엇을 근거로** 나왔는지. 백엔드 `ToneBasis` 와 값이 일치한다.
///
/// 근거에 따라 틀릴 확률이 크게 다르다. 운율만 본 판정은 사투리·평소 목소리
/// 크기·말 빠르기 같은 개인차를 감정으로 오해하기 쉽다. 사용자가 이 표시를
/// 얼마나 믿을지 스스로 정하려면 근거를 알아야 한다.
enum ToneBasis {
  /// 목소리(음량·높낮이·빠르기)만 봤다. 문장 내용은 반영되지 않았다.
  voice('voice', '목소리 톤만으로 추정'),

  /// 목소리 + 문장 내용을 함께 봤다.
  voiceText('voice_text', '목소리 톤과 문장 내용으로 추정');

  const ToneBasis(this.wireValue, this.labelKo);

  final String wireValue;
  final String labelKo;

  /// 모르면 [voice] 로 떨어뜨린다 — 근거를 부풀려 말하는 것보다 낫다.
  /// 구버전 서버나 이 필드가 없던 시절의 기록이 여기로 온다.
  static ToneBasis fromWire(String? value) {
    for (final basis in ToneBasis.values) {
      if (basis.wireValue == value) return basis;
    }
    return ToneBasis.voice;
  }
}

/// 위급 음향 종류.
///
/// 백엔드의 `AlertType` 과 값이 일치해야 하고, 온디바이스 모델의 클래스명은
/// `AlarmDetector._alertTypeFor` 가 여기로 이어 준다.
///
/// `smokeDetector` 는 지금 모델이 내지 않는다 (화재경보와 같은 심각도·같은
/// 행동이라 `fire_alarm` 으로 합쳤다). 과거 기록에 남아 있을 수 있으므로
/// enum 값 자체는 지우지 않는다.
enum AlertType {
  fireAlarm('fire_alarm', '화재경보', 3),
  smokeDetector('smoke_detector', '연기감지기', 3),
  civilDefenseSiren('civil_defense_siren', '민방위 경보', 3),
  emergencyVehicle('emergency_vehicle', '긴급차량 사이렌', 2),
  generalAlarm('general_alarm', '경보음', 1);

  const AlertType(this.wireValue, this.labelKo, this.severity);

  final String wireValue;
  final String labelKo;

  /// 1(주의) ~ 3(즉시 대피). 경고 화면의 강도를 결정한다.
  final int severity;

  /// 사용자에게 보여줄 행동 지침. 소리를 못 듣는 상황에서 "무슨 소리인지" 만큼
  /// "어떻게 해야 하는지" 가 중요하다.
  String get guidance => switch (this) {
        AlertType.fireAlarm =>
          '화재경보가 울리고 있습니다. 즉시 밖으로 대피하세요. 엘리베이터를 쓰지 마세요.',
        AlertType.smokeDetector =>
          '연기가 감지되었습니다. 주변을 확인하고 필요하면 대피하세요.',
        AlertType.civilDefenseSiren =>
          '민방위 경보입니다. 가까운 대피소로 이동하고 안내 방송을 확인하세요.',
        AlertType.emergencyVehicle =>
          '긴급차량이 접근 중입니다. 길을 비켜 주세요.',
        AlertType.generalAlarm => '경보음이 감지되었습니다. 주변을 확인하세요.',
      };

  static AlertType fromWire(String? value) {
    if (value == null) return AlertType.generalAlarm;
    for (final type in AlertType.values) {
      if (type.wireValue == value) return type;
    }
    return AlertType.generalAlarm;
  }
}

/// 대화 세션 상태.
enum SessionStatus {
  active('active'),
  ended('ended'),
  abandoned('abandoned');

  const SessionStatus(this.wireValue);

  final String wireValue;

  static SessionStatus fromWire(String? value) {
    for (final status in SessionStatus.values) {
      if (status.wireValue == value) return status;
    }
    return SessionStatus.ended;
  }
}
