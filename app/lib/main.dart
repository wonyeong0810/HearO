import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'core/providers.dart';
import 'core/router.dart';
import 'core/theme/app_theme.dart';
import 'domain/entities/conversation.dart';
import 'features/alert/alert_overlay.dart';
import 'features/alert/alert_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 한국어 날짜 포맷(요일 등)에 필요하다.
  await initializeDateFormatting('ko');

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  runApp(const ProviderScope(child: HearOApp()));
}

class HearOApp extends ConsumerStatefulWidget {
  const HearOApp({super.key});

  @override
  ConsumerState<HearOApp> createState() => _HearOAppState();
}

class _HearOAppState extends ConsumerState<HearOApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // 첫 프레임 이후에 무거운 초기화를 한다 — 스플래시가 오래 떠 있으면
    // 앱이 멈춘 것처럼 보인다.
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  Future<void> _bootstrap() async {
    final alerts = ref.read(alertServiceProvider.notifier);
    await alerts.initialize();

    // 설정을 받아온 뒤 경보 감시를 시작한다. 로그인 전이면 설정 로드가
    // 완료될 때 아래 listener 가 대신 시작한다.
    final settings = ref.read(settingsProvider).valueOrNull;
    if (settings?.alertsEnabled ?? false) {
      await alerts.startMonitoring(settings: settings);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    // 앱이 다시 앞으로 나오면, 오프라인 동안 쌓인 경보를 서버에 올린다.
    if (state == AppLifecycleState.resumed) {
      unawaited(ref.read(alertServiceProvider.notifier).flushPendingUploads());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);
    final settings = ref.watch(settingsProvider).valueOrNull;
    final highContrast = settings?.highContrastMode ?? false;

    // 설정이 로드되면 경보 감시를 시작한다.
    ref.listen<AsyncValue<AppSettings>>(settingsProvider, (previous, next) {
      final loaded = next.valueOrNull;
      if (loaded == null) return;
      final service = ref.read(alertServiceProvider.notifier);
      if (loaded.alertsEnabled && !ref.read(alertServiceProvider).monitoring) {
        unawaited(service.startMonitoring(settings: loaded));
      }
    });

    return MaterialApp.router(
      title: 'HearO',
      debugShowCheckedModeBanner: false,
      routerConfig: router,

      theme: AppTheme.light(highContrast: highContrast),
      darkTheme: AppTheme.dark(highContrast: highContrast),
      themeMode: ThemeMode.system,

      locale: const Locale('ko'),
      supportedLocales: const [Locale('ko'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],

      builder: (context, child) {
        // 1) 경보 오버레이는 라우터 바깥에 둔다 — 어느 화면에 있든,
        //    다이얼로그가 떠 있든 경고가 화면을 덮어야 한다.
        // 2) 시스템 글꼴 확대는 존중하되 상한을 둔다. 무제한으로 키우면
        //    버튼 레이블이 잘려 오히려 못 쓰게 된다.
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            textScaler: media.textScaler.clamp(
              minScaleFactor: 0.85,
              maxScaleFactor: 1.6,
            ),
          ),
          child: AlertHost(child: child ?? const SizedBox.shrink()),
        );
      },
    );
  }
}
