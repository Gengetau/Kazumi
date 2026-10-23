import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/episode_item.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';
import 'package:kazumi/pages/syncplay_room/media_picker/syncplay_room_media_selection.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/async_session.dart';

export 'syncplay_room_media_selection.dart';

typedef SyncPlayRoomRecommendationsLoader =
    Future<List<BangumiItem>> Function();
typedef SyncPlayRoomSearchLoader = Future<BangumiSearchPage?> Function(
  String keyword,
);
typedef SyncPlayRoomEpisodesLoader = Future<List<EpisodeInfo>> Function(
  int bangumiId,
);

bool _isBangumiMirrorEnabled() {
  try {
    return GStorage.getSetting<bool>(SettingsKeys.enableBangumiProxy);
  } catch (_) {
    // Unit tests and early startup can construct the picker before Hive.
    return false;
  }
}

Future<List<BangumiItem>> _loadDefaultRecommendations() {
  return _isBangumiMirrorEnabled()
      ? BangumiApi.getBangumiMirrorPopularSubjects(limit: 24)
      : BangumiApi.getBangumiTrendsList(limit: 24);
}

Future<BangumiSearchPage?> _loadDefaultSearch(String keyword) {
  return BangumiApi.bangumiSearch(keyword, limit: 24);
}

Future<List<EpisodeInfo>> _loadDefaultEpisodes(int bangumiId) {
  return BangumiApi.getBangumiEpisodesByID(bangumiId);
}

/// Owns the replaceable, local state used by the room media picker.
///
/// This controller deliberately has no room-session reference. Selecting an
/// item only creates a [SyncPlayRoomMediaSelection] for the page; the page's
/// app-scoped room session sends the id and episode after confirmation.
class SyncPlayRoomMediaPickerController extends ChangeNotifier {
  SyncPlayRoomMediaPickerController({
    SyncPlayRoomRecommendationsLoader? recommendationsLoader,
    SyncPlayRoomSearchLoader? searchLoader,
    SyncPlayRoomEpisodesLoader? episodesLoader,
    Duration searchDebounce = const Duration(milliseconds: 300),
  }) : _recommendationsLoader =
           recommendationsLoader ?? _loadDefaultRecommendations,
       _searchLoader = searchLoader ?? _loadDefaultSearch,
       _episodesLoader = episodesLoader ?? _loadDefaultEpisodes,
       _searchDebounce = searchDebounce;

  final SyncPlayRoomRecommendationsLoader _recommendationsLoader;
  final SyncPlayRoomSearchLoader _searchLoader;
  final SyncPlayRoomEpisodesLoader _episodesLoader;
  final Duration _searchDebounce;

  final AsyncSessionOwner _recommendationSessions = AsyncSessionOwner();
  final AsyncSessionOwner _searchSessions = AsyncSessionOwner();
  final AsyncSessionOwner _episodeSessions = AsyncSessionOwner();

  Timer? _searchTimer;
  bool _disposed = false;

  List<BangumiItem> _recommendations = <BangumiItem>[];
  List<BangumiItem> _searchResults = <BangumiItem>[];
  BangumiItem? _selectedBangumi;
  List<int> _episodes = <int>[];
  int _selectedEpisode = 1;
  String _query = '';

  bool _isLoadingRecommendations = false;
  bool _isLoadingSearch = false;
  bool _isLoadingEpisodes = false;
  String? _recommendationError;
  String? _searchError;
  String? _episodeError;

  List<BangumiItem> get recommendations =>
      List<BangumiItem>.unmodifiable(_recommendations);

  /// Alias kept descriptive for callers that do not use the page wording.
  List<BangumiItem> get recommendedBangumis => recommendations;

  List<BangumiItem> get searchResults =>
      List<BangumiItem>.unmodifiable(_searchResults);

  List<BangumiItem> get searchBangumis => searchResults;

  BangumiItem? get selectedBangumi => _selectedBangumi;

  List<int> get episodes => List<int>.unmodifiable(_episodes);

  List<int> get episodeNumbers => episodes;

  int get selectedEpisode => _selectedEpisode;

  String get query => _query;

  bool get isLoadingRecommendations => _isLoadingRecommendations;

  bool get isLoadingSearch => _isLoadingSearch;

  bool get isLoadingEpisodes => _isLoadingEpisodes;

  bool get isLoading =>
      _isLoadingRecommendations || _isLoadingSearch || _isLoadingEpisodes;

  String? get recommendationError => _recommendationError;

  String? get searchError => _searchError;

  String? get episodeError => _episodeError;

  bool get hasSearchQuery => _query.trim().isNotEmpty;

  bool get canConfirm =>
      _selectedBangumi != null &&
      _selectedBangumi!.id > 0 &&
      _selectedEpisode > 0 &&
      !_isLoadingEpisodes;

  Future<void> loadRecommendations() async {
    final session = _recommendationSessions.begin();
    _isLoadingRecommendations = true;
    _recommendationError = null;
    _notify();
    try {
      final result = await _recommendationsLoader();
      if (session.isStale) return;
      _recommendations = _deduplicate(result);
    } catch (_) {
      if (session.isStale) return;
      _recommendations = <BangumiItem>[];
      _recommendationError = '推荐加载失败，请重试';
    } finally {
      if (session.isActive) {
        _isLoadingRecommendations = false;
        _notify();
      }
    }
  }

