import 'package:flutter/material.dart';

/// 보관 기간 선택 시트.
///
/// 시트 안의 내용은 반드시 스크롤 가능해야 한다. 이 앱의 사용자 중에는 저시력
/// 사용자가 있고, 시스템 글자 크기를 크게 올려 쓰는 것이 정상 사용이다. 높이를
/// 늘려 두는 것만으로는 부족하다 — 글자 배율을 조금만 더 올리면 다시 넘친다.
class RetentionSheet extends StatelessWidget {
  const RetentionSheet({required this.selectedDays, super.key});

  /// 지금 선택된 보관 일수. 0 은 무기한.
  final int selectedDays;

  /// 값 → 표시 문구. 0 은 "삭제 안 함"이라는 뜻을 문구에 드러낸다 —
  /// 숫자만 보고 "0일 보관"으로 오해하면 정반대의 결과가 된다.
  static const options = <int, String>{
    7: '7일',
    30: '30일',
    90: '90일',
    180: '6개월',
    365: '1년',
    0: '무기한 (삭제 안 함)',
  };

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        // 화면을 통째로 덮으면 시트가 아니라 새 화면처럼 보인다.
        // 여기까지만 늘어나고 그 뒤로는 스크롤한다.
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(20),
                child: Text(
                  '보관 기간',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
              ),
              // Flutter 3.32 부터 groupValue/onChanged 는 RadioGroup 으로 대체됐다.
              RadioGroup<int>(
                groupValue: selectedDays,
                onChanged: (value) => Navigator.pop(context, value),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final entry in options.entries)
                      RadioListTile<int>(
                        value: entry.key,
                        title: Text(entry.value),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}
