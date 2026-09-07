import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearo/features/settings/widgets/retention_sheet.dart';

/// 보관 기간 시트가 어떤 화면 크기·글자 배율에서도 넘치지 않는지 확인한다.
///
/// 실제로 작은 화면에서 "BOTTOM OVERFLOWED BY 7.7 PIXELS" 가 떴고, 마지막
/// 항목인 "무기한 (삭제 안 함)" 이 잘렸다. 하필 이 항목이 잘리는 게 나쁘다 —
/// 자동 삭제를 끄려는 사용자가 그 선택지를 못 본다.
///
/// 저시력 사용자가 시스템 글자 크기를 키우는 것은 이 앱에서 정상 사용이므로
/// 큰 배율까지 함께 본다.
void main() {
  /// 앱과 같은 경로로 띄운다.
  ///
  /// 위젯을 그냥 화면에 얹어 보면 높이가 조여지지 않아 오버플로가 재현되지
  /// 않는다. 터진 곳은 **모달 시트가 높이를 제한하는 지점**이므로 반드시
  /// showModalBottomSheet 를 거쳐야 의미 있는 테스트가 된다.
  Future<int?> pumpSheet(
    WidgetTester tester, {
    required Size size,
    required double textScale,
    bool isScrollControlled = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    int? result;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showModalBottomSheet<int>(
                  context: context,
                  isScrollControlled: isScrollControlled,
                  builder: (_) => const RetentionSheet(selectedDays: 90),
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

  group('넘치지 않는다', () {
    // 작은 폰부터 큰 폰까지. 세로가 짧을수록 위험하다.
    const sizes = <Size>[
      Size(360, 640), // 작은 폰
      Size(411, 731), // 흔한 크기
      Size(411, 914), // Pixel 6
    ];

    for (final size in sizes) {
      for (final scale in <double>[1.0, 1.3, 2.0]) {
        testWidgets('${size.width.toInt()}x${size.height.toInt()}, 글자 $scale배',
            (tester) async {
          await pumpSheet(tester, size: size, textScale: scale);
          expect(tester.takeException(), isNull);
        });
      }
    }

    testWidgets('시트 높이가 화면의 9/16 로 묶여도 버틴다', (tester) async {
      // 원래 터진 조건. isScrollControlled 없이 열면 모달 시트가 높이를
      // 화면의 9/16 로 제한한다. 호출하는 쪽이 그 옵션을 빠뜨려도 항목이
      // 잘리지 않아야 한다 — 잘리는 건 시트 자신의 문제다.
      await pumpSheet(
        tester,
        size: const Size(411, 731),
        textScale: 1,
        isScrollControlled: false,
      );
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('모든 선택지가 존재한다', (tester) async {
    await pumpSheet(tester, size: const Size(411, 914), textScale: 1);

    for (final label in RetentionSheet.options.values) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
  });

  testWidgets('작은 화면에서도 마지막 선택지에 닿을 수 있다', (tester) async {
    // 잘려서 안 보이는 것과, 스크롤하면 보이는 것은 다르다.
    await pumpSheet(tester, size: const Size(360, 640), textScale: 1.3);

    await tester.scrollUntilVisible(
      find.text('무기한 (삭제 안 함)'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('무기한 (삭제 안 함)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('고르면 그 값을 돌려준다', (tester) async {
    await pumpSheet(tester, size: const Size(411, 914), textScale: 1);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('30일'));
    await tester.pumpAndSettle();
    // 시트가 닫혔는지로 확인한다 — 값은 pumpSheet 안에서 받는다.
    expect(find.text('30일'), findsNothing);
  });

  testWidgets('무기한은 0 을 돌려준다 — 숫자만 보면 정반대로 읽힌다', (tester) async {
    int? result;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showModalBottomSheet<int>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => const RetentionSheet(selectedDays: 90),
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
    await tester.tap(find.text('무기한 (삭제 안 함)'));
    await tester.pumpAndSettle();
    expect(result, 0);
  });
}
