import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// HearO 테마.
///
/// 접근성 원칙 — 이 앱의 사용자는 화면이 유일한 정보 통로다.
///  1. 본문 대비는 WCAG AAA(7:1) 를 목표로 한다. AA(4.5:1) 는 최저선.
///  2. 정보를 색으로만 전달하지 않는다. 화자는 색 + 이름표, 감정은 색 + 아이콘 + 모션.
///  3. 시스템 글꼴 확대 설정을 존중하되, 자막은 별도 배율을 하나 더 가진다.
///  4. 경고는 화면 어디를 보고 있어도 눈에 들어와야 한다 (전체화면 + 고대비 점멸).
class AppTheme {
  const AppTheme._();

  // ---------------------------------------------------------------- 색상

  /// 브랜드 색. 파랑 계열은 화자 색상으로도 쓰이므로 청록 쪽으로 비켜 두었다.
  static const Color _seed = Color(0xFF00629B);

  /// 경보 색. 순수 빨강(#FF0000)은 어두운 배경에서 번져 보여 가독성이 떨어진다.
  static const Color alertRed = Color(0xFFD32029);
  static const Color alertAmber = Color(0xFFB25E02);

  /// 화자 미확정 자막의 색. 확정 전임을 나타내되 읽을 수는 있어야 한다.
  static const Color pendingLight = Color(0xFF5F6368);
  static const Color pendingDark = Color(0xFFB0B4BA);

  // ---------------------------------------------------------------- 테마

  static ThemeData light({bool highContrast = false}) =>
      _build(Brightness.light, highContrast);

  static ThemeData dark({bool highContrast = false}) =>
      _build(Brightness.dark, highContrast);

