import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/api_client.dart';
import '../../data/api_exception.dart';
import '../../domain/entities/conversation.dart';
import '../../domain/entities/emotion_tone.dart';

/// 기록 목록 필터 (기획 3-2 "날짜별 / 위치별 / 화자별 분류 + 검색").
@immutable
class HistoryFilter {
  const HistoryFilter({
    this.query = '',
    this.dateFrom,
    this.dateTo,
    this.location,
    this.speakerName,
    this.favoritesOnly = false,
    this.tone,
  });

  final String query;
  final DateTime? dateFrom;
  final DateTime? dateTo;
  final String? location;
  final String? speakerName;
  final bool favoritesOnly;
  final EmotionTone? tone;

  bool get isEmpty =>
      query.isEmpty &&
      dateFrom == null &&
      dateTo == null &&
      (location == null || location!.isEmpty) &&
      (speakerName == null || speakerName!.isEmpty) &&
      !favoritesOnly &&
      tone == null;

  /// 활성화된 필터 개수. UI 배지에 쓴다.
  int get activeCount => [
        dateFrom != null || dateTo != null,
        location != null && location!.isNotEmpty,
        speakerName != null && speakerName!.isNotEmpty,
        favoritesOnly,
        tone != null,
      ].where((active) => active).length;

  HistoryFilter copyWith({
    String? query,
    DateTime? dateFrom,
    bool clearDateFrom = false,
    DateTime? dateTo,
    bool clearDateTo = false,
    String? location,
    bool clearLocation = false,
    String? speakerName,
    bool clearSpeakerName = false,
    bool? favoritesOnly,
    EmotionTone? tone,
    bool clearTone = false,
  }) {
    return HistoryFilter(
      query: query ?? this.query,
      dateFrom: clearDateFrom ? null : (dateFrom ?? this.dateFrom),
      dateTo: clearDateTo ? null : (dateTo ?? this.dateTo),
      location: clearLocation ? null : (location ?? this.location),
      speakerName: clearSpeakerName ? null : (speakerName ?? this.speakerName),
      favoritesOnly: favoritesOnly ?? this.favoritesOnly,
      tone: clearTone ? null : (tone ?? this.tone),
    );
  }

  static const HistoryFilter none = HistoryFilter();
}

@immutable
class HistoryState {
  const HistoryState({
    this.items = const [],
    this.filter = HistoryFilter.none,
    this.isLoading = false,
    this.isLoadingMore = false,
    this.hasMore = false,
    this.total = 0,
    this.errorMessage,
  });

  final List<ConversationSummary> items;
  final HistoryFilter filter;
  final bool isLoading;
  final bool isLoadingMore;
  final bool hasMore;
  final int total;
  final String? errorMessage;

