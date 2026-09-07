import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../domain/entities/conversation.dart';
import 'live_controller.dart';
import 'widgets/caption_tile.dart';
import 'widgets/speaker_legend.dart';
import 'widgets/tone_basis_sheet.dart';

/// 실시간 자막 화면 (기획 1).
class LiveScreen extends ConsumerStatefulWidget {
  const LiveScreen({super.key});

  @override
  ConsumerState<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends ConsumerState<LiveScreen> {
  final _scrollController = ScrollController();

  /// 사용자가 위로 스크롤해 지난 자막을 읽고 있으면 자동 스크롤을 멈춘다.
  /// 읽는 도중 화면이 끌려가면 대화를 따라갈 수 없다.
  bool _autoScroll = true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    // 자막을 보는 동안 화면이 꺼지면 안 된다.
    WakelockPlus.enable();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final atBottom = position.pixels >= position.maxScrollExtent - 80;
    if (atBottom != _autoScroll) {
      setState(() => _autoScroll = atBottom);
    }
  }

  void _scrollToBottom() {
    if (!_autoScroll || !_scrollController.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(liveControllerProvider);
    final controller = ref.read(liveControllerProvider.notifier);
    final settings = ref.watch(settingsProvider).valueOrNull ?? const AppSettings();
    final reduceMotion = ref.watch(reduceMotionProvider);

    ref.listen<LiveState>(liveControllerProvider, (previous, next) {
      if (next.captions.length != previous?.captions.length ||
          next.partialText != previous?.partialText) {
        _scrollToBottom();
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('실시간 자막'),
        actions: [
          if (state.isRunning)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Center(child: _ElapsedBadge(elapsed: state.elapsed)),
            ),
        ],
      ),
      body: Column(
        children: [
          if (state.isReconnecting)
            _Banner(
              icon: Icons.wifi_tethering_error_rounded,
              message: state.statusMessage ?? '음성 인식 서버에 다시 연결하는 중…',
              color: Theme.of(context).colorScheme.tertiaryContainer,
              onColor: Theme.of(context).colorScheme.onTertiaryContainer,
            ),
          if (state.errorMessage != null)
            _Banner(
              icon: Icons.error_outline_rounded,
              message: state.errorMessage!,
              color: Theme.of(context).colorScheme.errorContainer,
              onColor: Theme.of(context).colorScheme.onErrorContainer,
              onDismiss: controller.clearError,
            ),
          // 말투 표시가 짐작이라는 사실은 자막이 처음 흐를 때 알아야 의미가
          // 있다. 이미 여러 줄을 사실로 받아들인 뒤에 알려주면 늦다.
          if (state.hasContent && ref.watch(toneDisclaimerProvider).valueOrNull == false)
            _Banner(
              icon: Icons.psychology_alt_outlined,
              message: '말투 표시는 목소리와 문장으로 짐작한 것입니다. '
                  '실제 감정과 다를 수 있어요. 표시를 누르면 판단 근거를 볼 수 있습니다.',
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              onColor: Theme.of(context).colorScheme.onSurface,
              onDismiss: () =>
                  ref.read(toneDisclaimerProvider.notifier).dismiss(),
            ),
          if (state.speakers.isNotEmpty)
            SpeakerLegend(
              speakers: state.speakers,
              onRename: controller.renameSpeaker,
              onRecolor: controller.recolorSpeaker,
            ),
          Expanded(
            child: state.hasContent
                ? _CaptionList(
                    scrollController: _scrollController,
                    state: state,
                    settings: settings,
                    reduceMotion: reduceMotion,
                  )
                : _EmptyState(
                    phase: state.phase,
                    isDemo: state.isDemo,
                    onTryDemo: controller.startDemo,
                  ),
          ),
          if (!_autoScroll && state.isRunning)
            _JumpToLatestButton(
              onPressed: () {
                setState(() => _autoScroll = true);
                _scrollToBottom();
              },
            ),
          _ControlBar(
            state: state,
            onStart: () => controller.start(),
            onStop: controller.stop,
            onTryDemo: controller.startDemo,
          ),
        ],
      ),
    );
  }
}

class _CaptionList extends StatelessWidget {
  const _CaptionList({
    required this.scrollController,
    required this.state,
    required this.settings,
    required this.reduceMotion,
  });