  /// Schedules a search after the user pauses typing.
  void scheduleSearch(String keyword) {
    _query = keyword;
    _searchTimer?.cancel();
    _searchSessions.cancel();
    if (keyword.trim().isEmpty) {
      _searchResults = <BangumiItem>[];
      _searchError = null;
      _isLoadingSearch = false;
      _notify();
      return;
    }
    _searchTimer = Timer(_searchDebounce, () {
      unawaited(searchBangumi(keyword));
    });
    _notify();
  }

  /// Performs an immediate search, suitable for a submitted query or retry.
  Future<void> searchBangumi(String keyword) async {
    _searchTimer?.cancel();
    _query = keyword;
    final normalized = keyword.trim();
    _searchSessions.cancel();
    if (normalized.isEmpty) {
      _searchResults = <BangumiItem>[];
      _searchError = null;
      _isLoadingSearch = false;
      _notify();
      return;
    }

    final session = _searchSessions.begin();
    _isLoadingSearch = true;
    _searchError = null;
    _searchResults = <BangumiItem>[];
    _notify();
    try {
      final page = await _searchLoader(normalized);
      if (session.isStale) return;
      if (page == null) {
        _searchError = '搜索失败，请重试';
        _searchResults = <BangumiItem>[];
      } else {
        _searchResults = _deduplicate(page.items);
      }
    } catch (_) {
      if (session.isStale) return;
      _searchResults = <BangumiItem>[];
      _searchError = '搜索失败，请重试';
    } finally {
      if (session.isActive) {
        _isLoadingSearch = false;
        _notify();
      }
    }
  }

  void clearSearch() {
    _searchTimer?.cancel();
    _searchSessions.cancel();
    _query = '';
    _searchResults = <BangumiItem>[];
    _searchError = null;
    _isLoadingSearch = false;
    _notify();
  }

  /// Selects a Bangumi and asynchronously resolves its episode numbers.
  Future<void> selectBangumi(BangumiItem bangumi) async {
    _selectedBangumi = bangumi;
    _selectedEpisode = 1;
    _episodes = <int>[];
    _episodeError = null;
    _isLoadingEpisodes = true;
    final session = _episodeSessions.begin();
    _notify();
    try {
      final result = await _episodesLoader(bangumi.id);
      if (session.isStale) return;
      final numbers = _episodeNumbers(result);
      _episodes = numbers.isEmpty ? <int>[1] : numbers;
      if (!_episodes.contains(_selectedEpisode)) {
        _selectedEpisode = _episodes.first;
      }
    } catch (_) {
      if (session.isStale) return;
      // A valid room protocol value is still available when the optional
      // episode metadata endpoint is unavailable. The page shows the retry
      // affordance while allowing the user to confirm episode one.
      _episodes = <int>[1];
      _selectedEpisode = 1;
      _episodeError = '集数加载失败，可重试';
    } finally {
      if (session.isActive) {
        _isLoadingEpisodes = false;
        _notify();
      }
    }
  }

  Future<void> retryEpisodes() async {
    final bangumi = _selectedBangumi;
    if (bangumi == null) return;
    await selectBangumi(bangumi);
  }

  bool setEpisode(int episode) {
    if (_selectedBangumi == null ||
        episode <= 0 ||
        (_episodes.isNotEmpty && !_episodes.contains(episode))) {
      return false;
    }
    _selectedEpisode = episode;
    _notify();
    return true;
  }

  /// Alias used by episode-picker widgets.
  bool selectEpisode(int episode) => setEpisode(episode);

  SyncPlayRoomMediaSelection? buildSelection() {
    if (!canConfirm) return null;
    return SyncPlayRoomMediaSelection(
      bangumi: _selectedBangumi!,
      episode: _selectedEpisode,
    );
  }

  /// Kept separate from navigation so the pure selection logic is testable.
  SyncPlayRoomMediaSelection? confirmSelection() => buildSelection();

  List<BangumiItem> _deduplicate(Iterable<BangumiItem> items) {
    final ids = <int>{};
    return items.where((item) => item.id > 0 && ids.add(item.id)).toList();
  }

  List<int> _episodeNumbers(Iterable<EpisodeInfo> infos) {
    final regular = infos
        .where((info) => info.type == 0)
        .map(_episodeNumber)
        .whereType<int>()
        .toSet()
        .toList();
    final all = infos.map(_episodeNumber).whereType<int>().toSet().toList();
    final numbers = regular.isNotEmpty ? regular : all;
    numbers.sort();
    return numbers;
  }

  int? _episodeNumber(EpisodeInfo info) {
    final value = info.episode.toDouble();
    if (!value.isFinite || value <= 0 || value != value.roundToDouble()) {
      return null;
    }
    return value.toInt();
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _searchTimer?.cancel();
    _recommendationSessions.close();
    _searchSessions.close();
    _episodeSessions.close();
    super.dispose();
  }
}
