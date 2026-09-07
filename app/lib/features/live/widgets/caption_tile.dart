import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/emotion_style.dart';
import '../../../domain/entities/caption.dart';

/// 자막 한 줄.
///
/// 기획서의 세 가지 시각화가 여기서 만난다.
///   1-2 화자 분리 → 왼쪽 색 막대 + 이름표 + 글자색
///   1-3 감정/톤   → 아이콘 + 라벨 + 텍스트 애니메이션
///   1-3 말의 세기 → 글자 크기와 굵기
///
/// 색만으로 정보를 전달하지 않는다. 화자는 이름표가, 감정은 아이콘과 라벨이
/// 항상 함께 나온다 — 색각이상 사용자와 흑백 스크린샷에서도 읽혀야 한다.
class CaptionTile extends StatefulWidget {
  const CaptionTile({
    required this.caption,
    required this.textScale,
    required this.loudnessScaling,
    required this.animationsEnabled,
    required this.reduceMotion,
    this.onLongPress,
    this.onToneTap,
    this.showTimestamp = false,
    super.key,
  });

  final Caption caption;

  /// 사용자가 설정에서 정한 자막 배율
  final double textScale;

  /// 음량에 따라 글자 크기를 바꿀지
  final bool loudnessScaling;

  /// 감정 애니메이션을 쓸지
  final bool animationsEnabled;

  /// 시스템 "동작 줄이기"가 켜져 있는지
  final bool reduceMotion;

  final VoidCallback? onLongPress;

  /// 말투 배지를 눌렀을 때. 무엇을 근거로 판단했는지 보여준다.
  final VoidCallback? onToneTap;

  final bool showTimestamp;

  @override
  State<CaptionTile> createState() => _CaptionTileState();
}