  final ScrollController scrollController;
  final LiveState state;
  final AppSettings settings;
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) {
    final hasPartial = state.partialText.isNotEmpty;

    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      // 자막이 많아지면 화면 밖 항목은 만들지 않는다.
      itemCount: state.captions.length + (hasPartial ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= state.captions.length) {
          return _PartialCaption(
            text: state.partialText,
            scale: settings.captionTextScale,
          );
        }
        final caption = state.captions[index];
        return CaptionTile(
          key: ValueKey(caption.sequence),
          caption: caption,
          textScale: settings.captionTextScale,
          loudnessScaling: settings.loudnessScalingEnabled,
          animationsEnabled: settings.emotionAnimationEnabled,
          reduceMotion: reduceMotion,
          onToneTap: () => showToneBasisSheet(context, caption),
        );
      },
    );
  }
}

/// 아직 확정되지 않은 잠정 자막. 확정본과 시각적으로 구분되어야 한다 —
/// 지금 보이는 글자가 바뀔 수 있다는 걸 알려야 오해가 없다.
class _PartialCaption extends StatelessWidget {
  const _PartialCaption({required this.text, required this.scale});

  final String text;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 5,
            constraints: const BoxConstraints(minHeight: 30),
            margin: const EdgeInsets.only(top: 4),
            decoration: BoxDecoration(
              color: theme.colorScheme.outlineVariant,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: CaptionSizing.base * scale * 0.95,
                height: 1.42,
                color: theme.colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ControlBar extends StatelessWidget {
  const _ControlBar({
    required this.state,
    required this.onStart,
    required this.onStop,
    required this.onTryDemo,
  });

  final LiveState state;
  final VoidCallback onStart;
  final Future<void> Function() onStop;
  final VoidCallback onTryDemo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final running = state.isRunning;

    if (state.isDemo) {
      return Container(
        padding: EdgeInsets.fromLTRB(
          16,
          12,
          16,
          12 + MediaQuery.paddingOf(context).bottom,
        ),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainer,
          border:
              Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _MicLevelMeter(level: state.micLevel),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: () => onStop(),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(60),
                ),
                icon: const Icon(Icons.close_rounded, size: 26),
                label: const Text('자막 끄기', style: TextStyle(fontSize: 18)),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: EdgeInsets.fromLTRB(
        16,
        12,
        16,
        12 + MediaQuery.paddingOf(context).bottom,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (running) ...[
            _MicLevelMeter(level: state.micLevel),
            const SizedBox(height: 12),
          ],
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: state.phase == LivePhase.starting ||
                      state.phase == LivePhase.stopping
                  ? null
                  : (running ? () => onStop() : onStart),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(60),
                backgroundColor: running ? theme.colorScheme.error : null,
                foregroundColor: running ? theme.colorScheme.onError : null,
              ),
              icon: Icon(
                running ? Icons.stop_rounded : Icons.mic_rounded,
                size: 26,
              ),
              label: Text(
                switch (state.phase) {
                  LivePhase.starting => '시작하는 중…',
                  LivePhase.stopping => '저장하는 중…',
                  LivePhase.listening => '자막 끄기',
                  _ => '자막 켜기',
                },
                style: const TextStyle(fontSize: 18),
              ),
            ),
          ),
          if (state.pendingSpeakerCount > 0) ...[
            const SizedBox(height: 8),
            Text(
              '화자 확인 중인 자막 ${state.pendingSpeakerCount}줄',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 마이크가 실제로 소리를 받고 있는지 보여준다.
/// 소리를 못 듣는 사용자에게는 "마이크가 살아있다"는 유일한 확인 수단이다.
class _MicLevelMeter extends StatelessWidget {
  const _MicLevelMeter({required this.level});

  final double level;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const barCount = 24;
    final active = (level * barCount).round();

    return Semantics(
      label: '마이크 입력 레벨 ${(level * 100).round()} 퍼센트',
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(barCount, (index) {
          final isActive = index < active;
          // 왼쪽(조용함) → 오른쪽(큼) 으로 갈수록 높아지는 막대
          final height = 6.0 + (index / barCount) * 14;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 90),
            width: 5,
            height: isActive ? height : 5,
            margin: const EdgeInsets.symmetric(horizontal: 2),
            decoration: BoxDecoration(
              color: isActive
                  ? (index > barCount * 0.85
                      ? theme.colorScheme.error
                      : theme.colorScheme.primary)
                  : theme.colorScheme.outlineVariant,
              borderRadius: BorderRadius.circular(3),
            ),
          );
        }),
      ),
    );
  }
}

