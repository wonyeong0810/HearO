import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `assets/demo/script.json` 이 있으면 앱 규칙에 맞는지 검사한다.
/// 파일은 각자 기기에만 있으므로, 없으면 건너뛴다.
void main() {
  final file = File('assets/demo/script.json');
  if (!file.existsSync()) {
    test('script.json 없음 — 내장 대본을 쓴다', () {}, skip: true);
    return;
  }

  late List<dynamic> rows;

  setUpAll(() {
    rows = jsonDecode(file.readAsStringSync()) as List<dynamic>;
  });

  const tones = {'calm', 'excited', 'angry', 'happy', 'sad', 'neutral'};

  test('필수 필드가 다 있다', () {
    for (final (i, row) in rows.cast<Map<String, dynamic>>().indexed) {
      expect(row['text'], isA<String>(), reason: '$i번째 줄 text');
      expect(row['speaker'], isA<String>(), reason: '$i번째 줄 speaker');
      expect(row['startMs'], isA<num>(), reason: '$i번째 줄 startMs');
      expect(row['endMs'], isA<num>(), reason: '$i번째 줄 endMs');
      expect(tones, contains(row['tone']), reason: '$i번째 줄 tone');
    }
  });

  test('시간이 앞뒤로 어긋나지 않는다', () {
    for (final (i, row) in rows.cast<Map<String, dynamic>>().indexed) {
      final start = row['startMs'] as num;
      final end = row['endMs'] as num;
      expect(end, greaterThan(start), reason: '$i번째 줄');
    }
  });

  test('운율 단독 판정이 실제로 나올 수 있는 값이다', () {
    for (final (i, row) in rows.cast<Map<String, dynamic>>().indexed) {
      if ((row['toneBasis'] ?? row['tone_basis']) != 'voice') continue;
      expect(row['tone'], isNot('angry'),
          reason: '$i번째 줄: 운율만으로는 화남을 판정하지 않는다');
      expect(row['toneConfidence'] as num, lessThanOrEqualTo(0.6),
          reason: '$i번째 줄: 운율 단독 신뢰도 상한은 0.6');
    }
  });

  test('단어 시각이 text 와 맞는다', () {
    for (final (i, row) in rows.cast<Map<String, dynamic>>().indexed) {
      final words = row['words'];
      if (words is! List) continue;

      final joined = words.map((w) => (w as Map<String, dynamic>)['w']).join(' ');
      expect(joined, row['text'], reason: '$i번째 줄: words 를 이으면 text 가 나와야 한다');

      var previous = -1;
      for (final word in words.cast<Map<String, dynamic>>()) {
        final at = (word['t'] as num).toInt();
        expect(at, greaterThan(previous), reason: '$i번째 줄: 단어 시각이 역행한다');
        previous = at;
      }
      expect((words.first as Map<String, dynamic>)['t'], row['startMs'],
          reason: '$i번째 줄: 첫 단어는 줄 시작과 같아야 한다');
      expect((words.last as Map<String, dynamic>)['t'] as num, lessThan(row['endMs'] as num),
          reason: '$i번째 줄: 마지막 단어가 줄 끝보다 늦다');
    }
  });

  test('화면에 나올 수 있는 상태를 고루 지나간다', () {
    final seen = rows.cast<Map<String, dynamic>>();
    final confidences = seen.map((r) => r['toneConfidence'] as num).toList();

    expect(confidences.any((c) => c < 0.35), isTrue,
        reason: '말투를 표시하지 않는 줄이 없다');
    expect(confidences.any((c) => c >= 0.35 && c < 0.6), isTrue,
        reason: '약한 문구로 뜨는 줄이 없다');
    expect(confidences.any((c) => c >= 0.6), isTrue,
        reason: '움직임까지 붙는 줄이 없다');
    expect(seen.map((r) => r['speaker']).toSet().length, greaterThan(1),
        reason: '화자가 하나뿐이면 화자 구분을 보여주지 못한다');
  });
}
