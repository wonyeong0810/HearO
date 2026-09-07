import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/theme/emotion_style.dart';
import '../../domain/entities/conversation.dart';
import '../../domain/entities/emotion_tone.dart';
import 'history_controller.dart';
import 'widgets/filter_sheet.dart';

/// 대화 기록 목록 (기획 3-2).
class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  final _scrollController = ScrollController();
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(() {
      final position = _scrollController.position;
      // 바닥에 가까워지면 미리 다음 페이지를 불러온다.
      if (position.pixels > position.maxScrollExtent - 400) {
        ref.read(historyControllerProvider.notifier).loadMore();
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(historyControllerProvider);
    final controller = ref.read(historyControllerProvider.notifier);
    final theme = Theme.of(context);

    ref.listen<HistoryState>(historyControllerProvider, (previous, next) {
      final message = next.errorMessage;
      if (message != null && message != previous?.errorMessage) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
        controller.clearError();
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('대화 기록'),
        actions: [
          IconButton(
            onPressed: () => context.push('/bookmarks'),
            icon: const Icon(Icons.bookmark_outline_rounded),
            tooltip: '즐겨찾기한 자막',
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    onChanged: controller.search,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: '대화 내용 검색',
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: state.filter.query.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear_rounded),
                              tooltip: '검색어 지우기',
                              onPressed: () {
                                _searchController.clear();
                                controller.search('');
                              },
                            ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _FilterButton(
                  activeCount: state.filter.activeCount,
                  onPressed: () => _openFilters(context, state, controller),
                ),
              ],
            ),
          ),
          if (state.filter.activeCount > 0)
            _ActiveFilterRow(
              filter: state.filter,
              onClear: controller.clearFilters,
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: controller.refresh,
              child: _buildBody(state, controller, theme),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(
    HistoryState state,
    HistoryController controller,
    ThemeData theme,
  ) {
    if (state.isLoading && state.items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state.items.isEmpty) {
      return _EmptyHistory(hasFilters: !state.filter.isEmpty);
    }

    return ListView.separated(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      itemCount: state.items.length + (state.isLoadingMore ? 1 : 0),
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        if (index >= state.items.length) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final session = state.items[index];
        return _ConversationCard(
          session: session,
          onTap: () => context.push('/history/${session.id}'),
          onToggleFavorite: () => controller.toggleFavorite(session),
          onDelete: () => _confirmDelete(context, session, controller),
          onRename: () => _promptRename(context, session, controller),
        );
      },
    );
  }

  Future<void> _openFilters(
    BuildContext context,
    HistoryState state,
    HistoryController controller,
  ) async {
    final result = await showModalBottomSheet<HistoryFilter>(
      context: context,
      isScrollControlled: true,
      builder: (_) => FilterSheet(initial: state.filter),
    );
    if (result != null) controller.applyFilter(result);
  }

  Future<void> _confirmDelete(
    BuildContext context,
    ConversationSummary session,
    HistoryController controller,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('대화를 삭제할까요?'),
        content: Text(
          '"${session.displayTitle}" 의 자막 ${session.utteranceCount}줄이 '
          '모두 삭제됩니다. 되돌릴 수 없습니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) await controller.delete(session);
  }

  Future<void> _promptRename(
    BuildContext context,
    ConversationSummary session,
    HistoryController controller,
  ) async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => RenameDialog(initialTitle: session.title ?? ''),
    );
    if (result != null && result.isNotEmpty) {
      await controller.rename(session, result);
    }
  }
}

/// 대화 이름 바꾸기 대화상자.
///
/// **컨트롤러를 이 위젯이 직접 들고 있어야 한다.** 바깥 함수에서 만들어
/// `showDialog` 가 끝나자마자 `dispose()` 하면, 닫히는 애니메이션이 아직
/// 도는 동안 `TextField` 가 이미 버려진 컨트롤러를 계속 듣고 있어서
/// `'_dependents.isEmpty': is not true` 로 붉은 화면이 뜬다.
///
/// 이름은 pop 하기 전에 이미 읽어 넘기므로 실제 저장은 되고, 화면만 깨진다 —
/// 그래서 "에러가 떴는데 이름은 바뀌어 있는" 형태로 나타났다.
class RenameDialog extends StatefulWidget {
  const RenameDialog({required this.initialTitle, super.key});

  final String initialTitle;

  @override
  State<RenameDialog> createState() => RenameDialogState();
}

class RenameDialogState extends State<RenameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialTitle);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _controller.text.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('대화 이름 바꾸기'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 60,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        decoration: const InputDecoration(
          hintText: '예: 병원 진료, 팀 회의',
          counterText: '',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        FilledButton(onPressed: _submit, child: const Text('저장')),
      ],
    );
  }
}

class _ConversationCard extends StatelessWidget {
  const _ConversationCard({
    required this.session,
    required this.onTap,
    required this.onToggleFavorite,
    required this.onDelete,
    required this.onRename,
  });

