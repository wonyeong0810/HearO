import 'dart:convert';

import 'package:flutter/services.dart';

import '../../domain/entities/caption.dart';
import '../../domain/entities/emotion_tone.dart';

/// 체험 모드에서 재생할 예시 대화.
///
/// 마이크도 서버도 쓰지 않는다. 그래서 권한을 주기 전에도, 오프라인에서도,
/// 백엔드가 죽어 있어도 돈다. 소리를 못 듣는 사용자가 "이 앱이 화면에 뭘
/// 보여주는지"를 말 한마디 하지 않고 먼저 확인할 수 있어야 한다.
///
/// 대본은 화면에 나올 수 있는 상태를 고루 지나가도록 짰다.
///   - 감정 6종 전부 (차분·격앙·화남·기쁨·슬픔·중립)
///   - 신뢰도 세 구간: 0.35 미만(표시 안 함) / 0.35~0.6(약한 문구) / 0.6 이상(움직임)
///   - 판정 근거 두 가지 (목소리만 / 목소리+문장) — 근거에 따라 시트 문구가 다르다
///   - 말의 세기 0.32 ~ 0.9 (글자 크기 변화)
///   - 화자가 늦게 확정되는 줄 ([DemoLine.speakerLate])
/// 하나라도 빠지면 그 표현은 사용자가 실제 대화에서 처음 보게 된다.
class DemoLine {
  const DemoLine({
    required this.speakerKey,
    required this.text,
    required this.tone,
    required this.toneConfidence,
    required this.intensity,
    this.toneBasis = ToneBasis.voiceText,
    this.speakerLate = false,
    this.pauseBefore = const Duration(milliseconds: 500),
    this.startMs,
    this.endMs,
    this.words,
  });

  final String speakerKey;
  final String text;
  final EmotionTone tone;

  /// 0~1. 0.35 미만이면 감정을 아예 표시하지 않는다.
  final double toneConfidence;

  /// 0~1. 글자 크기와 굵기를 정한다.
  final double intensity;

  /// 판정 근거. 실제 시스템이 만들 수 있는 조합만 써야 한다 — 운율 단독 판정은
  /// 신뢰도가 0.6 을 넘지 못하고, `angry` 를 절대 내지 않는다. 예시가 실제로
  /// 불가능한 상태를 보여주면 미리보기의 의미가 없어진다
  /// (`demo_script_test.dart` 가 지킨다).
  final ToneBasis toneBasis;

  /// 화자분리가 늦게 붙는 줄. 실제로도 새 목소리가 처음 등장하면
  /// 한 박자 뒤에 확정된다 — 그 과정을 보여 주지 않으면 사용자는
  /// "화자 확인 중"이 고장인 줄 안다.
  final bool speakerLate;

  /// 이 줄을 말하기 전의 뜸. [startMs] 가 있으면 쓰이지 않는다.
  final Duration pauseBefore;

  /// 체험 시작 기준 **절대 시각**. 있으면 이 시점에 줄이 뜬다.
  ///
  /// 상대 지연만으로 돌리면 타이핑 시간과 프레임 지연이 줄마다 쌓여서, 뒤로
  /// 갈수록 실제 시각이 밀린다. 대본만 볼 때는 티가 안 나지만 **바깥에서 음원을
  /// 틀어 놓고 맞추려는 순간 무너진다.** 절대 시각이 있으면 매 줄이 같은
  /// 기준점을 보므로 오차가 쌓이지 않는다.
  ///
  /// 실제 녹음에서 대본을 뽑을 때(`scripts/make_demo_script.py`) 이 값이 채워진다.
  final int? startMs;

  /// 이 줄이 끝나는 절대 시각. 타이핑 속도를 여기에 맞춘다.
  final int? endMs;

  /// 단어별 절대 시각. 있으면 이걸로 한 단어씩 띄운다.
  final List<DemoWord>? words;
}

class DemoWord {
  const DemoWord({required this.atMs, required this.text});

  final int atMs;
  final String text;
}

/// 예시 대화의 화자들. 색은 실제 백엔드가 배정하는 팔레트와 같은 계열이다.
const List<Speaker> demoSpeakers = [
  Speaker(key: 'S1', label: 'A', colorHex: '#1A73E8'),
  Speaker(key: 'S2', label: 'B', colorHex: '#188038'),
  Speaker(key: 'S3', label: 'C', colorHex: '#B25E02'),
];

