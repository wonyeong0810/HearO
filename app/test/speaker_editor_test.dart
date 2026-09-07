import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearo/domain/entities/caption.dart';
import 'package:hearo/features/live/widgets/speaker_legend.dart';

/// 화자 이름·색 편집 시트가 **키보드가 올라온 상태에서** 넘치지 않는지 본다.
///
/// 실제로 `BOTTOM OVERFLOWED BY 10.0 PIXELS` 가 떴고, 하필 맨 아래의 취소·저장
/// 버튼이 잘렸다. 이름을 다 입력해 놓고 저장을 못 누르는 상태가 된다.
///
/// 이 시트는 이름 입력이 autofocus 라 **열리자마자 항상 키보드가 올라온다.**
/// 즉 키보드 없는 상태만 확인하면 정작 사용자가 보는 화면을 한 번도 안 보는
/// 셈이다. 그래서 여기서는 viewInsets 로 키보드를 만들어 놓고 연다.
///
/// 저시력 사용자가 시스템 글자 크기를 키우는 것은 이 앱에서 정상 사용이므로
/// 큰 배율까지 함께 본다.
void main() {
  const speaker = Speaker(key: 'S1', label: 'A', colorHex: '#2563EB');

  /// 앱과 같은 경로(showModalBottomSheet)로 띄운다.
  ///
  /// 위젯을 그냥 화면에 얹으면 높이가 조여지지 않아 오버플로가 재현되지 않는다.
  /// 터지는 곳은 **모달 시트가 높이를 제한하는 지점**이다.
  Future<void> openEditor(
    WidgetTester tester, {
    required Size size,
    double textScale = 1.0,
    double keyboardHeight = 0,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

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
          body: SpeakerLegend(
            speakers: const [speaker],
            onRename: (_, __) {},
            onRecolor: (_, __) {},
          ),
        ),
      ),
    );

    await tester.tap(find.text('화자 A'));
    await tester.pumpAndSettle();
  }

  group('키보드가 올라와도 넘치지 않는다', () {
    // 갤럭시 S24 (1080x2340 @3.0) 기준 논리 크기. 키보드는 화면의 약 40%.
    const phone = Size(360, 780);

    testWidgets('기본 크기', (tester) async {
      await openEditor(tester, size: phone, keyboardHeight: 310);
      expect(tester.takeException(), isNull);
    });

    testWidgets('글자 1.3배', (tester) async {
      await openEditor(
        tester,
        size: phone,
        textScale: 1.3,
        keyboardHeight: 310,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('글자 1.6배 — 앱이 허용하는 최대 배율', (tester) async {
      await openEditor(
        tester,
        size: phone,
        textScale: 1.6,
        keyboardHeight: 310,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('작은 화면', (tester) async {
      await openEditor(
        tester,
        size: const Size(320, 568),
        keyboardHeight: 260,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('저장 버튼에 닿을 수 있다', () {
    testWidgets('키보드가 가려도 스크롤해서 누를 수 있다', (tester) async {
      // 안 넘치기만 하고 버튼이 화면 밖에 있으면 결국 저장을 못 한다.
      await openEditor(
        tester,
        size: const Size(360, 780),
        textScale: 1.6,
        keyboardHeight: 310,
      );

      await tester.dragUntilVisible(
        find.text('저장'),
        find.byType(SingleChildScrollView),
        const Offset(0, -60),
      );

      expect(find.text('저장'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('색상 선택지가 모두 남아 있다', (tester) async {
      // 색이 잘려 나가면 색각이상 사용자가 구분 가능한 색을 못 고른다.
      await openEditor(tester, size: const Size(360, 780), keyboardHeight: 310);

      expect(find.text('색상'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
