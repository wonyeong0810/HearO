import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/providers.dart';
import '../../data/audio/alarm_detector.dart';
import 'alert_service.dart';

/// 위급 상황 전체화면 경고 (기획 2-1).
///
/// 설계 원칙
/// ─────────
/// 이 화면은 사용자가 **무엇을 보고 있든 상관없이** 눈에 들어와야 한다.
///  - 전체화면을 덮는다. 스낵바나 배너로는 놓친다.
///  - 고대비로 깜빡인다. 주변시(peripheral vision)는 색보다 밝기 변화에
///    훨씬 민감하다 — 화면을 정면으로 안 보고 있어도 알아챈다.
///  - 아이콘·문구·행동지침을 함께 준다. "무슨 소리인지" 만큼 "어떻게 해야
///    하는지"가 중요하다.
///  - 실수로 닫히지 않게 한다. 뒤로가기와 화면 탭으로는 안 닫히고, 명시적으로
///    큰 버튼을 눌러야 닫힌다.
class AlertOverlay extends ConsumerStatefulWidget {
  const AlertOverlay({required this.detection, super.key});

  final AlarmDetection detection;

  @override
  ConsumerState<AlertOverlay> createState() => _AlertOverlayState();
}

class _AlertOverlayState extends ConsumerState<AlertOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _flash;

  @override
  void initState() {
    super.initState();

    _flash = AnimationController(
      vsync: this,
      // 광과민성 발작 위험 때문에 초당 3Hz 를 넘기지 않는다.
      // (WCAG 2.3.1: 초당 3회 이하)
      duration: const Duration(milliseconds: 340),
    );

    if (_shouldFlash) {
      _flash.repeat(reverse: true);
    }

    // 경고가 뜨는 동안 화면이 꺼지면 안 된다. 사용자가 알아챌 방법이 사라진다.
    //
    // 실패는 삼킨다. wakelock 을 못 잡는 기기·플랫폼이 있는데, 그것 때문에
    // 경고 화면 자체가 죽으면 훨씬 나쁜 결과가 된다.
    unawaited(WakelockPlus.enable().catchError((Object _) {}));
  }

  bool get _shouldFlash {
    final settings = ref.read(alertServiceProvider).settings;
    final reduceMotion = ref.read(reduceMotionProvider);
    // "동작 줄이기"를 켠 사용자에게는 깜빡임을 쓰지 않는다.
    return (settings?.alertFlashEnabled ?? true) && !reduceMotion;
  }

  @override
  void dispose() {
    _flash.dispose();
    // 라이브 자막 화면이 켜 둔 wakelock 을 여기서 꺼버리면 안 되므로,
    // 경고가 닫힐 때는 해제하지 않는다. 자막 화면이 자기 수명주기에서 정리한다.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final detection = widget.detection;
    final type = detection.type;
    final isCritical = type.severity >= 3;

    // 심각도별 색. 빨강(즉시 대피) / 주황(주의).
    final baseColor =
        isCritical ? const Color(0xFFB3161F) : const Color(0xFF9A4B00);
    final flashColor =
        isCritical ? const Color(0xFFFF3B30) : const Color(0xFFFF9500);

    return PopScope(
      // 뒤로가기로 닫히면 안 된다. 사용자가 명시적으로 확인해야 한다.
      canPop: false,
      child: AnimatedBuilder(
        animation: _flash,
        builder: (context, child) {
          final background = _shouldFlash
              ? Color.lerp(baseColor, flashColor, _flash.value)!
              : baseColor;
          return Material(
            color: background,
            child: child,
          );
        },
        child: SafeArea(
          child: Semantics(
            liveRegion: true,
            label: '위급 상황. ${type.labelKo} 감지. ${type.guidance}',
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Spacer(),
                  _PulsingIcon(
                    icon: _iconFor(detection),
                    animate: _shouldFlash,
                    controller: _flash,
                  ),
                  const SizedBox(height: 28),
                  const Text(
                    '위급 상황',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: Colors.white70,
                      letterSpacing: 2,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    type.labelKo,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 46,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      height: 1.15,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.28),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      type.guidance,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 19,
                        height: 1.5,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '감지 신뢰도 ${(detection.confidence * 100).round()}%'
                    ' · ${_formatTime(detection.detectedAt)}',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 14,
                      color: Colors.white.withValues(alpha: 0.75),
                    ),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () =>
                        ref.read(alertServiceProvider.notifier).acknowledge(),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: baseColor,
                      minimumSize: const Size.fromHeight(64),
                      textStyle: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    child: const Text('확인했습니다'),
                  ),
                  // "잘못된 감지였어요"는 테스트에 뜨지 않는다 — 사용자가 직접
                  // 띄운 화면이라 오탐일 수가 없고, 눌러 봐야 서버에 올릴
                  // 기록도 없다.
                  if (!detection.isTest) ...[
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: () => ref
                          .read(alertServiceProvider.notifier)
                          .acknowledge(falsePositive: true),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white.withValues(alpha: 0.9),
                        minimumSize: const Size.fromHeight(52),
                      ),
                      child: const Text(
                        '잘못된 감지였어요',
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  IconData _iconFor(AlarmDetection detection) => switch (detection.type.name) {
        'fireAlarm' => Icons.local_fire_department_rounded,
        'smokeDetector' => Icons.cloud_rounded,
        'civilDefenseSiren' => Icons.campaign_rounded,
        'emergencyVehicle' => Icons.emergency_rounded,
        _ => Icons.warning_amber_rounded,
      };

  String _formatTime(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}:'
      '${time.second.toString().padLeft(2, '0')}';
}

class _PulsingIcon extends StatelessWidget {
  const _PulsingIcon({
    required this.icon,
    required this.animate,
    required this.controller,
  });

  final IconData icon;
  final bool animate;
  final AnimationController controller;

  @override
  Widget build(BuildContext context) {
    final iconWidget = Container(
      padding: const EdgeInsets.all(26),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withValues(alpha: 0.18),
        border: Border.all(color: Colors.white, width: 3),
      ),
      child: Icon(icon, size: 76, color: Colors.white),
    );

    if (!animate) return Center(child: iconWidget);

    return Center(
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, child) => Transform.scale(
          scale: 1 + controller.value * 0.08,
          child: child,
        ),
        child: iconWidget,
      ),
    );
  }
}

/// 앱 어디서든 경보가 뜨면 전체화면으로 덮는 래퍼.
///
/// 라우터 바깥에 두어야 어느 화면에 있든 동작한다.
class AlertHost extends ConsumerWidget {
  const AlertHost({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(alertServiceProvider.select((s) => s.active));

    return Stack(
      children: [
        child,
        if (active != null)
          Positioned.fill(
            child: AlertOverlay(
              detection: active,
              // 새 경보가 오면 위젯을 새로 만들어 애니메이션을 다시 시작한다.
              key: ValueKey(active.detectedAt),
            ),
          ),
      ],
    );
  }
}
