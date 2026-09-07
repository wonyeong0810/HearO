import 'package:flutter_test/flutter_test.dart';
import 'package:hearo/domain/entities/caption.dart';

/// 자막 줄이 **말한 순서대로** 놓이는지 확인한다.
///
/// 대개는 맨 뒤에 붙지만 항상 그렇지는 않다. 쉬는 텀 없이 화자가 바뀌면
/// 실시간 트랙은 두 사람의 말을 한 줄로 묶고, 서버가 나중에 화자분리 결과로
/// 그 줄을 나눈다. 그때 새 조각이 이미 나간 줄 **사이에** 끼어든다.
///
/// 그냥 이어 붙이면 나중에 한 말이 먼저 한 말 위에 온다. 화면이 유일한 통로인
/// 사용자에게 대화 순서가 뒤바뀌는 것은 내용이 틀린 것만큼 나쁘다.
///
/// `_appendCaption` 은 private 이라 같은 삽입 규칙을 여기서 그대로 검증한다.
List<Caption> insert(List<Caption> captions, Caption incoming) {
  final updated = [...captions];
  var at = updated.length;
  while (at > 0 && updated[at - 1].startMs > incoming.startMs) {
    at--;
  }
  updated.insert(at, incoming);
  return updated;
}

Caption line(int sequence, int startMs) =>
    Caption(sequence: sequence, text: '$startMs', startMs: startMs);

void main() {
  test('보통은 맨 뒤에 붙는다', () {
    final result = insert([line(1, 0), line(2, 3000)], line(3, 6000));

    expect(result.map((c) => c.startMs), [0, 3000, 6000]);
  });

  test('나뉜 조각이 뒤늦게 와도 말한 순서대로 놓인다', () {
    // 1번 줄(0ms)이 두 사람 것이었고, 그 사이 3번 줄(6000ms)이 이미 나갔다.
    // 뒤늦게 도착한 조각(3000ms)은 그 앞에 들어가야 한다.
    final result = insert(
      [line(1, 0), line(2, 6000)],
      line(3, 3000),
    );

    expect(result.map((c) => c.startMs), [0, 3000, 6000]);
    expect(result.map((c) => c.sequence), [1, 3, 2]);
  });

  test('같은 시작 지점이면 나중에 온 것이 뒤로 간다', () {
    final result = insert([line(1, 3000)], line(2, 3000));

    expect(result.map((c) => c.sequence), [1, 2]);
  });

  test('맨 앞으로도 들어갈 수 있다', () {
    final result = insert([line(2, 3000), line(3, 6000)], line(1, 0));

    expect(result.map((c) => c.startMs), [0, 3000, 6000]);
  });

  test('빈 목록에도 넣을 수 있다', () {
    expect(insert([], line(1, 0)).single.startMs, 0);
  });
}
