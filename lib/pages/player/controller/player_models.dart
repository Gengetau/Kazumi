import 'package:kazumi/services/video_source/video_source_format.dart';

class PlaybackInitParams {
  final String videoUrl;
  final int offset;
  final bool isLocalPlayback;
  final VideoSourceFormat videoSourceFormat;
  final int bangumiId;
  final String pluginName;
  final int episode;
  final int danmakuEpisodeNumber;
  final String pageUrl;

  /// 集数排序号，语义同 EpisodeRef.sortNumber（在线解析自标题、离线为 episodeNumber）。
  final int? sortNumber;
  final Map<String, String> httpHeaders;
  final bool adBlockerEnabled;
  final String episodeTitle;
  final String referer;
  final int currentRoad;
  final String? coverUrl;
  final String? bangumiName;

  const PlaybackInitParams({
    required this.videoUrl,
    required this.offset,
    required this.isLocalPlayback,
    required this.bangumiId,
    required this.pluginName,
    required this.episode,
    required this.danmakuEpisodeNumber,
    required this.httpHeaders,
    required this.adBlockerEnabled,
    required this.episodeTitle,
    required this.referer,
    required this.currentRoad,
    this.videoSourceFormat = VideoSourceFormat.auto,
    this.pageUrl = '',
    this.sortNumber,
    this.coverUrl,
    this.bangumiName,
  });
}

enum DanmakuDestination {
  chatRoom,
  remoteDanmaku,
}

enum SyncPlayChatMessageType {
  user,
  system,
}

class SyncPlayChatMessage {
  /// A client-local identifier used for list keys and stable ordering.
  /// SyncPlay does not carry a message id, so this value is never sent.
  final int id;
  final String username;
  final String message;
  final bool fromRemote;
  final DateTime time;
  final SyncPlayChatMessageType type;

  const SyncPlayChatMessage({
    required this.id,
    required this.username,
    required this.message,
    required this.fromRemote,
    required this.time,
    this.type = SyncPlayChatMessageType.user,
  });
}
