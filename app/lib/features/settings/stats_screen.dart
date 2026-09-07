import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/providers.dart';
import '../../core/theme/emotion_style.dart';
import '../../domain/entities/emotion_tone.dart';

final _statsProvider =
    FutureProvider.autoDispose<Map<String, dynamic>>((ref) {
  return ref.watch(apiClientProvider).getStats();
});

/// 사용 통계.
class StatsScreen extends ConsumerWidget {
  const StatsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(_statsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('사용 통계')),
      body: stats.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text('불러오지 못했습니다: $error', textAlign: TextAlign.center),
          ),
        ),
        data: (data) => _StatsBody(data: data),
      ),
    );
  }
}

class _StatsBody extends StatelessWidget {
  const _StatsBody({required this.data});

  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final totalSessions = (data['total_sessions'] as num?)?.toInt() ?? 0;
    final totalUtterances = (data['total_utterances'] as num?)?.toInt() ?? 0;
    final totalSeconds =
        (data['total_duration_seconds'] as num?)?.toDouble() ?? 0;
    final favorites = (data['favorite_sessions'] as num?)?.toInt() ?? 0;
    final totalAlerts = (data['total_alerts'] as num?)?.toInt() ?? 0;
    final oldest = data['oldest_session_at'] as String?;

    final distribution =
        (data['tone_distribution'] as Map?)?.cast<String, dynamic>() ?? {};
    final toneTotal = distribution.values
        .fold<int>(0, (sum, value) => sum + ((value as num?)?.toInt() ?? 0));

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.5,
          children: [
            _StatCard(
              icon: Icons.forum_outlined,
              label: '저장된 대화',
              value: '$totalSessions',
            ),
            _StatCard(
              icon: Icons.subtitles_outlined,
              label: '자막 줄 수',
              value: NumberFormat.decimalPattern('ko').format(totalUtterances),
            ),
            _StatCard(
              icon: Icons.timer_outlined,
              label: '누적 시간',
              value: _formatHours(totalSeconds),
            ),
            _StatCard(
              icon: Icons.star_outline_rounded,
              label: '즐겨찾기',
              value: '$favorites',
            ),
          ],
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            leading: const Icon(Icons.shield_outlined),
            title: const Text('감지된 경보'),
            trailing: Text(
              '$totalAlerts건',
              style: theme.textTheme.titleMedium,
            ),
          ),
        ),
        if (oldest != null) ...[
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(Icons.calendar_today_outlined),
              title: const Text('가장 오래된 기록'),
              trailing: Text(
                DateFormat('yyyy.M.d')
                    .format(DateTime.parse(oldest).toLocal()),
                style: theme.textTheme.titleMedium,
              ),
            ),
          ),
        ],

        // ---- 말투 분포 ----
        if (toneTotal > 0) ...[
          const SizedBox(height: 24),
          Text('주로 들린 말투', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            '목소리와 문장으로 짐작한 값입니다. 실제 감정과는 다를 수 있습니다.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          for (final entry in _toneCounts(distribution))
            _ToneBar(tone: entry.$1, count: entry.$2, total: toneTotal),
        ],
      ],
    );
  }

  /// 등장한 감정만, 많은 순으로 추린다.
  List<(EmotionTone, int)> _toneCounts(Map<String, dynamic> distribution) {
    final counts = <(EmotionTone, int)>[];
    for (final tone in EmotionTone.values) {
      final count = (distribution[tone.wireValue] as num?)?.toInt() ?? 0;
      if (count > 0) counts.add((tone, count));
    }
    counts.sort((a, b) => b.$2.compareTo(a.$2));
    return counts;
  }

  String _formatHours(double seconds) {
    final duration = Duration(seconds: seconds.round());
    if (duration.inHours > 0) {
      return '${duration.inHours}시간 ${duration.inMinutes.remainder(60)}분';
    }
    return '${duration.inMinutes}분';
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Icon(icon, color: theme.colorScheme.primary),
            Text(value, style: theme.textTheme.headlineSmall),
            Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToneBar extends StatelessWidget {
  const _ToneBar({
    required this.tone,
    required this.count,
    required this.total,
  });

  final EmotionTone tone;
  final int count;
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = EmotionStyle.of(tone);
    final color = style.colorOf(theme.brightness);
    final ratio = total == 0 ? 0.0 : count / total;

    return Semantics(
      label: '${tone.labelKo} ${(ratio * 100).round()} 퍼센트, $count 줄',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(style.icon, size: 16, color: color),
                const SizedBox(width: 8),
                Text(tone.labelKo, style: theme.textTheme.labelLarge),
                const Spacer(),
                Text(
                  '${(ratio * 100).round()}%',
                  style: theme.textTheme.labelLarge?.copyWith(color: color),
                ),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: ratio,
                minHeight: 8,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation(color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
