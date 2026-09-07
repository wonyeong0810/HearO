import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearo/domain/entities/caption.dart';
import 'package:hearo/domain/entities/emotion_tone.dart';
import 'package:hearo/features/live/widgets/caption_tile.dart';
import 'package:hearo/features/live/widgets/tone_basis_sheet.dart';

/// 말투 표시가 화면에서 **추정으로 보이는지** 확인한다.
///
/// 자막 옆에 뜨는 한 단어는 사용자가 대화 분위기를 아는 유일한 단서라, 사실로
/// 받아들여진다. 그런데 이 판정은 목소리와 문장에서 나온 짐작이고 개인차에
/// 흔들린다. 소리를 못 듣는 사용자는 틀렸다는 걸 알아챌 방법조차 없다.
///
/// 그래서 화면 자체가 세 가지를 해야 한다.
///   1. 감정이 아니라 말투를 말한다
///   2. 확신이 약하면 문구와 모양이 함께 약해진다
///   3. 왜 그렇게 판단했는지 손 닿는 곳에 있다
void main() {
  Widget host(Caption caption, {VoidCallback? onToneTap}) => MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              CaptionTile(
                caption: caption,
                textScale: 1,
                loudnessScaling: true,
                animationsEnabled: false,
                reduceMotion: true,
                onToneTap: onToneTap,
              ),
            ],
          ),
        ),
      );

  const angryConfident = Caption(
    sequence: 0,
    text: '그러니까 몇 번을 말해',
    tone: EmotionTone.angry,
    toneConfidence: 0.82,
    intensity: 0.8,
    toneBasis: ToneBasis.voiceText,
  );

  const angryWeak = Caption(
    sequence: 0,
    text: '그러니까 몇 번을 말해',
    tone: EmotionTone.angry,
    toneConfidence: 0.45,
    intensity: 0.8,
    toneBasis: ToneBasis.voice,
  );

  group('배지 문구', () {
    testWidgets('감정이 아니라 들린 말투를 적는다', (tester) async {
      await tester.pumpWidget(host(angryConfident));

      expect(find.text('화난 말투로 들림'), findsOneWidget);
      // 단정형은 화면에 없어야 한다.
      expect(find.text('화남'), findsNothing);
    });

    testWidgets('확신이 약하면 문구가 함께 약해진다', (tester) async {
      await tester.pumpWidget(host(angryWeak));

      expect(find.text('화난 말투일 수도'), findsOneWidget);
      expect(find.text('화난 말투로 들림'), findsNothing);
    });

    testWidgets('확신이 약한 배지는 배경을 채우지 않는다', (tester) async {
      // 확신의 정도가 색 진하기에만 걸려 있으면 흑백·색각이상·저시력에서
      // 사라진다. 채움 여부는 그런 환경에서도 남는 단서다.
      Future<Decoration?> badgeDecoration(Caption caption) async {
        await tester.pumpWidget(host(caption));
        final box = tester.widget<Container>(
          find
              .ancestor(
                of: find.textContaining('화난 말투'),
                matching: find.byType(Container),
              )
              .first,
        );
        return box.decoration;
      }

      final weak = await badgeDecoration(angryWeak) as BoxDecoration?;
      final strong = await badgeDecoration(angryConfident) as BoxDecoration?;

      expect(weak?.color, isNull);
      expect(strong?.color, isNotNull);
      // 테두리는 양쪽 다 있어야 배지 모양이 유지된다.
      expect(weak?.border, isNotNull);
    });

    testWidgets('신뢰도가 아주 낮으면 아무것도 표시하지 않는다', (tester) async {
      // 틀린 말투를 자신 있게 보여주는 것이 안 보여주는 것보다 해롭다.
      await tester.pumpWidget(host(const Caption(
        sequence: 0,
        text: '아 그래요',
        tone: EmotionTone.angry,
        toneConfidence: 0.2,
      )));

      expect(find.textContaining('화난 말투'), findsNothing);
    });
  });

  group('판단 근거 열기', () {
    testWidgets('배지를 누르면 근거가 나온다', (tester) async {
      var opened = false;
      await tester.pumpWidget(host(angryConfident, onToneTap: () => opened = true));

      await tester.tap(find.text('화난 말투로 들림'));
      await tester.pump();

      expect(opened, isTrue);
    });

    testWidgets('스크린리더 사용자도 근거에 닿을 수 있다', (tester) async {
      // 타일이 excludeSemantics 로 내용을 한 줄 요약으로 합치기 때문에, 배지의
      // 버튼 시맨틱이 지워진다. 커스텀 동작으로 다시 노출하지 않으면 검증이
      // 가장 필요한 사용자만 근거를 못 본다.
      await tester.pumpWidget(host(angryConfident, onToneTap: () {}));

      final node = tester.getSemantics(find.byType(CaptionTile));
      expect(
        node.getSemanticsData().customSemanticsActionIds,
        isNotEmpty,
        reason: '"말투 판단 근거 보기" 커스텀 동작이 없다',
      );
    });

    testWidgets('표시가 없는 줄에는 근거 동작도 달지 않는다', (tester) async {
      await tester.pumpWidget(host(
        const Caption(
          sequence: 0,
          text: '아 그래요',
          tone: EmotionTone.angry,
          toneConfidence: 0.2,
        ),
        onToneTap: () {},
      ));

      final node = tester.getSemantics(find.byType(CaptionTile));
      expect(node.getSemanticsData().customSemanticsActionIds, isEmpty);
    });
  });

  group('근거 시트', () {
    Future<void> open(WidgetTester tester, Caption caption) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showToneBasisSheet(context, caption),
              child: const Text('열기'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();
    }

    testWidgets('추정이라는 사실과 확신 정도를 함께 보여준다', (tester) async {
      await open(tester, angryConfident);

      expect(find.text('이 표시는 추정입니다'), findsOneWidget);
      expect(find.textContaining('82%'), findsOneWidget);
    });

    testWidgets('목소리만 본 판정은 그 사실을 명시한다', (tester) async {
      // 여기가 오해가 가장 크게 생기는 지점이다. 사투리·평소 목소리 크기·말
      // 빠르기가 전부 운율에 섞여 들어온다.
      await open(tester, angryWeak);

      expect(find.textContaining('반영하지 않았습니다'), findsOneWidget);
    });

    testWidgets('문장까지 본 판정은 반영했다고 적는다', (tester) async {
      await open(tester, angryConfident);

      expect(find.text('반영했습니다.'), findsOneWidget);
    });

    testWidgets('빗나가는 경우를 구체적으로 알려준다', (tester) async {
      // "정확하지 않을 수 있습니다" 같은 일반론은 아무 행동도 바꾸지 못한다.
      // 자기 상황이 목록에 있으면 그때부터 표시를 다르게 읽게 된다.
      await open(tester, angryConfident);

      expect(find.text('원래 목소리가 크거나 낮은 사람'), findsOneWidget);
      expect(find.text('사투리나 억양이 다른 경우'), findsOneWidget);
      expect(find.text('말투 특성이 다른 사람 (자폐 스펙트럼 등)'), findsOneWidget);
      expect(find.text('신나서 흥분한 것을 화난 것으로 볼 때'), findsOneWidget);
    });

    testWidgets('글자를 크게 써도 내용이 잘리지 않는다', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
          child: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showToneBasisSheet(context, angryWeak),
                child: const Text('열기'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      // 스크롤로 마지막 줄까지 닿아야 한다.
      await tester.dragUntilVisible(
        find.textContaining('중요한 이야기는 직접 확인'),
        find.byType(SingleChildScrollView),
        const Offset(0, -80),
      );
      expect(find.textContaining('중요한 이야기는 직접 확인'), findsOneWidget);
    });
  });
}
