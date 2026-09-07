import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../domain/entities/conversation.dart';
import '../alert/alert_service.dart';
import '../alert/alert_test_sheet.dart';
import 'widgets/retention_sheet.dart';

/// 설정 화면.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(settingsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('설정')),
      body: settingsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('설정을 불러오지 못했습니다\n$error', textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => ref.read(settingsProvider.notifier).load(),
                  child: const Text('다시 시도'),
                ),
              ],
            ),
          ),
        ),
        data: (settings) => _SettingsBody(settings: settings),
      ),
    );
  }
}

class _SettingsBody extends ConsumerWidget {
  const _SettingsBody({required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(settingsProvider.notifier);
    final alertState = ref.watch(alertServiceProvider);

    Future<void> save(
      AppSettings Function(AppSettings) mutate,
      Map<String, dynamic> payload,
    ) async {
      try {
        await notifier.update(mutate, payload);
      } on Object catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('설정 저장 실패: $error')));
        }
      }
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 40),
      children: [
        // ============================================================ 자막
        const _SectionHeader('자막 표시'),

        _CaptionPreview(settings: settings),

        ListTile(
          title: const Text('자막 크기'),
          subtitle: Text('${(settings.captionTextScale * 100).round()}%'),
          contentPadding: const EdgeInsets.symmetric(horizontal: 20),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Slider(
            value: settings.captionTextScale,
            min: 0.7,
            max: 2.2,
            divisions: 15,
            label: '${(settings.captionTextScale * 100).round()}%',
            onChanged: (value) => save(
              (s) => s.copyWith(captionTextScale: value),
              {'caption_text_scale': value},
            ),
          ),
        ),

        SwitchListTile(
          value: settings.loudnessScalingEnabled,
          onChanged: (value) => save(
            (s) => s.copyWith(loudnessScalingEnabled: value),
            {'loudness_scaling_enabled': value},
          ),
          title: const Text('말의 크기를 글자 크기로'),
          subtitle: const Text('크게 말하면 자막도 커집니다.'),
          secondary: const Icon(Icons.format_size_rounded),
        ),

        SwitchListTile(
          value: settings.emotionAnimationEnabled,
          onChanged: (value) => save(
            (s) => s.copyWith(emotionAnimationEnabled: value),
            {'emotion_animation_enabled': value},
          ),
          title: const Text('말투 애니메이션'),
          subtitle: const Text('말투에 따라 자막이 흔들리거나 튑니다.'),
          secondary: const Icon(Icons.animation_rounded),
        ),

        SwitchListTile(
          value: settings.highContrastMode,
          onChanged: (value) => save(
            (s) => s.copyWith(highContrastMode: value),
            {'high_contrast_mode': value},
          ),
          title: const Text('고대비 모드'),
          subtitle: const Text('배경과 글자의 대비를 최대로 높입니다.'),
          secondary: const Icon(Icons.contrast_rounded),
        ),

        // ============================================================ 경보
        const _SectionHeader('위급 상황 알림'),

        if (alertState.errorMessage != null)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    alertState.errorMessage!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onErrorContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),

        SwitchListTile(
          value: settings.alertsEnabled,
          onChanged: (value) async {
            await save(
              (s) => s.copyWith(alertsEnabled: value),
              {'alerts_enabled': value},
            );
            final service = ref.read(alertServiceProvider.notifier);
            if (value) {
              await service.startMonitoring(settings: settings);
            } else {
              await service.stopMonitoring();
            }
          },
          title: const Text('경보음 감지'),
          subtitle: Text(
            alertState.monitoring
                ? '화재경보·사이렌을 감지하는 중입니다.'
                : '화재경보기, 사이렌 등을 감지해 알려 줍니다.',
          ),
          secondary: Icon(
            alertState.monitoring
                ? Icons.notifications_active_rounded
                : Icons.notifications_off_outlined,
          ),
        ),

        SwitchListTile(
          value: settings.alertVibrationEnabled,
          onChanged: settings.alertsEnabled
              ? (value) => save(
                    (s) => s.copyWith(alertVibrationEnabled: value),
                    {'alert_vibration_enabled': value},
                  )
              : null,
          title: const Text('진동으로 알림'),
          subtitle: const Text('경보 종류에 따라 다른 진동 패턴을 사용합니다.'),
          secondary: const Icon(Icons.vibration_rounded),
        ),

        SwitchListTile(
          value: settings.alertFlashEnabled,
          onChanged: settings.alertsEnabled
              ? (value) => save(
                    (s) => s.copyWith(alertFlashEnabled: value),
                    {'alert_flash_enabled': value},
                  )
              : null,
          title: const Text('화면 깜빡임'),
          subtitle: const Text('경고 화면이 고대비로 깜빡입니다.'),
          secondary: const Icon(Icons.flash_on_rounded),
        ),

        SwitchListTile(
          value: settings.alertTorchStrobeEnabled,
          onChanged: settings.alertsEnabled
              ? (value) => save(
                    (s) => s.copyWith(alertTorchStrobeEnabled: value),
                    {'alert_torch_strobe_enabled': value},
                  )
              : null,
          title: const Text('손전등 점멸'),
          subtitle: const Text('화면을 보고 있지 않아도 알아챌 수 있습니다. 배터리를 더 씁니다.'),
          secondary: const Icon(Icons.flashlight_on_rounded),
        ),

        ListTile(
          title: const Text('감지 민감도'),
          subtitle: Text(_sensitivityLabel(settings.alertSensitivity)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 20),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Slider(
            value: settings.alertSensitivity,
            min: 0.2,
            max: 0.9,
            divisions: 14,
            label: _sensitivityLabel(settings.alertSensitivity),
            onChanged: settings.alertsEnabled
                ? (value) {
                    ref
                        .read(alertServiceProvider.notifier)
                        .updateSensitivity(value);
                    save(
                      (s) => s.copyWith(alertSensitivity: value),
                      {'alert_sensitivity': value},
                    );
                  }
                : null,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Text(
            '민감하게 설정하면 경보를 놓칠 확률이 줄지만, 관계없는 소리에도 '
            '알림이 뜰 수 있습니다.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ),

        // 감지를 꺼 둔 사용자도 누를 수 있게 둔다 — 켜기 전에 이 기기에서
        // 진동·손전등이 실제로 동작하는지 보고 결정할 수 있어야 한다.
        ListTile(
          leading: const Icon(Icons.play_circle_outline_rounded),
          title: const Text('알림 테스트'),
          subtitle: const Text('진동·화면·손전등이 이 기기에서 동작하는지 직접 확인합니다.'),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => showAlertTestSheet(context),
        ),

        ListTile(
          leading: const Icon(Icons.history_rounded),
          title: const Text('경보 기록 보기'),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => context.push('/alerts'),
        ),

        // ============================================================ 기록
        const _SectionHeader('대화 기록 · 개인정보'),

        SwitchListTile(
          value: settings.locationTaggingEnabled,
          onChanged: (value) => save(
            (s) => s.copyWith(locationTaggingEnabled: value),
            {'location_tagging_enabled': value},
          ),
          title: const Text('위치 기록'),
          subtitle: const Text('대화가 어디에서 있었는지 함께 저장합니다.'),
          secondary: const Icon(Icons.place_outlined),
        ),

        SwitchListTile(
          value: settings.autoDeleteEnabled,
          onChanged: (value) => save(
            (s) => s.copyWith(autoDeleteEnabled: value),
            {'auto_delete_enabled': value},
          ),
          title: const Text('오래된 기록 자동 삭제'),
          subtitle: const Text('즐겨찾기한 대화는 삭제되지 않습니다.'),
          secondary: const Icon(Icons.auto_delete_outlined),
        ),

        if (settings.autoDeleteEnabled)
          ListTile(
            leading: const Icon(Icons.calendar_month_outlined),
            title: const Text('보관 기간'),
            subtitle: Text(
              settings.logRetentionDays == 0
                  ? '무기한 보관'
                  : '${settings.logRetentionDays}일',
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => _pickRetention(context, settings, save),
          ),

        ListTile(
          leading: const Icon(Icons.delete_sweep_outlined),
          title: const Text('지금 오래된 기록 삭제'),
          subtitle: const Text('보관 기간이 지난 대화를 즉시 삭제합니다.'),
          onTap: () => _purgeNow(context, ref),
        ),

        // ============================================================ 계정
        const _SectionHeader('계정'),

        ListTile(
          leading: const Icon(Icons.insights_outlined),
          title: const Text('사용 통계'),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => context.push('/stats'),
        ),

        ListTile(
          leading: const Icon(Icons.logout_rounded),
          title: const Text('로그아웃'),
          onTap: () async {
            final confirmed = await _confirm(
              context,
              title: '로그아웃할까요?',
              body: '저장된 대화 기록은 서버에 그대로 남아 있습니다.',
              confirmLabel: '로그아웃',
            );
            if (confirmed && context.mounted) {
              await ref.read(authStateProvider.notifier).logout();
            }
          },
        ),

        ListTile(
          leading: Icon(
            Icons.person_remove_outlined,
            color: Theme.of(context).colorScheme.error,
          ),
          title: Text(
            '계정 삭제',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          subtitle: const Text('모든 대화 기록이 즉시 삭제되며 되돌릴 수 없습니다.'),
          onTap: () => _deleteAccount(context, ref),
        ),

        const SizedBox(height: 24),
        Center(
          child: Text(
            'HearO 1.0.0',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ),
      ],
    );
  }

  String _sensitivityLabel(double value) {
    if (value <= 0.35) return '매우 민감';
    if (value <= 0.5) return '민감';
    if (value <= 0.65) return '보통';
    if (value <= 0.8) return '둔감';
    return '매우 둔감';
  }

  Future<void> _pickRetention(
    BuildContext context,
    AppSettings settings,
    Future<void> Function(
      AppSettings Function(AppSettings),
      Map<String, dynamic>,
    ) save,
  ) async {
    final selected = await showModalBottomSheet<int>(
      context: context,
      // 없으면 시트 높이가 화면의 9/16 로 묶여 항목이 잘린다.
      isScrollControlled: true,
      builder: (context) =>
          RetentionSheet(selectedDays: settings.logRetentionDays),
    );

    if (selected != null) {
      await save(
        (s) => s.copyWith(logRetentionDays: selected),
        {'log_retention_days': selected},
      );
    }
  }

  Future<void> _purgeNow(BuildContext context, WidgetRef ref) async {
    final confirmed = await _confirm(
      context,
      title: '오래된 기록을 삭제할까요?',
      body: '보관 기간이 지난 대화가 삭제됩니다. 즐겨찾기한 대화는 남습니다.',
      confirmLabel: '삭제',
      destructive: true,
    );
    if (!confirmed) return;

    try {
      final message = await ref.read(apiClientProvider).purgeLogs();
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      }
    } on Object catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('삭제 실패: $error')));
      }
    }
  }

  Future<void> _deleteAccount(BuildContext context, WidgetRef ref) async {
    // 비밀번호는 대화상자가 **닫히면서 값으로 돌려준다.** 바깥에서 컨트롤러를
    // 만들어 두고 닫힌 뒤에 읽으면, 그 컨트롤러를 언제 버려야 하는지가
    // 애매해진다 (`_RenameDialog` 주석 참고).
    final password = await showDialog<String>(
      context: context,
      builder: (_) => const _DeleteAccountDialog(),
    );

    if (password == null || password.isEmpty) return;

    try {
      await ref.read(apiClientProvider).deleteAccount(password);
      ref.read(authStateProvider.notifier).markUnauthenticated();
    } on Object catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }
}