class _ElapsedBadge extends StatelessWidget {
  const _ElapsedBadge({required this.elapsed});

  final Duration elapsed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final minutes = elapsed.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = elapsed.inSeconds.remainder(60).toString().padLeft(2, '0');
    final text = elapsed.inHours > 0
        ? '${elapsed.inHours}:$minutes:$seconds'
        : '$minutes:$seconds';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: theme.colorScheme.error,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onErrorContainer,
            ),
          ),
        ],
      ),
    );
  }
}

class _JumpToLatestButton extends StatelessWidget {
  const _JumpToLatestButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: FilledButton.tonalIcon(
        onPressed: onPressed,
        icon: const Icon(Icons.arrow_downward_rounded, size: 20),
        label: const Text('최신 자막으로'),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.message,
    required this.color,
    required this.onColor,
    this.onDismiss,
  });

  final IconData icon;
  final String message;
  final Color color;
  final Color onColor;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: color,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(icon, color: onColor, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: onColor,
              ),
            ),
          ),
          if (onDismiss != null)
            IconButton(
              onPressed: onDismiss,
              icon: Icon(Icons.close_rounded, color: onColor),
              tooltip: '닫기',
            ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.phase,
    required this.isDemo,
    required this.onTryDemo,
  });

  final LivePhase phase;
  final bool isDemo;
  final VoidCallback onTryDemo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final (icon, title, body) = switch (phase) {
      LivePhase.starting => (
          Icons.hourglass_top_rounded,
          '연결하는 중…',
          '음성 인식 서버에 연결하고 있습니다.',
        ),
      LivePhase.listening => (
          Icons.hearing_rounded,
          '듣고 있습니다',
          '누군가 말하면 자막이 여기에 나타납니다.',
        ),
      // 이 화면이 비어 있다는 건 자막이 한 줄도 안 잡혔다는 뜻이다.
      // 서버도 그런 세션은 저장하지 않으므로 "저장했습니다" 는 거짓말이 된다.
      LivePhase.ended => (
          Icons.mic_off_rounded,
          '들린 말이 없습니다',
          '자막이 한 줄도 잡히지 않아 기록에 남기지 않았습니다.\n'
              '마이크가 소리를 받고 있었는지 확인해 보세요.',
        ),
      _ => (
          Icons.mic_none_rounded,
          '자막을 시작해 보세요',
          '아래 버튼을 누르면 주변 대화가 실시간으로 자막이 됩니다.\n'
              '화자마다 다른 색으로 표시되고, 말의 감정과 크기도 함께 보여 줍니다.',
        ),
    };

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 72, color: theme.colorScheme.outline),
            const SizedBox(height: 20),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 10),
            Text(
              body,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.6,
              ),
            ),
            // 말을 걸어 줄 사람이 없어도 화면이 어떻게 동작하는지 볼 수 있어야
            // 한다. 마이크 권한도, 인터넷도 필요 없다.
            if (phase == LivePhase.idle || phase == LivePhase.failed) ...[
              const SizedBox(height: 28),
              OutlinedButton.icon(
                onPressed: onTryDemo,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 52),
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                ),
                icon: const Icon(Icons.play_circle_outline_rounded, size: 24),
                label: const Text(
                  '예시로 먼저 보기',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '말하지 않아도 됩니다. 예시 대화로 화면을 미리 봅니다.',
                textAlign: TextAlign.center,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
