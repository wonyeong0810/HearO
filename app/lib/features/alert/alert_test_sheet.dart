import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/emotion_tone.dart';
import 'alert_service.dart';

/// 어떤 경보로 알림을 테스트할지 고르는 시트.
///
/// 종류를 고르게 하는 이유는 **심각도마다 실제로 다른 것이 동작하기 때문**이다.
/// 진동 패턴이 다르고, 손전등 점멸과 잠금화면 전체화면 알림은 심각도 3 에서만
/// 켜진다. 하나만 눌러 보고 "잘 되는구나" 하면, 정작 화재경보가 울릴 때 처음
/// 보는 동작이 남는다.
Future<void> showAlertTestSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => const _AlertTestSheet(),
  );
}

class _AlertTestSheet extends ConsumerWidget {
  const _AlertTestSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return SafeArea(
      child: ConstrainedBox(
        // 글꼴을 크게 쓰는 사용자에게도 시트가 화면을 넘지 않아야 한다.
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('알림 테스트', style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                '고른 경보가 실제로 감지된 것처럼 진동·화면·손전등이 동작합니다. '
                '실제 경보가 아니며 경보 기록에도 남지 않습니다.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 16),
              for (final type in AlertType.values)
                _TypeTile(
                  type: type,
                  onTap: () {
                    Navigator.of(context).pop();
                    ref.read(alertServiceProvider.notifier).runSelfTest(type);
                  },
                ),
              const SizedBox(height: 12),
              _Note(
                '테스트 화면은 20초 뒤 저절로 닫힙니다. '
                '진동이나 손전등이 동작하지 않으면 기기 설정에서 권한과 절전 모드를 '
                '확인해 주세요.',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TypeTile extends StatelessWidget {
  const _TypeTile({required this.type, required this.onTap});

  final AlertType type;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final critical = type.severity >= 3;

    // 심각도를 색으로만 구분하지 않는다 (이 앱의 접근성 원칙). 색 + 아이콘 +
    // 한국어 라벨을 함께 준다.
    final color = critical
        ? theme.colorScheme.error
        : theme.colorScheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Icon(
                  critical
                      ? Icons.warning_amber_rounded
                      : Icons.notifications_active_outlined,
                  color: color,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        type.labelKo,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _describe(type),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.play_arrow_rounded, color: color),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 이 종류를 테스트하면 **무엇이 켜지는지** 적는다. 심각도 숫자만 보여주면
  /// 사용자가 무엇을 확인해야 하는지 알 수 없다.
  String _describe(AlertType type) => switch (type.severity) {
        3 => '심각 · 진동 반복 + 손전등 점멸 + 잠금화면 알림',
        2 => '주의 · 짧은 진동 3회 + 전체화면 경고',
        _ => '알림 · 짧은 진동 2회 + 전체화면 경고',
      };
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.info_outline_rounded,
          size: 18,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
        ),
      ],
    );
  }
}