  static ThemeData _build(Brightness brightness, bool highContrast) {
    final isDark = brightness == Brightness.dark;

    final scheme = highContrast
        ? _highContrastScheme(brightness)
        : ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);

    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      fontFamily: 'Pretendard',
      scaffoldBackgroundColor: scheme.surface,
      splashFactory: InkSparkle.splashFactory,
    );

    return base.copyWith(
      textTheme: _textTheme(base.textTheme, scheme),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 1,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontFamily: 'Pretendard',
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: scheme.onSurface,
        ),
        systemOverlayStyle:
            isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      ),
      // NOTE: cardTheme 은 여기서 설정하지 않는다. Flutter 가 `CardTheme` →
      // `CardThemeData` 로 타입을 바꾸는 중이라 버전에 따라 컴파일이 깨진다.
      // 카드 외형은 M3 기본값을 쓰고, 고대비 모드의 테두리는 outline 색을
      // 통해 자연히 반영된다.
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          // 터치 목표 최소 48dp (Material 접근성 가이드라인).
          minimumSize: const Size(64, 52),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          textStyle: const TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 52),
          side: BorderSide(color: scheme.outline, width: highContrast ? 2 : 1.5),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(
            color: scheme.outline,
            width: highContrast ? 2 : 1,
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.primary, width: 2.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.error, width: 2),
        ),
      ),
      chipTheme: ChipThemeData(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
        side: highContrast ? BorderSide(color: scheme.outline, width: 1.5) : null,
      ),
      listTileTheme: const ListTileThemeData(
        minVerticalPadding: 12,
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: highContrast ? 1.5 : 1,
        space: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        contentTextStyle: const TextStyle(
          fontFamily: 'Pretendard',
          fontSize: 16,
          fontWeight: FontWeight.w500,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 72,
        elevation: 0,
        backgroundColor: scheme.surfaceContainer,
        indicatorColor: scheme.secondaryContainer,
        labelTextStyle: WidgetStateProperty.all(
          const TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  /// 고대비 배색. Material 의 자동 대비 계산에 맡기지 않고 직접 못박는다 —
  /// 저시력 사용자에게는 이 값이 앱을 쓸 수 있느냐 없느냐를 가른다.
  static ColorScheme _highContrastScheme(Brightness brightness) {
    if (brightness == Brightness.dark) {
      return const ColorScheme.dark(
        primary: Color(0xFF7FD4FF),
        onPrimary: Color(0xFF000000),
        primaryContainer: Color(0xFF004A6E),
        onPrimaryContainer: Color(0xFFFFFFFF),
        secondary: Color(0xFFB9E4FF),
        onSecondary: Color(0xFF000000),
        secondaryContainer: Color(0xFF00344D),
        onSecondaryContainer: Color(0xFFFFFFFF),
        error: Color(0xFFFF8A80),
        onError: Color(0xFF000000),
        surface: Color(0xFF000000),
        onSurface: Color(0xFFFFFFFF),
        surfaceContainerLowest: Color(0xFF000000),
        surfaceContainerLow: Color(0xFF0A0A0A),
        surfaceContainer: Color(0xFF141414),
        surfaceContainerHigh: Color(0xFF1F1F1F),
        surfaceContainerHighest: Color(0xFF2A2A2A),
        outline: Color(0xFFE0E0E0),
        outlineVariant: Color(0xFF8A8A8A),
      );
    }
    return const ColorScheme.light(
      primary: Color(0xFF00405E),
      onPrimary: Color(0xFFFFFFFF),
      primaryContainer: Color(0xFFCCE8FF),
      onPrimaryContainer: Color(0xFF000000),
      secondary: Color(0xFF00344D),
      onSecondary: Color(0xFFFFFFFF),
      secondaryContainer: Color(0xFFD6ECFF),
      onSecondaryContainer: Color(0xFF000000),
      error: Color(0xFF8C0009),
      onError: Color(0xFFFFFFFF),
      surface: Color(0xFFFFFFFF),
      onSurface: Color(0xFF000000),
      surfaceContainerLowest: Color(0xFFFFFFFF),
      surfaceContainerLow: Color(0xFFF7F7F7),
      surfaceContainer: Color(0xFFEFEFEF),
      surfaceContainerHigh: Color(0xFFE7E7E7),
      surfaceContainerHighest: Color(0xFFDEDEDE),
      outline: Color(0xFF1A1A1A),
      outlineVariant: Color(0xFF5A5A5A),
    );
  }

  static TextTheme _textTheme(TextTheme base, ColorScheme scheme) {
    return base
        .copyWith(
          displayLarge: base.displayLarge?.copyWith(fontWeight: FontWeight.w800),
          headlineMedium:
              base.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
          titleLarge: base.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          titleMedium: base.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          // 본문 기본 크기를 Material 기본(14)보다 키운다. 이 앱에서 텍스트는
          // 장식이 아니라 유일한 정보 전달 수단이다.
          bodyLarge: base.bodyLarge?.copyWith(fontSize: 17, height: 1.5),
          bodyMedium: base.bodyMedium?.copyWith(fontSize: 15.5, height: 1.5),
          labelLarge: base.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        )
        .apply(fontFamily: 'Pretendard', bodyColor: scheme.onSurface);
  }
}

/// 자막 텍스트 크기 계산.
///
/// 기획 1-3 의 "말의 크기/세기 → 텍스트 크기로 표현" 을 담당한다.
class CaptionSizing {
  const CaptionSizing._();

  /// 자막 기본 크기(논리 픽셀).
  static const double base = 26.0;

  /// 세기에 따른 최대 증감 폭. 너무 크게 잡으면 줄바꿈이 요동쳐 읽기 어렵다.
  static const double _range = 10.0;

  /// [intensity](0~1) 와 사용자 배율로 실제 글자 크기를 정한다.
  ///
  /// [loudnessScaling] 이 꺼져 있으면 세기를 무시하고 고정 크기를 쓴다 —
  /// 글자 크기가 계속 변하는 것을 불편해하는 사용자가 있다.
  static double resolve({
    required double intensity,
    required double userScale,
    required bool loudnessScaling,
  }) {
    final clamped = intensity.clamp(0.0, 1.0);
    // 0.5(보통 말소리)를 기준점으로 두고 위아래로 벌린다.
    final delta = loudnessScaling ? (clamped - 0.5) * 2 * _range : 0.0;
    return ((base + delta) * userScale).clamp(14.0, 80.0);
  }

  /// 세기에 따른 굵기. 크기만으로는 시끄러운 환경에서 구분이 약하다.
  static FontWeight weightFor(double intensity) {
    if (intensity >= 0.75) return FontWeight.w800;
    if (intensity >= 0.55) return FontWeight.w700;
    if (intensity >= 0.3) return FontWeight.w500;
    return FontWeight.w400;
  }
}