// 컨트롤러가 둘(감정 움직임 + 등장 효과)이므로 SingleTicker 를 쓰면 안 된다.
// 두 번째 컨트롤러를 만드는 순간 던지고, 그러면 자막 타일 자리에 붉은 오류
// 상자만 남는다 — 자막이 한 줄도 안 보이는데 로그에는 아무것도 안 남는다.
class _CaptionTileState extends State<CaptionTile>
    with TickerProviderStateMixin {
  late final AnimationController _controller;

  /// 새로 들어온 자막이 부드럽게 나타나는 효과
  late final AnimationController _entrance;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _entrance = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _entrance.forward();
    _syncMotion();
  }

  @override
  void didUpdateWidget(CaptionTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 감정이 나중에 확정되면(patch) 그때 애니메이션을 시작/중지한다.
    if (oldWidget.caption.tone != widget.caption.tone ||
        oldWidget.caption.toneConfidence != widget.caption.toneConfidence ||
        oldWidget.animationsEnabled != widget.animationsEnabled ||
        oldWidget.reduceMotion != widget.reduceMotion) {
      _syncMotion();
    }
  }

  void _syncMotion() {
    final emphasis = _emphasis;
    final style = EmotionStyle.of(widget.caption.tone);

    if (emphasis.motionScale <= 0 || style.motion == EmotionMotion.none) {
      _controller.stop();
      _controller.value = 0;
      return;
    }

    // 감정 표현이 영원히 반복되면 화면이 계속 움직여 피로하고, 스크롤할 때
    // 시선을 뺏는다. 새 자막일 때 몇 번만 강조하고 잦아들게 한다.
    switch (style.motion) {
      case EmotionMotion.shake:
      case EmotionMotion.pulse:
        _controller.repeat(reverse: true, period: const Duration(milliseconds: 420));
        Future<void>.delayed(const Duration(milliseconds: 2100), () {
          if (mounted) _controller.animateTo(0, duration: const Duration(milliseconds: 300));
        });
      case EmotionMotion.bounce:
        _controller.repeat(reverse: true, period: const Duration(milliseconds: 600));
        Future<void>.delayed(const Duration(milliseconds: 2400), () {
          if (mounted) _controller.animateTo(0, duration: const Duration(milliseconds: 300));
        });
      case EmotionMotion.sink:
        _controller.animateTo(1, duration: const Duration(milliseconds: 900));
      case EmotionMotion.none:
        break;
    }
  }

  EmotionEmphasis get _emphasis => EmotionEmphasis.fromConfidence(
        widget.caption.toneConfidence,
        animationsEnabled: widget.animationsEnabled,
        reduceMotion: widget.reduceMotion,
      );

  @override
  void dispose() {
    _controller.dispose();
    _entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brightness = theme.brightness;
    final caption = widget.caption;

    final style = EmotionStyle.of(caption.tone);
    final emphasis = _emphasis;

    final speaker = caption.speaker;
    final speakerColor = speaker?.color ??
        (brightness == Brightness.dark
            ? AppTheme.pendingDark
            : AppTheme.pendingLight);

    final fontSize = CaptionSizing.resolve(
      intensity: caption.intensity,
      userScale: widget.textScale,
      loudnessScaling: widget.loudnessScaling,
    );

    // 감정 색은 글자색에 살짝만 섞는다. 통째로 감정 색으로 칠하면 화자 색과
    // 충돌해 누가 말했는지 알 수 없게 된다 — 화자 구분이 우선이다.
    final emotionColor = style.colorOf(brightness);
    final textColor = emphasis.colorOpacity > 0
        ? Color.lerp(
            theme.colorScheme.onSurface,
            emotionColor,
            emphasis.colorOpacity * 0.35,
          )!
        : theme.colorScheme.onSurface;

    return Semantics(
      // 스크린리더 사용자(청각+시각 중복장애)를 위해 한 줄로 요약한다.
      label: _semanticLabel(caption, style, emphasis),
      excludeSemantics: true,
      // excludeSemantics 가 배지의 버튼 시맨틱까지 지우므로, 근거 보기를 커스텀
      // 동작으로 다시 노출한다. 이게 없으면 스크린리더 사용자만 "왜 그렇게
      // 판단했는지"에 접근하지 못한다 — 가장 확인이 필요한 사용자가 막힌다.
      customSemanticsActions: {
        if (widget.onToneTap != null && emphasis.showLabel)
          const CustomSemanticsAction(label: '말투 판단 근거 보기'):
              widget.onToneTap!,
      },
      child: FadeTransition(
        opacity: _entrance,
        child: GestureDetector(
          onLongPress: widget.onLongPress,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SpeakerBar(
                  color: speakerColor,
                  isPending: caption.isAwaitingSpeaker,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _CaptionHeader(
                        caption: caption,
                        speakerColor: speakerColor,
                        style: style,
                        emphasis: emphasis,
                        showTimestamp: widget.showTimestamp,
                        onToneTap: widget.onToneTap,
                      ),
                      const SizedBox(height: 4),
                      AnimatedBuilder(
                        animation: _controller,
                        builder: (context, child) => _applyMotion(
                          style.motion,
                          emphasis.motionScale,
                          child!,
                        ),
                        child: AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOut,
                          style: TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: fontSize,
                            height: 1.42,
                            color: textColor,
                            fontWeight:
                                CaptionSizing.weightFor(caption.intensity),
                            // 화자 미확정 상태를 기울임으로도 표시한다.
                            fontStyle: caption.isAwaitingSpeaker
                                ? FontStyle.italic
                                : FontStyle.normal,
                          ),
                          child: Text(caption.text),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 감정에 따른 변형을 적용한다.
  Widget _applyMotion(EmotionMotion motion, double scale, Widget child) {
    if (scale <= 0) return child;
    final t = _controller.value;

    return switch (motion) {
      // 격앙 — 좌우 미세 진동
      EmotionMotion.shake => Transform.translate(
          offset: Offset(math.sin(t * math.pi * 2) * 2.4 * scale, 0),
          child: child,
        ),
      // 화남 — 강한 맥동
      EmotionMotion.pulse => Transform.scale(
          scale: 1 + t * 0.045 * scale,
          alignment: Alignment.centerLeft,
          child: child,
        ),
      // 기쁨 — 위로 통통
      EmotionMotion.bounce => Transform.translate(
          offset: Offset(0, -math.sin(t * math.pi) * 4.0 * scale),
          child: child,
        ),
      // 슬픔 — 아래로 가라앉으며 살짝 흐려짐
      EmotionMotion.sink => Transform.translate(
          offset: Offset(0, t * 3.0 * scale),
          child: Opacity(opacity: 1 - t * 0.15 * scale, child: child),
        ),
      EmotionMotion.none => child,
    };
  }

  String _semanticLabel(
    Caption caption,
    EmotionStyle style,
    EmotionEmphasis emphasis,
  ) {
    final speaker = caption.speaker?.displayLabel ?? '화자 확인 중';
    final volume = switch (caption.intensity) {
      > 0.75 => '큰 소리로',
      < 0.3 => '작은 소리로',
      _ => '',
    };
    // 스크린리더로 들을 때도 추정임이 드러나야 한다. "화남"이라고 읽어주면
    // 화면에서 하는 것보다 더 단정적으로 들린다 — 시각적 맥락이 없으니까.
    final emotion = emphasis.showLabel ? '${style.phraseFor(emphasis)},' : '';
    return '$speaker, $volume $emotion ${caption.text}'
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}

/// 화자를 나타내는 세로 색 막대.
class _SpeakerBar extends StatelessWidget {
  const _SpeakerBar({required this.color, required this.isPending});

  final Color color;
  final bool isPending;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOut,
      width: 5,
      constraints: const BoxConstraints(minHeight: 34),
      margin: const EdgeInsets.only(top: 4),
      decoration: BoxDecoration(
        // 화자 미확정이면 흐리게 — 확정되면 색이 또렷해지면서 눈에 띈다.
        color: isPending ? color.withValues(alpha: 0.35) : color,
        borderRadius: BorderRadius.circular(3),
      ),
    );
  }
}

/// 말투 배지.
///
/// 이 배지는 **누르면 근거가 나온다.** 자막 옆에 "화난 말투로 들림"이 떠 있는데
/// 무엇을 보고 그렇게 판단했는지 알 방법이 없으면, 사용자는 믿거나 무시하거나
/// 둘 중 하나밖에 못 한다. 소리를 못 듣는 사용자는 이 판정을 직접 검증할 수도
/// 없으므로 더 그렇다.
class _ToneBadge extends StatelessWidget {
  const _ToneBadge({
    required this.style,
    required this.emphasis,
    required this.color,
    this.onTap,
  });

  final EmotionStyle style;
  final EmotionEmphasis emphasis;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tentative = emphasis.isTentative;

    return Semantics(
      button: onTap != null,
      label: onTap == null
          ? null
          : '${style.phraseFor(emphasis)}. 어떻게 판단했는지 보기',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          // 최소 터치 목표를 채운다. 배지 글씨가 작아 그냥 두면 누를 수 없다.
          constraints: const BoxConstraints(minHeight: 30),
          decoration: BoxDecoration(
            // 근거가 약한 판정은 **채우지 않는다.** 확신의 정도가 색 진하기에만
            // 걸려 있으면 흑백·색각이상·저시력에서 통째로 사라진다.
            color: tentative ? null : color.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: color.withValues(alpha: tentative ? 0.4 : 0.5),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(style.icon, size: 14, color: color),
              const SizedBox(width: 4),
              Text(
                style.phraseFor(emphasis),
                style: TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 12.5,
                  // 확신이 약하면 글자 무게도 낮춘다.
                  fontWeight: tentative ? FontWeight.w500 : FontWeight.w700,
                  color: color,
                ),
              ),
              if (onTap != null) ...[
                const SizedBox(width: 3),
                Icon(
                  Icons.help_outline_rounded,
                  size: 13,
                  color: color.withValues(alpha: 0.75),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 화자 이름 + 감정 배지 + 시각.
class _CaptionHeader extends StatelessWidget {
  const _CaptionHeader({
    required this.caption,
    required this.speakerColor,
    required this.style,
    required this.emphasis,
    required this.showTimestamp,
    this.onToneTap,
  });

  final Caption caption;
  final Color speakerColor;
  final EmotionStyle style;
  final EmotionEmphasis emphasis;
  final bool showTimestamp;
  final VoidCallback? onToneTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final emotionColor = style.colorOf(theme.brightness);

    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 4,
      children: [
        Text(
          caption.speaker?.displayLabel ?? '화자 확인 중…',
          style: theme.textTheme.labelLarge?.copyWith(
            color: caption.isAwaitingSpeaker
                ? theme.colorScheme.onSurfaceVariant
                : speakerColor,
            fontWeight: FontWeight.w700,
            fontSize: 14,
          ),
        ),
        if (emphasis.showLabel)
          _ToneBadge(
            style: style,
            emphasis: emphasis,
            color: emotionColor,
            onTap: onToneTap,
          ),
        // 아주 크게 말한 경우 별도 표시. 글자 크기 변화만으로는 "얼마나 큰지"
        // 절대적인 감이 안 온다.
        if (caption.intensity > 0.8)
          Icon(
            Icons.volume_up_rounded,
            size: 15,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        if (showTimestamp)
          Text(
            _formatOffset(caption.offset),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
      ],
    );
  }
}

String _formatOffset(Duration offset) {
  final minutes = offset.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = offset.inSeconds.remainder(60).toString().padLeft(2, '0');
  if (offset.inHours > 0) {
    return '${offset.inHours}:$minutes:$seconds';
  }
  return '$minutes:$seconds';
}
