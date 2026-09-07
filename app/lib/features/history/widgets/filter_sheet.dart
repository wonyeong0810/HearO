import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/emotion_style.dart';
import '../../../domain/entities/emotion_tone.dart';
import '../history_controller.dart';

/// 기록 필터 시트 — 날짜 / 위치 / 화자 / 즐겨찾기 / 감정 (기획 3-2).
class FilterSheet extends StatefulWidget {
  const FilterSheet({required this.initial, super.key});

  final HistoryFilter initial;

  @override
  State<FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<FilterSheet> {
  late HistoryFilter _draft;
  late final TextEditingController _locationController;
  late final TextEditingController _speakerController;

  @override
  void initState() {
    super.initState();
    _draft = widget.initial;
    _locationController = TextEditingController(text: _draft.location ?? '');
    _speakerController = TextEditingController(text: _draft.speakerName ?? '');
  }

  @override
  void dispose() {
    _locationController.dispose();
    _speakerController.dispose();
    super.dispose();
  }

  Future<void> _pickDateRange() async {
    final now = DateTime.now();
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 5),
      lastDate: now,
      initialDateRange: _draft.dateFrom != null && _draft.dateTo != null
          ? DateTimeRange(start: _draft.dateFrom!, end: _draft.dateTo!)
          : null,
      locale: const Locale('ko'),
      helpText: '기간 선택',
      saveText: '적용',
    );

    if (range != null) {
      setState(() {
        _draft = _draft.copyWith(
          dateFrom: DateTime(
            range.start.year,
            range.start.month,
            range.start.day,
          ),
          // 종료일은 그날 끝까지 포함해야 한다. 안 그러면 오늘 대화가 안 나온다.
          dateTo: DateTime(
            range.end.year,
            range.end.month,
            range.end.day,
            23,
            59,
            59,
          ),
        );
      });
    }
  }

  void _apply() {
    Navigator.of(context).pop(
      _draft.copyWith(
        location: _locationController.text.trim(),
        clearLocation: _locationController.text.trim().isEmpty,
        speakerName: _speakerController.text.trim(),
        clearSpeakerName: _speakerController.text.trim().isEmpty,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final format = DateFormat('yyyy년 M월 d일');

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('필터', style: theme.textTheme.titleLarge),
                  const Spacer(),
                  TextButton(
                    onPressed: () {
                      _locationController.clear();
                      _speakerController.clear();
                      setState(() {
                        _draft = HistoryFilter(query: widget.initial.query);
                      });
                    },
                    child: const Text('초기화'),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // ---- 즐겨찾기 ----
              SwitchListTile(
                value: _draft.favoritesOnly,
                onChanged: (value) =>
                    setState(() => _draft = _draft.copyWith(favoritesOnly: value)),
                title: const Text('즐겨찾기한 대화만'),
                secondary: const Icon(Icons.star_rounded),
                contentPadding: EdgeInsets.zero,
              ),
              const Divider(),

              // ---- 기간 ----
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text('기간', style: theme.textTheme.titleMedium),
              ),
              OutlinedButton.icon(
                onPressed: _pickDateRange,
                icon: const Icon(Icons.calendar_month_rounded),
                label: Text(
                  _draft.dateFrom == null || _draft.dateTo == null
                      ? '전체 기간'
                      : '${format.format(_draft.dateFrom!)} ~ '
                          '${format.format(_draft.dateTo!)}',
                ),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  alignment: Alignment.centerLeft,
                ),
              ),
              if (_draft.dateFrom != null)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => setState(() {
                      _draft = _draft.copyWith(
                        clearDateFrom: true,
                        clearDateTo: true,
                      );
                    }),
                    child: const Text('기간 해제'),
                  ),
                ),
              const SizedBox(height: 8),

              // ---- 위치 ----
              TextField(
                controller: _locationController,
                decoration: const InputDecoration(
                  labelText: '위치',
                  hintText: '예: 병원, 학교',
                  prefixIcon: Icon(Icons.place_outlined),
                ),
              ),
              const SizedBox(height: 12),

              // ---- 화자 ----
              TextField(
                controller: _speakerController,
                decoration: const InputDecoration(
                  labelText: '화자 이름',
                  hintText: '예: 엄마, 김 선생님',
                  prefixIcon: Icon(Icons.person_outline_rounded),
                ),
              ),
              const SizedBox(height: 20),

              // ---- 말투 ----
              Text('주로 들린 말투', style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              // 목록·통계에는 줄마다 근거를 붙일 자리가 없다. 대신 묶어 보여주는
              // 자리에서 한 번 명시한다 — 이 값들은 측정이 아니라 추정이다.
              Text(
                '목소리와 문장으로 짐작한 값입니다.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final tone in EmotionTone.values)
                    if (tone != EmotionTone.neutral)
                      _ToneChip(
                        tone: tone,
                        selected: _draft.tone == tone,
                        onTap: () => setState(() {
                          _draft = _draft.tone == tone
                              ? _draft.copyWith(clearTone: true)
                              : _draft.copyWith(tone: tone);
                        }),
                      ),
                ],
              ),
              const SizedBox(height: 24),

              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _apply,
                  child: const Text('적용'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToneChip extends StatelessWidget {
  const _ToneChip({
    required this.tone,
    required this.selected,
    required this.onTap,
  });

  final EmotionTone tone;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final style = EmotionStyle.of(tone);
    final color = style.colorOf(Theme.of(context).brightness);

    return FilterChip(
      selected: selected,
      onSelected: (_) => onTap(),
      avatar: Icon(style.icon, size: 18, color: color),
      label: Text(tone.labelKo),
      selectedColor: color.withValues(alpha: 0.2),
      checkmarkColor: color,
    );
  }
}