/// 계정 삭제 확인 대화상자. 확인을 누르면 입력한 비밀번호를 돌려준다.
class _DeleteAccountDialog extends StatefulWidget {
  const _DeleteAccountDialog();

  @override
  State<_DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<_DeleteAccountDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('계정을 삭제할까요?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '모든 대화 기록과 경보 기록이 즉시 삭제됩니다. '
            '되돌릴 수 없습니다.\n\n확인을 위해 비밀번호를 입력해 주세요.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            obscureText: true,
            autofocus: true,
            decoration: const InputDecoration(labelText: '비밀번호'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('계정 삭제'),
        ),
      ],
    );
  }
}

Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
  bool destructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('취소'),
        ),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                )
              : null,
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 8),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// 설정 변경 결과를 바로 보여주는 미리보기.
/// 슬라이더를 움직이며 실제 자막이 어떻게 보일지 확인할 수 있어야 한다.
class _CaptionPreview extends StatelessWidget {
  const _CaptionPreview({required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '미리보기',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          for (final sample in const [
            (0.35, '#2563EB', '화자 A', '조용히 말할 때'),
            (0.85, '#059669', '화자 B', '크게 말할 때'),
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 5,
                    height: 32,
                    decoration: BoxDecoration(
                      color: Color(
                        0xFF000000 |
                            int.parse(sample.$2.substring(1), radix: 16),
                      ),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      sample.$4,
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: CaptionSizing.resolve(
                          intensity: sample.$1,
                          userScale: settings.captionTextScale,
                          loudnessScaling: settings.loudnessScalingEnabled,
                        ),
                        fontWeight: CaptionSizing.weightFor(sample.$1),
                        color: theme.colorScheme.onSurface,
                      ),
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
