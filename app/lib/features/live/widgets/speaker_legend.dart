import 'package:flutter/material.dart';

import '../../../domain/entities/caption.dart';

/// 화자 색상 범례 (기획 1-2).
///
/// 화면 상단에 지금까지 등장한 화자를 색과 이름으로 보여준다. 자막만으로는
/// "파란색이 누구였지?" 를 계속 되짚어야 하는데, 범례가 있으면 한 번에 확인된다.
/// 탭하면 이름과 색을 바꿀 수 있다 — 기획의 "유저가 직접 색상 지정".
class SpeakerLegend extends StatelessWidget {
  const SpeakerLegend({
    required this.speakers,
    required this.onRename,
    required this.onRecolor,
    super.key,
  });

  final List<Speaker> speakers;
  final void Function(String key, String name) onRename;
  final void Function(String key, String colorHex) onRecolor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      height: 60,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border:
            Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        itemCount: speakers.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final speaker = speakers[index];
          return _SpeakerChip(
            speaker: speaker,
            onTap: () => _openEditor(context, speaker),
          );
        },
      ),
    );
  }

  Future<void> _openEditor(BuildContext context, Speaker speaker) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _SpeakerEditorSheet(
        speaker: speaker,
        onRename: (name) => onRename(speaker.key, name),
        onRecolor: (color) => onRecolor(speaker.key, color),
      ),
    );
  }
}

class _SpeakerChip extends StatelessWidget {
  const _SpeakerChip({required this.speaker, required this.onTap});

  final Speaker speaker;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Semantics(
      button: true,
      label: '${speaker.displayLabel}, 이름과 색상 변경',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: speaker.color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: speaker.color, width: 1.5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: speaker.color,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                speaker.displayLabel,
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.edit_rounded,
                size: 14,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SpeakerEditorSheet extends StatefulWidget {
  const _SpeakerEditorSheet({
    required this.speaker,
    required this.onRename,
    required this.onRecolor,
  });

  final Speaker speaker;
  final void Function(String name) onRename;
  final void Function(String colorHex) onRecolor;

  @override
  State<_SpeakerEditorSheet> createState() => _SpeakerEditorSheetState();
}

class _SpeakerEditorSheetState extends State<_SpeakerEditorSheet> {
  late final TextEditingController _nameController;
  late String _selectedColor;

  /// 화자 구분용 팔레트. 백엔드 SPEAKER_PALETTE 와 같은 색을 쓴다.
  /// 색각이상에서도 서로 구분되도록 명도까지 벌려 두었다.
  static const _palette = <String>[
    '#2563EB', // 파랑
    '#059669', // 초록
    '#7C3AED', // 보라
    '#EA580C', // 주황
    '#0891B2', // 청록
    '#DB2777', // 자홍
    '#CA8A04', // 황토
    '#4F46E5', // 남색
  ];

  @override
  void initState() {
    super.initState();
    _nameController =
        TextEditingController(text: widget.speaker.displayName ?? '');
    _selectedColor = widget.speaker.colorHex.toUpperCase();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _save() {
    final name = _nameController.text.trim();
    if (name.isNotEmpty && name != widget.speaker.displayName) {
      widget.onRename(name);
    }
    if (_selectedColor.toUpperCase() !=
        widget.speaker.colorHex.toUpperCase()) {
      widget.onRecolor(_selectedColor);
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // 키보드가 올라오면 시트에 남는 높이가 확 줄어든다. 스크롤이 없으면 그
    // 순간 내용이 넘치고, 하필 맨 아래의 **취소·저장 버튼이 잘린다** — 이름을
    // 다 입력해 놓고 저장을 못 누르는 상태가 된다.
    //
    // 이름 입력이 autofocus 라 이 시트는 열리자마자 항상 그 상황이 된다.
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.9,
        ),
        child: SingleChildScrollView(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.viewInsetsOf(context).bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '화자 ${widget.speaker.label}',
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: 4),
              Text(
                '이 화자를 알아보기 쉽게 이름과 색을 바꿀 수 있습니다.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _nameController,
                autofocus: true,
                maxLength: 30,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _save(),
                decoration: const InputDecoration(
                  labelText: '이름',
                  hintText: '예: 엄마, 김 선생님, 카페 직원',
                  counterText: '',
                ),
              ),
              const SizedBox(height: 20),
              Text('색상', style: theme.textTheme.titleMedium),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final hex in _palette)
                    _ColorSwatch(
                      hex: hex,
                      selected: _selectedColor.toUpperCase() == hex,
                      onTap: () => setState(() => _selectedColor = hex),
                    ),
                ],
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('취소'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _save,
                      child: const Text('저장'),
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
}

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({
    required this.hex,
    required this.selected,
    required this.onTap,
  });

  final String hex;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = Color(0xFF000000 | int.parse(hex.substring(1), radix: 16));

    return Semantics(
      button: true,
      selected: selected,
      label: '색상 $hex',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(28),
        // 터치 목표 최소 48dp
        child: Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected
                  ? Theme.of(context).colorScheme.onSurface
                  : Colors.transparent,
              width: 3,
            ),
          ),
          // 선택 표시를 테두리만이 아니라 체크 아이콘으로도 준다.
          child: selected
              ? const Icon(Icons.check_rounded, color: Colors.white, size: 26)
              : null,
        ),
      ),
    );
  }
}