/// 카페에서 친구 둘이 만나고 직원이 주문을 받는 상황.
const List<DemoLine> demoScript = [
  DemoLine(
    speakerKey: 'S1',
    text: '어, 왔어? 여기 자리 잡아 놨어.',
    tone: EmotionTone.happy,
    toneConfidence: 0.74,
    intensity: 0.52,
    pauseBefore: Duration(milliseconds: 300),
  ),
  DemoLine(
    speakerKey: 'S2',
    text: '미안, 버스가 너무 막혀서.',
    toneBasis: ToneBasis.voice,
    // 0.35~0.6 구간 — 라벨만 붙고 움직이지는 않는다.
    tone: EmotionTone.calm,
    toneConfidence: 0.48,
    intensity: 0.38,
  ),
  DemoLine(
    speakerKey: 'S1',
    text: '괜찮아, 나도 방금 왔어.',
    tone: EmotionTone.calm,
    toneConfidence: 0.81,
    intensity: 0.44,
  ),
  DemoLine(
    speakerKey: 'S3',
    text: '주문 도와드릴까요?',
    // 신뢰도가 낮아 감정을 표시하지 않는다. 잘못 알려주느니 침묵한다.
    tone: EmotionTone.neutral,
    toneConfidence: 0.28,
    intensity: 0.5,
    // 처음 등장한 목소리 — 화자가 한 박자 뒤에 확정된다.
    speakerLate: true,
    pauseBefore: Duration(milliseconds: 900),
  ),
  DemoLine(
    speakerKey: 'S2',
    text: '저는 따뜻한 아메리카노요.',
    toneBasis: ToneBasis.voice,
    tone: EmotionTone.neutral,
    toneConfidence: 0.52,
    intensity: 0.4,
  ),
  DemoLine(
    speakerKey: 'S2',
    text: '야, 어제 그 경기 봤어?!',
    tone: EmotionTone.excited,
    toneConfidence: 0.91,
    intensity: 0.84,
    pauseBefore: Duration(milliseconds: 800),
  ),
  DemoLine(
    speakerKey: 'S1',
    text: '봤지! 마지막 5분 진짜 대박이었잖아',
    tone: EmotionTone.excited,
    toneConfidence: 0.88,
    intensity: 0.9,
    pauseBefore: Duration(milliseconds: 350),
  ),
  DemoLine(
    speakerKey: 'S2',
    text: '근데 그 판정은 진짜 아니었어. 말이 되냐고',
    tone: EmotionTone.angry,
    toneConfidence: 0.76,
    intensity: 0.78,
  ),
  DemoLine(
    speakerKey: 'S1',
    text: '그러게… 그것 때문에 진 것 같아서 좀 그렇더라.',
    tone: EmotionTone.sad,
    toneConfidence: 0.69,
    intensity: 0.32,
    pauseBefore: Duration(milliseconds: 700),
  ),
  DemoLine(
    speakerKey: 'S3',
    text: '주문하신 음료 나왔습니다.',
    toneBasis: ToneBasis.voice,
    tone: EmotionTone.neutral,
    toneConfidence: 0.44,
    intensity: 0.5,
    pauseBefore: Duration(milliseconds: 900),
  ),
  DemoLine(
    speakerKey: 'S1',
    text: '감사합니다!',
    tone: EmotionTone.happy,
    toneConfidence: 0.95,
    intensity: 0.62,
    pauseBefore: Duration(milliseconds: 400),
  ),
];

class DemoContent {
  const DemoContent({required this.lines, required this.speakers});

  final List<DemoLine> lines;
  final List<Speaker> speakers;
}

const DemoContent _builtIn =
    DemoContent(lines: demoScript, speakers: demoSpeakers);

Future<DemoContent> loadDemoContent() async {
  try {
    final raw = await rootBundle.loadString('assets/demo/script.json');
    final parsed = _parse(jsonDecode(raw) as List<dynamic>);
    return parsed.lines.isEmpty ? _builtIn : parsed;
  } on Object {
    return _builtIn;
  }
}

DemoContent _parse(List<dynamic> rows) {
  final lines = <DemoLine>[];
  final speakers = <Speaker>[];
  final seen = <String>{};

  for (final row in rows) {
    final map = row as Map<String, dynamic>;
    final text = (map['text'] as String? ?? '').trim();
    if (text.isEmpty) continue;

    final key = (map['speaker'] as String? ?? 'A').trim();
    final isNew = seen.add(key);
    if (isNew) {
      final index = speakers.length;
      speakers.add(Speaker(
        key: key,
        label: String.fromCharCode(0x41 + index),
        colorHex: _demoPalette[index % _demoPalette.length],
      ));
    }

    final basis = ToneBasis.fromWire(map['tone_basis'] as String? ??
        map['toneBasis'] as String? ??
        'voice_text');
    var tone = EmotionTone.fromWire(map['tone'] as String? ?? 'neutral');
    var confidence =
        ((map['toneConfidence'] as num?)?.toDouble() ?? 0.5).clamp(0.0, 1.0);

    if (basis == ToneBasis.voice) {
      if (tone == EmotionTone.angry) tone = EmotionTone.excited;
      if (confidence > 0.6) confidence = 0.6;
    }

    final startMs = (map['startMs'] as num?)?.toInt();
    final endMs = (map['endMs'] as num?)?.toInt();
    final words = _parseWords(map['words']);

    lines.add(DemoLine(
      speakerKey: key,
      text: text,
      tone: tone,
      toneConfidence: confidence,
      intensity:
          ((map['intensity'] as num?)?.toDouble() ?? 0.5).clamp(0.0, 1.0),
      toneBasis: basis,
      speakerLate: isNew && speakers.length > 1,
      startMs: startMs,
      endMs: endMs,
      words: words,
    ));
  }

  return DemoContent(lines: lines, speakers: speakers);
}

List<DemoWord>? _parseWords(dynamic raw) {
  if (raw is! List || raw.isEmpty) return null;

  final words = <DemoWord>[];
  for (final row in raw) {
    if (row is! Map) continue;
    final text = (row['w'] as String? ?? row['text'] as String? ?? '').trim();
    final at = (row['t'] as num?)?.toInt() ?? (row['atMs'] as num?)?.toInt();
    if (text.isEmpty || at == null) continue;
    words.add(DemoWord(atMs: at, text: text));
  }

  words.sort((a, b) => a.atMs.compareTo(b.atMs));
  return words.isEmpty ? null : words;
}

const _demoPalette = ['#1A73E8', '#188038', '#B25E02', '#8E24AA'];
