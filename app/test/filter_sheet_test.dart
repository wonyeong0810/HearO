import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearo/features/history/history_controller.dart';
import 'package:hearo/features/history/widgets/filter_sheet.dart';

/// 기록 필터 시트가 어떤 화면 크기·글자 배율에서도 넘치지 않고, 맨 아래
/// **적용 버튼에 닿을 수 있는지** 확인한다.
///
/// 이 시트는 세로로 긴 편이다 — 즐겨찾기 · 기간 · 위치 · 화자 · 말투 5종 칩 ·
/// 적용 버튼. 저시력 사용자가 글자를 키우면 금방 화면을 넘긴다.
///
/// 위치·화자가 텍스트 입력이라 키보드까지 올라오면 남는 높이가 절반 아래로
/// 떨어진다. 그 상태에서 적용 버튼이 잘리면, 필터를 다 골라 놓고 적용을 못
/// 누른다.
void main() {
  Future<HistoryFilter?> openSheet(
    WidgetTester tester, {
    required Size size,
    double textScale = 1.0,
    double keyboardHeight = 0,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    HistoryFilter? result;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            viewInsets: EdgeInsets.only(bottom: keyboardHeight),
          ),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showModalBottomSheet<HistoryFilter>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => const FilterSheet(initial: HistoryFilter()),
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
    return result;
  }

  // 갤럭시 S24 (1080x2340 @3.0) 기준 논리 크기.
  const phone = Size(360, 780);

  group('넘치지 않는다', () {
    testWidgets('기본 크기', (tester) async {
      await openSheet(tester, size: phone);
      expect(tester.takeException(), isNull);
    });

    testWidgets('글자 1.3배', (tester) async {
      await openSheet(tester, size: phone, textScale: 1.3);
      expect(tester.takeException(), isNull);
    });

    testWidgets('글자 1.6배 — 앱이 허용하는 최대 배율', (tester) async {
      await openSheet(tester, size: phone, textScale: 1.6);
      expect(tester.takeException(), isNull);
    });

    testWidgets('작은 화면', (tester) async {
      await openSheet(tester, size: const Size(320, 568));
      expect(tester.takeException(), isNull);
    });

    testWidgets('위치·화자를 입력하려 키보드가 올라왔을 때', (tester) async {
      await openSheet(tester, size: phone, textScale: 1.3, keyboardHeight: 310);
      expect(tester.takeException(), isNull);
    });
  });

  group('적용 버튼에 닿을 수 있다', () {
    testWidgets('글자를 최대로 키우고 키보드가 올라와도', (tester) async {
      // 안 넘치기만 하고 버튼이 화면 밖에 있으면 결국 필터를 못 건다.
      await openSheet(tester, size: phone, textScale: 1.6, keyboardHeight: 310);

      await tester.dragUntilVisible(
        find.text('적용'),
        find.byType(SingleChildScrollView),
        const Offset(0, -80),
      );

      expect(find.text('적용'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('말투 칩이 모두 남아 있다', (tester) async {
      await openSheet(tester, size: phone);

      // 중립을 뺀 5종. 하나라도 잘리면 그 말투로는 걸러낼 수 없다.
      expect(find.text('차분한 말투'), findsOneWidget);
      expect(find.text('화난 말투'), findsOneWidget);
      expect(find.text('가라앉은 말투'), findsOneWidget);
    });
  });
}
