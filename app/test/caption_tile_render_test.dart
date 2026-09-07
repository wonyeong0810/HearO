import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearo/domain/entities/caption.dart';
import 'package:hearo/features/live/demo_script.dart';
import 'package:hearo/features/live/widgets/caption_tile.dart';

/// 자막 타일이 대본의 모든 조합에서 실제로 그려지는지 확인한다.
///
/// 화면에서 자막 목록이 통째로 빨간 상자로 나온 적이 있다. Flutter 는 빌드나
/// 레이아웃이 던지면 그 자리에 붉은 오류 위젯을 그리는데, 기기 로그만 봐서는
/// 원인이 안 보인다. 여기서 먼저 걸리게 해 둔다.
void main() {
  Widget host(Caption caption) => MaterialApp(
        home: Scaffold(
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              CaptionTile(
                caption: caption,
                textScale: 1,
                loudnessScaling: true,
                animationsEnabled: true,
                reduceMotion: false,
              ),
            ],
          ),
        ),
      );

  testWidgets('대본의 모든 줄이 예외 없이 그려진다', (tester) async {
    for (var i = 0; i < demoScript.length; i++) {
      final line = demoScript[i];
      final caption = Caption(
        sequence: i,
        text: line.text,
        tone: line.tone,
        toneConfidence: line.toneConfidence,
        intensity: line.intensity,
        speaker: line.speakerLate
            ? null
            : demoSpeakers.firstWhere((s) => s.key == line.speakerKey),
        speakerResolved: !line.speakerLate,
      );

      await tester.pumpWidget(host(caption));
      await tester.pump(const Duration(milliseconds: 300));

      expect(tester.takeException(), isNull, reason: '${i + 1}번째 줄: ${line.text}');
      expect(find.text(line.text), findsOneWidget);

      // 애니메이션이 도는 동안에도 던지지 않아야 한다.
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 3));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('화자 미확정 줄도 그려진다', (tester) async {
    await tester.pumpWidget(host(const Caption(
      sequence: 0,
      text: '주문 도와드릴까요?',
      speakerResolved: false,
    )));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(find.text('화자 확인 중…'), findsOneWidget);
  });

  testWidgets('세기가 최대여도 레이아웃이 깨지지 않는다', (tester) async {
    await tester.pumpWidget(host(Caption(
      sequence: 0,
      text: '봤지! 마지막 5분 진짜 대박이었잖아',
      intensity: 1,
      toneConfidence: 1,
      speaker: demoSpeakers.first,
      speakerResolved: true,
    )));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
  });
}
