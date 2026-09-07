import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearo/features/history/history_screen.dart';

/// 대화 이름 바꾸기 대화상자가 **닫히는 동안** 터지지 않는지 확인한다.
///
/// 실제로 저장이든 취소든 누르면 붉은 화면이 떴다.
///
///     'package:flutter/src/widgets/framework.dart':
///     Failed assertion: '_dependents.isEmpty': is not true.
///
/// 원인은 `TextEditingController` 를 바깥 함수에서 만들고 `showDialog` 가
/// 끝나자마자 `dispose()` 한 것이었다. 닫히는 애니메이션이 아직 도는 동안
/// `TextField` 는 그 컨트롤러를 계속 듣고 있다.
///
/// 이 버그가 특히 헷갈리는 이유는 **이름은 실제로 바뀌기 때문이다.** 값은
/// pop 하기 전에 넘어가므로 저장은 되고 화면만 깨진다. 나갔다 들어오면 멀쩡해
/// 보여서, 저장이 안 된 줄 알고 다시 시도하게 만든다.
///
/// 그래서 이 테스트의 핵심은 `pumpAndSettle` 이다 — 닫힘 애니메이션이 끝날
/// 때까지 돌려야 터지던 지점을 지나간다. `pump()` 한 번으로는 못 잡는다.
void main() {
  Future<String?> openAndTap(WidgetTester tester, String button) async {
    String? result;
    var opened = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                opened = true;
                result = await showDialog<String>(
                  context: context,
                  builder: (_) => const RenameDialog(initialTitle: '병원 진료'),
                );
              },
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    expect(opened, isTrue);

    await tester.tap(find.text(button));
    await tester.pumpAndSettle();

    return result;
  }

  testWidgets('저장을 눌러도 터지지 않는다', (tester) async {
    final result = await openAndTap(tester, '저장');

    expect(tester.takeException(), isNull);
    expect(result, '병원 진료');
  });

  testWidgets('취소를 눌러도 터지지 않는다', (tester) async {
    final result = await openAndTap(tester, '취소');

    expect(tester.takeException(), isNull);
    expect(result, isNull, reason: '취소는 이름을 바꾸지 않는다');
  });

  testWidgets('기존 이름이 채워져 있다', (tester) async {
    // 이름을 바꾸려는 사람은 대개 조금만 고친다. 빈 칸으로 시작하면 매번
    // 처음부터 다시 써야 한다.
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: RenameDialog(initialTitle: '병원 진료')),
      ),
    );
    await tester.pump();

    expect(find.text('병원 진료'), findsOneWidget);
  });

  testWidgets('입력한 이름을 그대로 돌려준다', (tester) async {
    String? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showDialog<String>(
                  context: context,
                  builder: (_) => const RenameDialog(initialTitle: ''),
                );
              },
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '  팀 회의  ');
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(result, '팀 회의', reason: '앞뒤 공백은 다듬어야 한다');
  });
}