  HistoryState copyWith({
    List<ConversationSummary>? items,
    HistoryFilter? filter,
    bool? isLoading,
    bool? isLoadingMore,
    bool? hasMore,
    int? total,
    String? errorMessage,
    bool clearError = false,
  }) {
    return HistoryState(
      items: items ?? this.items,
      filter: filter ?? this.filter,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasMore: hasMore ?? this.hasMore,
      total: total ?? this.total,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

class HistoryController extends StateNotifier<HistoryState> {
  HistoryController(this._api) : super(const HistoryState()) {
    unawaited(refresh());
  }

  final ApiClient _api;

  static const _pageSize = 20;

  /// 검색어 입력 중에 매 글자마다 요청하지 않도록 지연시킨다.
  Timer? _debounce;

  Future<void> refresh() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final page = await _fetch(offset: 0);
      state = state.copyWith(
        items: page.items,
        total: page.total,
        hasMore: page.hasMore,
        isLoading: false,
      );
    } on ApiException catch (error) {
      state = state.copyWith(isLoading: false, errorMessage: error.message);
    }
  }

  Future<void> loadMore() async {
    if (state.isLoadingMore || !state.hasMore) return;
    state = state.copyWith(isLoadingMore: true);

    try {
      final page = await _fetch(offset: state.items.length);
      state = state.copyWith(
        items: [...state.items, ...page.items],
        total: page.total,
        hasMore: page.hasMore,
        isLoadingMore: false,
      );
    } on ApiException catch (error) {
      state = state.copyWith(
        isLoadingMore: false,
        errorMessage: error.message,
      );
    }
  }

  Future<Paged<ConversationSummary>> _fetch({required int offset}) {
    final filter = state.filter;
    return _api.listSessions(
      query: filter.query,
      dateFrom: filter.dateFrom,
      dateTo: filter.dateTo,
      location: filter.location,
      speakerName: filter.speakerName,
      favoritesOnly: filter.favoritesOnly,
      tone: filter.tone,
      limit: _pageSize,
      offset: offset,
    );
  }

  /// 검색어 변경. 300ms 동안 추가 입력이 없으면 조회한다.
  void search(String query) {
    state = state.copyWith(filter: state.filter.copyWith(query: query));
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), refresh);
  }

  void applyFilter(HistoryFilter filter) {
    _debounce?.cancel();
    state = state.copyWith(filter: filter);
    unawaited(refresh());
  }

  void clearFilters() => applyFilter(HistoryFilter(query: state.filter.query));

  /// 즐겨찾기 토글. 목록을 다시 불러오지 않고 해당 항목만 갱신한다.
  Future<void> toggleFavorite(ConversationSummary session) async {
    final target = !session.isFavorite;

    // 낙관적 갱신 — 탭하면 즉시 반응해야 한다.
    _replace(session.copyWith(isFavorite: target));

    try {
      await _api.updateSession(session.id, isFavorite: target);
      // 즐겨찾기만 보기 상태에서 해제하면 목록에서 빠져야 한다.
      if (state.filter.favoritesOnly && !target) {
        state = state.copyWith(
          items: state.items.where((s) => s.id != session.id).toList(),
          total: (state.total - 1).clamp(0, 1 << 30),
        );
      }
    } on ApiException catch (error) {
      _replace(session); // 되돌린다
      state = state.copyWith(errorMessage: error.message);
    }
  }

  Future<void> rename(ConversationSummary session, String title) async {
    _replace(session.copyWith(title: title));
    try {
      await _api.updateSession(session.id, title: title);
    } on ApiException catch (error) {
      _replace(session);
      state = state.copyWith(errorMessage: error.message);
    }
  }

  Future<void> delete(ConversationSummary session) async {
    final previous = state.items;
    state = state.copyWith(
      items: state.items.where((s) => s.id != session.id).toList(),
      total: (state.total - 1).clamp(0, 1 << 30),
    );

    try {
      await _api.deleteSession(session.id);
    } on ApiException catch (error) {
      state = state.copyWith(items: previous, errorMessage: error.message);
    }
  }

  void _replace(ConversationSummary updated) {
    final items = [...state.items];
    final index = items.indexWhere((s) => s.id == updated.id);
    if (index >= 0) {
      items[index] = updated;
      state = state.copyWith(items: items);
    }
  }

  void clearError() => state = state.copyWith(clearError: true);

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }
}

final historyControllerProvider =
    StateNotifierProvider<HistoryController, HistoryState>((ref) {
  return HistoryController(ref.watch(apiClientProvider));
});

/// 대화 상세.
final conversationDetailProvider =
    FutureProvider.family<ConversationDetail, String>((ref, sessionId) {
  return ref.watch(apiClientProvider).getSession(sessionId);
});

/// 자막 본문 전체 검색 (기획 3-2 "검색 기능").
final captionSearchProvider =
    FutureProvider.family<Paged<CaptionSearchHit>, String>((ref, query) async {
  if (query.trim().length < 2) {
    return const Paged<CaptionSearchHit>(
      items: [],
      total: 0,
      limit: 50,
      offset: 0,
    );
  }
  return ref.watch(apiClientProvider).searchCaptions(query.trim());
});

/// 즐겨찾기한 자막 모아보기 (기획 3-2 "중요 대화 즐겨찾기").
final bookmarksProvider =
    FutureProvider<Paged<CaptionSearchHit>>((ref) async {
  return ref.watch(apiClientProvider).listBookmarks();
});
