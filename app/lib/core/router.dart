import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/alert/alert_history_screen.dart';
import '../features/auth/auth_screen.dart';
import '../features/history/bookmarks_screen.dart';
import '../features/history/conversation_detail_screen.dart';
import '../features/history/history_screen.dart';
import '../features/live/live_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/settings/stats_screen.dart';
import 'providers.dart';

final _rootNavigatorKey = GlobalKey<NavigatorState>();
final _shellNavigatorKey = GlobalKey<NavigatorState>();

final routerProvider = Provider<GoRouter>((ref) {
  final refreshListenable = _AuthRefreshNotifier(ref);
  ref.onDispose(refreshListenable.dispose);

  return GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: '/live',
    refreshListenable: refreshListenable,
    redirect: (context, state) {
      final auth = ref.read(authStateProvider);

      // 토큰 복원 중에는 아무 데도 보내지 않는다. 여기서 성급히 로그인 화면으로
      // 보내면 앱을 켤 때마다 로그인 화면이 깜빡인다.
      if (auth.status == AuthStatus.unknown) return null;

      final loggingIn = state.matchedLocation == '/login';

      if (!auth.isAuthenticated) return loggingIn ? null : '/login';
      if (loggingIn) return '/live';
      return null;
    },
    routes: [
      GoRoute(
        path: '/login',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => const AuthScreen(),
      ),

      // 하단 탭을 유지하는 셸
      ShellRoute(
        navigatorKey: _shellNavigatorKey,
        builder: (context, state, child) => AppShell(child: child),
        routes: [
          GoRoute(
            path: '/live',
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: LiveScreen()),
          ),
          GoRoute(
            path: '/history',
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: HistoryScreen()),
          ),
          GoRoute(
            path: '/settings',
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: SettingsScreen()),
          ),
        ],
      ),

      // 셸 밖 — 탭 없이 전체화면으로 열리는 화면들
      GoRoute(
        path: '/history/:sessionId',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => ConversationDetailScreen(
          sessionId: state.pathParameters['sessionId']!,
        ),
      ),
      GoRoute(
        path: '/bookmarks',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => const BookmarksScreen(),
      ),
      GoRoute(
        path: '/alerts',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => const AlertHistoryScreen(),
      ),
      GoRoute(
        path: '/stats',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => const StatsScreen(),
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      appBar: AppBar(title: const Text('페이지를 찾을 수 없습니다')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${state.uri}'),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => context.go('/live'),
              child: const Text('홈으로'),
            ),
          ],
        ),
      ),
    ),
  );
});

/// 로그인 상태가 바뀌면 go_router 가 redirect 를 다시 평가하게 한다.
class _AuthRefreshNotifier extends ChangeNotifier {
  _AuthRefreshNotifier(Ref ref) {
    _subscription = ref.listen<AuthState>(
      authStateProvider,
      (_, __) => notifyListeners(),
      fireImmediately: true,
    );
  }

  late final ProviderSubscription<AuthState> _subscription;

  @override
  void dispose() {
    _subscription.close();
    super.dispose();
  }
}

/// 하단 탭 셸.
class AppShell extends ConsumerWidget {
  const AppShell({required this.child, super.key});

  final Widget child;

  static const _destinations = [
    ('/live', Icons.mic_none_rounded, Icons.mic_rounded, '실시간 자막'),
    ('/history', Icons.history_outlined, Icons.history_rounded, '기록'),
    ('/settings', Icons.settings_outlined, Icons.settings_rounded, '설정'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = GoRouterState.of(context).matchedLocation;
    final index = _destinations.indexWhere((d) => location.startsWith(d.$1));
    final unacknowledged =
        ref.watch(unacknowledgedAlertCountProvider).valueOrNull ?? 0;

    return Scaffold(
      body: child,
      bottomNavigationBar: NavigationBar(
        selectedIndex: index < 0 ? 0 : index,
        onDestinationSelected: (selected) =>
            context.go(_destinations[selected].$1),
        destinations: [
          for (final (path, icon, selectedIcon, label) in _destinations)
            NavigationDestination(
              icon: path == '/settings' && unacknowledged > 0
                  ? Badge(
                      label: Text('$unacknowledged'),
                      child: Icon(icon),
                    )
                  : Icon(icon),
              selectedIcon: Icon(selectedIcon),
              label: label,
            ),
        ],
      ),
    );
  }
}
