import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/theme/emotion_style.dart';
import '../../domain/entities/conversation.dart';
import 'history_controller.dart';

/// 즐겨찾기한 자막 모아보기 (기획 3-2 "중요 대화 즐겨찾기").
///
/// 대화 단위가 아니라 **자막 줄 단위**로 모은다. 병원에서 들은 복약 안내
/// 한 줄, 약속 시간 한 줄처럼 다시 확인해야 하는 건 대개 대화 전체가 아니라
/// 특정 문장이기 때문이다.
class BookmarksScreen extends ConsumerWidget {
  const BookmarksScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bookmarks = ref.watch(bookmarksProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('즐겨찾기한 자막')),
      body: bookmarks.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text('불러오지 못했습니다: $error', textAlign: TextAlign.center),
          ),
        ),
        data: (page) => page.items.isEmpty
            ? const _EmptyBookmarks()
            : RefreshIndicator(
                onRefresh: () async => ref.invalidate(bookmarksProvider),
                child: ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: page.items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final hit = page.items[index];
                    return _BookmarkCard(
                      hit: hit,
                      onTap: () => context.push('/history/${hit.sessionId}'),
                    );
                  },
                ),
              ),
      ),
    );
  }
}

class _BookmarkCard extends StatelessWidget {
  const _BookmarkCard({required this.hit, required this.onTap});

  final CaptionSearchHit hit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = EmotionStyle.of(hit.tone);
    final toneColor = style.colorOf(theme.brightness);

    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                hit.text,
                style: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    hit.speakerDisplay,
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: hit.speakerColor == null
                          ? theme.colorScheme.onSurfaceVariant
                          : _parseColor(hit.speakerColor!),
                    ),
                  ),
                  // 아이콘만 두면 색과 모양으로만 말투를 주장하는 셈이라,
                  // 무슨 뜻인지도 짐작이라는 사실도 알 수 없다. 짧은 이름을
                  // 함께 붙인다 (이 앱의 "색만으로 전달하지 않는다" 원칙).
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(style.icon, size: 13, color: toneColor),
                      const SizedBox(width: 3),
                      Text(
                        style.label,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: toneColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  Text(
                    hit.sessionTitle ??
                        DateFormat('M월 d일').format(hit.sessionStartedAt),
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _parseColor(String hex) =>
      Color(0xFF000000 | int.parse(hex.replaceFirst('#', ''), radix: 16));
}

class _EmptyBookmarks extends StatelessWidget {
  const _EmptyBookmarks();

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
              Icons.bookmark_border_rounded,
              size: 64,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text('즐겨찾기한 자막이 없습니다', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              '대화 기록에서 자막을 길게 누르면 즐겨찾기에 추가할 수 있습니다.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
