import 'package:flutter/material.dart';

import '../../../core/theme/emotion_style.dart';
import '../../../domain/entities/caption.dart';
import '../../../domain/entities/emotion_tone.dart';

/// 말투 판정의 근거를 보여주는 시트.
///
/// ## 왜 필요한가
///
/// 자막 옆에 "화난 말투로 들림"이 뜨면 사용자는 그걸 꽤 강한 사실로 받아들인다.
/// 그런데 이 판정은 목소리와 문장에서 뽑은 추정이고, 사람에 따라 크게 빗나간다 —
/// 원래 목소리가 큰 사람, 사투리, 신나서 흥분한 사람, 말투 특성이 다른 사람,
/// 문화·연령에 따른 표현 차이.
///
/// 특히 이 앱의 사용자는 소리를 못 듣기 때문에 **판정을 스스로 검증할 수 없다.**
/// 들리는 사람이라면 "화남"이 떠도 목소리를 직접 듣고 아니라고 판단할 수 있지만,
/// 여기서는 화면이 유일한 통로다. 그래서 결론만 주고 끝내면 안 되고, 무엇을 보고
/// 그렇게 판단했는지와 어떤 경우에 틀리는지를 손 닿는 곳에 두어야 한다.
///
/// 신뢰도 임계값은 *얼마나* 표시할지를 정할 뿐, *왜 그렇게 봤는지*는 말해 주지
/// 않는다. 이 시트가 그 자리를 메운다.
Future<void> showToneBasisSheet(BuildContext context, Caption caption) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _ToneBasisSheet(caption: caption),
  );
}

class _ToneBasisSheet extends StatelessWidget {
  const _ToneBasisSheet({required this.caption});

  final Caption caption;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = EmotionStyle.of(caption.tone);
    final color = style.colorOf(theme.brightness);
    final percent = (caption.toneConfidence * 100).round();

    return SafeArea(
      // 시스템 글꼴을 크게 쓰는 사용자에게도 내용이 잘리면 안 된다. 이 시트는
      // 설명이 본체라 스크롤 없이는 큰 배율에서 아래가 날아간다.
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '이 표시는 추정입니다',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '실제 감정이 아니라, 목소리와 문장에서 짐작한 결과입니다.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),

            const SizedBox(height: 18),

            // ------------------------------------------------ 무엇으로 봤는가
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.09),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: color.withValues(alpha: 0.35)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(style.icon, size: 18, color: color),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          style.heardPhrase,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: color,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _ConfidenceBar(percent: percent, color: color),
                ],
              ),
            ),

            const SizedBox(height: 20),

            _SectionTitle('무엇을 보고 판단했나'),
            const SizedBox(height: 8),
            _BasisRow(
              icon: Icons.graphic_eq_rounded,
              title: '목소리',
              detail: _voiceDetail(caption),
            ),
            _BasisRow(
              icon: Icons.chat_bubble_outline_rounded,
              title: '문장 내용',
              detail: caption.toneBasis == ToneBasis.voiceText
                  ? '반영했습니다.'
                  : '반영하지 않았습니다. 목소리만 보고 짐작한 결과라 더 자주 빗나갑니다.',
              // 근거가 약한 쪽을 눈에 띄게 한다. 여기가 오해가 생기는 지점이다.
              warn: caption.toneBasis == ToneBasis.voice,
            ),

            const SizedBox(height: 20),

            _SectionTitle('이런 경우에는 빗나갑니다'),
            const SizedBox(height: 8),
            // 사용자가 "왜 나한테는 자꾸 틀리지"라고 느낄 때, 자기 탓이나 상대
            // 탓이 아니라 이 기능의 한계임을 알 수 있어야 한다.
            ...const [
              '원래 목소리가 크거나 낮은 사람',
              '사투리나 억양이 다른 경우',
              '신나서 흥분한 것을 화난 것으로 볼 때',
              '말투 특성이 다른 사람 (자폐 스펙트럼 등)',
              '문화나 연령에 따른 표현 차이',
              '주변이 시끄러워 목소리를 크게 낼 때',
            ].map(_BulletLine.new),

            const SizedBox(height: 18),

            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 20,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '확실하지 않을 때는 표시가 흐려지거나 아예 나오지 않습니다. '
                      '말투 표시는 참고만 하시고, 중요한 이야기는 직접 확인해 주세요.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1.45,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 세기를 사람이 읽을 수 있는 말로. 숫자(dBFS)는 사용자에게 의미가 없다.
  static String _voiceDetail(Caption caption) {
    final volume = switch (caption.intensity) {
      > 0.75 => '크게',
      < 0.3 => '작게',
      _ => '보통 크기로',
    };
    return '$volume 말했습니다. 높낮이와 빠르기도 함께 봤습니다.';
  }
}

class _ConfidenceBar extends StatelessWidget {
  const _ConfidenceBar({required this.percent, required this.color});

  final int percent;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 확신 정도를 숫자로도 준다. 막대만 있으면 대략적인 인상만 남고, 사용자가
    // "이건 60%짜리 짐작"이라고 구체적으로 인식하기 어렵다.
    final word = switch (percent) {
      >= 80 => '꽤 확실함',
      >= 60 => '어느 정도 확실함',
      _ => '확실하지 않음',
    };

    return Semantics(
      label: '확신 정도 $percent 퍼센트, $word',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '확신 정도 $percent%',
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '· $word',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: percent / 100,
              minHeight: 7,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: Theme.of(context)
            .textTheme
            .titleSmall
            ?.copyWith(fontWeight: FontWeight.w800),
      );
}

class _BasisRow extends StatelessWidget {
  const _BasisRow({
    required this.icon,
    required this.title,
    required this.detail,
    this.warn = false,
  });

  final IconData icon;
  final String title;
  final String detail;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = warn
        ? theme.colorScheme.error
        : theme.colorScheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(warn ? Icons.error_outline_rounded : icon, size: 18, color: tint),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                Text(
                  detail,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: tint,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BulletLine extends StatelessWidget {
  const _BulletLine(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 7, right: 9),
            child: Container(
              width: 4,
              height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.onSurfaceVariant,
                shape: BoxShape.circle,
              ),
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}