  final ConversationSummary session;
  final VoidCallback onTap;
  final VoidCallback onToggleFavorite;
  final VoidCallback onDelete;
  final VoidCallback onRename;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tone = session.dominantTone;

    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      session.displayTitle,
                      style: theme.textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    onPressed: onToggleFavorite,
                    tooltip: session.isFavorite ? '즐겨찾기 해제' : '즐겨찾기',
                    icon: Icon(
                      session.isFavorite
                          ? Icons.star_rounded
                          : Icons.star_outline_rounded,
                      color: session.isFavorite
                          ? const Color(0xFFCA8A04)
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: '더 보기',
                    onSelected: (value) => switch (value) {
                      'rename' => onRename(),
                      'delete' => onDelete(),
                      _ => null,
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'rename', child: Text('이름 바꾸기')),
                      PopupMenuItem(value: 'delete', child: Text('삭제')),
                    ],
                  ),
                ],
              ),
              if (session.previewText != null) ...[
                const SizedBox(height: 4),
                Text(
                  session.previewText!,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _MetaChip(
                    icon: Icons.schedule_rounded,
                    label: DateFormat('M월 d일 (E) HH:mm', 'ko')
                        .format(session.startedAt),
                  ),
                  if (session.durationSeconds > 0)
                    _MetaChip(
                      icon: Icons.timer_outlined,
                      label: _formatDuration(session.duration),
                    ),
                  if (session.speakerCount > 0)
                    _MetaChip(
                      icon: Icons.people_outline_rounded,
                      label: '화자 ${session.speakerCount}명',
                    ),
                  _MetaChip(
                    icon: Icons.subtitles_outlined,
                    label: '${session.utteranceCount}줄',
                  ),
                  if (session.locationLabel != null)
                    _MetaChip(
                      icon: Icons.place_outlined,
                      label: session.locationLabel!,
                    ),
                  if (tone != null) _TonePill(tone: tone),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _TonePill extends StatelessWidget {
  const _TonePill({required this.tone});

  final EmotionTone tone;

  @override
  Widget build(BuildContext context) {
    final style = EmotionStyle.of(tone);
    final color = style.colorOf(Theme.of(context).brightness);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(style.icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(
            '주로 ${style.label}',
            style: TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterButton extends StatelessWidget {
  const _FilterButton({required this.activeCount, required this.onPressed});

  final int activeCount;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Badge(
      isLabelVisible: activeCount > 0,
      label: Text('$activeCount'),
      child: IconButton.filledTonal(
        onPressed: onPressed,
        tooltip: '필터',
        style: IconButton.styleFrom(
          minimumSize: const Size(52, 52),
          backgroundColor: activeCount > 0
              ? theme.colorScheme.secondaryContainer
              : theme.colorScheme.surfaceContainerHighest,
        ),
        icon: const Icon(Icons.tune_rounded),
      ),
    );
  }
}

class _ActiveFilterRow extends StatelessWidget {
  const _ActiveFilterRow({required this.filter, required this.onClear});

  final HistoryFilter filter;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final labels = <String>[
      if (filter.favoritesOnly) '즐겨찾기만',
      if (filter.dateFrom != null || filter.dateTo != null) _dateLabel(),
      if (filter.location?.isNotEmpty ?? false) '위치: ${filter.location}',
      if (filter.speakerName?.isNotEmpty ?? false) '화자: ${filter.speakerName}',
      if (filter.tone != null) '말투: ${filter.tone!.labelKo}',
    ];

    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          for (final label in labels) ...[
            Chip(
              label: Text(label),
              visualDensity: VisualDensity.compact,
            ),
            const SizedBox(width: 8),
          ],
          ActionChip(
            avatar: const Icon(Icons.clear_rounded, size: 16),
            label: const Text('전체 해제'),
            onPressed: onClear,
          ),
        ],
      ),
    );
  }

  String _dateLabel() {
    final format = DateFormat('M/d');
    final from = filter.dateFrom;
    final to = filter.dateTo;
    if (from != null && to != null) {
      return '${format.format(from)} ~ ${format.format(to)}';
    }
    if (from != null) return '${format.format(from)} 이후';
    return '${format.format(to!)} 이전';
  }
}

class _EmptyHistory extends StatelessWidget {
  const _EmptyHistory({required this.hasFilters});

  final bool hasFilters;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListView(
      // RefreshIndicator 가 동작하려면 스크롤 가능해야 한다.
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(height: MediaQuery.sizeOf(context).height * 0.2),
        Icon(
          hasFilters ? Icons.search_off_rounded : Icons.history_rounded,
          size: 64,
          color: theme.colorScheme.outline,
        ),
        const SizedBox(height: 16),
        Text(
          hasFilters ? '조건에 맞는 대화가 없습니다' : '아직 저장된 대화가 없습니다',
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Text(
            hasFilters
                ? '검색어나 필터를 바꿔 보세요.'
                : '실시간 자막을 켜면 대화가 자동으로 저장됩니다.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

String _formatDuration(Duration duration) {
  if (duration.inHours > 0) {
    return '${duration.inHours}시간 ${duration.inMinutes.remainder(60)}분';
  }
  if (duration.inMinutes > 0) return '${duration.inMinutes}분';
  return '${duration.inSeconds}초';
}
