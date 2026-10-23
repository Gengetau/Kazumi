import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/plugins/plugins.dart';

/// Identifies the room media snapshot a video route was opened for.
///
/// Room-first navigation resolves a playable source asynchronously.  The
/// room may receive another media update while that lookup is in flight, so
/// the route must verify this identity before starting a stale player.
class SyncPlayPlaybackLaunchIntent {
  const SyncPlayPlaybackLaunchIntent({
    required this.expectedBangumiId,
    required this.expectedEpisode,
    required this.expectedMediaGeneration,
  });

  final int expectedBangumiId;
  final int expectedEpisode;
  final int expectedMediaGeneration;

  bool get isValid =>
      expectedBangumiId > 0 &&
      expectedEpisode > 0 &&
      expectedMediaGeneration >= 0;
}

/// Route arguments for '/video/'. Entry points hand playback context over
/// through the route instead of pre-filling a shared controller, which lets
/// [VideoPageController] live and die with the route.
sealed class VideoPlaybackArgs {
  const VideoPlaybackArgs({
    required this.bangumiItem,
    this.launchIntent,
  });

  final BangumiItem bangumiItem;

  final SyncPlayPlaybackLaunchIntent? launchIntent;

  /// Descriptive alias for callers that do not use the short route name.
  SyncPlayPlaybackLaunchIntent? get playbackLaunchIntent => launchIntent;
}

class OnlineVideoPlaybackArgs extends VideoPlaybackArgs {
  const OnlineVideoPlaybackArgs({
    required super.bangumiItem,
    required this.plugin,
    required this.title,
    required this.src,
    required this.roads,
    super.launchIntent,
  });

  final Plugin plugin;
  final String title;
  final String src;
  final List<Road> roads;
}

class OfflineVideoPlaybackArgs extends VideoPlaybackArgs {
  const OfflineVideoPlaybackArgs({
    required super.bangumiItem,
    required this.pluginName,
    required this.episodeNumber,
    required this.road,
    required this.downloadedEpisodes,
    super.launchIntent,
  });

  final String pluginName;
  final int episodeNumber;
  final int road;
  final List<DownloadEpisode> downloadedEpisodes;
}
