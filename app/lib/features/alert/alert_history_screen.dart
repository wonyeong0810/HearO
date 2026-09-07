import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/providers.dart';
import '../../domain/entities/conversation.dart';

final _alertHistoryProvider =
    FutureProvider.autoDispose<Paged<AlertRecord>>((ref) {
  return ref.watch(apiClientProvider).listAlerts(limit: 100);
});

/// 경보 기록 화면.
///
/// 오탐을 신고할 수 있게 해 두었다. 사용자가 "이건 아니었다"고 알려주는 것이
/// 민감도를 조정할 유일한 근거이고, 오탐이 쌓이면 사람들은 기능을 꺼버린다.
class AlertHistoryScreen extends ConsumerWidget {
  const AlertHistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alerts = ref.watch(_alertHistoryProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('경보 기록'),
        actions: [
          IconButton(
            tooltip: '모두 확인 처리',
            icon: const Icon(Icons.done_all_rounded),
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              try {
                final message =
                    await ref.read(apiClientProvider).acknowledgeAllAlerts();
                messenger.showSnackBar(SnackBar(content: Text(message)));
              } on Object catch (error) {
                messenger
                    .showSnackBar(SnackBar(content: Text('처리 실패: $error')));
              }
              ref.invalidate(_alertHistoryProvider);
              ref.invalidate(unacknowledgedAlertCountProvider);
            },
          ),
        ],
      ),
      body: alerts.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text('불러오지 못했습니다: $error', textAlign: TextAlign.center),
          ),
        ),
        data: (page) => page.items.isEmpty
            ? const _EmptyAlerts()
            : RefreshIndicator(
                onRefresh: () async => ref.invalidate(_alertHistoryProvider),
                child: ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: page.items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) => _AlertCard(
                    record: page.items[index],
                    onReportFalsePositive: () async {
                      await ref.read(apiClientProvider).updateAlert(
                            page.items[index].id,
                            isFalsePositive: true,
                            acknowledged: true,
                          );
                      ref.invalidate(_alertHistoryProvider);
                    },
                  ),
                ),
              ),
      ),
    );
  }
}

class _AlertCard extends StatelessWidget {
  const _AlertCard({
    required this.record,
    required this.onReportFalsePositive,
  });

  final AlertRecord record;
  final Future<void> Function() onReportFalsePositive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final severityColor = switch (record.type.severity) {
      3 => const Color(0xFFD32029),
      2 => const Color(0xFFB25E02),
      _ => theme.colorScheme.onSurfaceVariant,
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: severityColor.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.warning_amber_rounded,
                    color: severityColor,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        record.type.labelKo,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: record.isFalsePositive
                              ? theme.colorScheme.onSurfaceVariant
                              : null,
                          decoration: record.isFalsePositive
                              ? TextDecoration.lineThrough
                              : null,
                        ),
                      ),
                      Text(
                        DateFormat('M월 d일 (E) HH:mm:ss', 'ko')
                            .format(record.detectedAt),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  '${(record.confidence * 100).round()}%',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            if (record.isFalsePositive) ...[
              const SizedBox(height: 10),
              Text(
                '오탐으로 신고됨',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ] else ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: onReportFalsePositive,
                  icon: const Icon(Icons.thumb_down_outlined, size: 18),
                  label: const Text('잘못된 감지였어요'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _EmptyAlerts extends StatelessWidget {
  const _EmptyAlerts();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.shield_outlined,
              size: 64,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text('감지된 경보가 없습니다', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              '화재경보나 사이렌이 감지되면 여기에 기록됩니다.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
