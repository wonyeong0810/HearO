import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/providers.dart';
import '../../domain/entities/caption.dart';
import '../../domain/entities/conversation.dart';
import '../live/widgets/caption_tile.dart';
import '../live/widgets/tone_basis_sheet.dart';
import 'history_controller.dart';

/// 저장된 대화 상세 — 자막 전문을 다시 읽는 화면.
class ConversationDetailScreen extends ConsumerWidget {
  const ConversationDetailScreen({required this.sessionId, super.key});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(conversationDetailProvider(sessionId));
    final settings =
        ref.watch(settingsProvider).valueOrNull ?? const AppSettings();
    final reduceMotion = ref.watch(reduceMotionProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(detail.valueOrNull?.summary.displayTitle ?? '대화'),
        actions: [
          if (detail.hasValue)
            IconButton(
              tooltip: '전체 복사',
              icon: const Icon(Icons.copy_all_rounded),
              onPressed: () => _copyTranscript(context, detail.value!),
            ),
        ],
      ),
      body: detail.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _ErrorView(
          message: '$error',
          onRetry: () => ref.invalidate(conversationDetailProvider(sessionId)),
        ),
        data: (data) => _DetailBody(
          detail: data,
          settings: settings,
          reduceMotion: reduceMotion,
          onToggleBookmark: (caption) =>
              _toggleBookmark(ref, sessionId, caption),
        ),
      ),
    );
  }

  Future<void> _toggleBookmark(
    WidgetRef ref,
    String sessionId,
    Caption caption,
  ) async {
    final captionId = caption.id;
    if (captionId == null) return;
    await ref.read(apiClientProvider).updateCaption(
          sessionId,
          captionId,
          isBookmarked: !caption.isBookmarked,
        );
    ref.invalidate(conversationDetailProvider(sessionId));
    ref.invalidate(bookmarksProvider);
  }

  Future<void> _copyTranscript(
    BuildContext context,
    ConversationDetail detail,
  ) async {
    final buffer = StringBuffer()
      ..writeln(detail.summary.displayTitle)
      ..writeln(
        DateFormat('yyyy년 M월 d일 HH:mm').format(detail.summary.startedAt),
      )
      ..writeln();

    for (final caption in detail.captions) {
      final speaker = caption.speaker?.displayLabel ?? '화자 미상';
      buffer.writeln('[$speaker] ${caption.text}');
    }

    await Clipboard.setData(ClipboardData(text: buffer.toString()));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('대화 전문을 클립보드에 복사했습니다.')),
      );
    }
  }
}

class _DetailBody extends StatelessWidget {
  const _DetailBody({
    required this.detail,
    required this.settings,
    required this.reduceMotion,
    required this.onToggleBookmark,
  });

  final ConversationDetail detail;
  final AppSettings settings;
  final bool reduceMotion;
  final void Function(Caption caption) onToggleBookmark;

  @override
  Widget build(BuildContext context) {
    if (detail.captions.isEmpty) {
      return const Center(child: Text('저장된 자막이 없습니다.'));
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      itemCount: detail.captions.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return _SessionHeader(detail: detail);
        }
        final caption = detail.captions[index - 1];
        return Stack(
          children: [
            CaptionTile(
              caption: caption,
              textScale: settings.captionTextScale,
              loudnessScaling: settings.loudnessScalingEnabled,
              // 저장된 기록에서는 애니메이션을 쓰지 않는다. 스크롤하며 읽는
              // 화면에서 글자가 계속 움직이면 오히려 방해된다.
              animationsEnabled: false,
              reduceMotion: reduceMotion,
              showTimestamp: true,
              onLongPress: () => onToggleBookmark(caption),
              // 기록에서도 근거를 볼 수 있어야 한다. 지난 대화를 다시 읽으며
              // "그때 정말 화난 거였나" 를 되짚는 게 오히려 흔한 상황이다.
              onToneTap: () => showToneBasisSheet(context, caption),
            ),
            if (caption.isBookmarked)
              Positioned(
                right: 0,
                top: 8,
                child: Icon(
                  Icons.bookmark_rounded,
                  size: 18,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
          ],
        );
      },
    );
  }
}

class _SessionHeader extends StatelessWidget {
  const _SessionHeader({required this.detail});

  final ConversationDetail detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final summary = detail.summary;

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              DateFormat('yyyy년 M월 d일 (E) HH:mm', 'ko')
                  .format(summary.startedAt),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (summary.locationLabel != null) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Icon(
                    Icons.place_outlined,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    summary.locationLabel!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ],
            if (detail.speakers.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text('참여 화자', style: theme.textTheme.labelLarge),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final speaker in detail.speakers)
                    _SpeakerSummaryChip(speaker: speaker),
                ],
              ),
            ],
            const SizedBox(height: 12),
            Text(
              '자막을 길게 누르면 즐겨찾기에 추가됩니다.',
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

class _SpeakerSummaryChip extends StatelessWidget {
  const _SpeakerSummaryChip({required this.speaker});

  final Speaker speaker;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final minutes = (speaker.totalSpeakingSeconds / 60).toStringAsFixed(1);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: speaker.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: speaker.color, width: 1.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 10,
            height: 10,
            decoration:
                BoxDecoration(color: speaker.color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(
            '${speaker.displayLabel} · ${speaker.utteranceCount}줄 · $minutes분',
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline_rounded,
              size: 56,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(
              '대화를 불러오지 못했습니다',
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('다시 시도'),
            ),
          ],
        ),
      ),
    );
  }
}
