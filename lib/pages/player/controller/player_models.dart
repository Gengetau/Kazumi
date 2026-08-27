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

/// The lifecycle of the SyncPlay connection owned by the player.
///
/// A socket being allocated is deliberately not the same thing as being
/// connected: the server's Hello response is the point at which the room and
/// identity are authoritative.
enum SyncPlayConnectionState {
  disconnected,
  connecting,
  connected,
  reconnecting,
  failed,
}

/// Returns a safe display name for data received from a SyncPlay server.
///
/// Usernames are server supplied and are also rendered in system messages and
/// mention matching. Keeping control characters (or an unbounded value) here
/// would make those two paths ambiguous, so malformed values become a
/// localized system identity instead of being interpolated into the UI.
String normalizeSyncPlayUsername(Object? value, {String fallback = '系统'}) {
  final text = value is String ? value.trim() : '';
  if (!isSyncPlayUsernameValid(value)) {
    return fallback;
  }
  return text;
}

bool isSyncPlayUsernameValid(Object? value) {
  if (value is! String) {
    return false;
  }
  final text = value.trim();
  if (text.isEmpty || text.length > 32) {
    return false;
  }
  for (final codeUnit in text.codeUnits) {
    if (codeUnit < 0x20 || codeUnit == 0x7f) {
      return false;
    }
  }
  return true;
}

int syncPlayUsernameHash(String username) {
  var hash = 0x811c9dc5;
  for (final codeUnit in username.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x01000193) & 0x7fffffff;
  }
  return hash;
}

String syncPlayUsernameInitial(String username) {
  final safeName = normalizeSyncPlayUsername(username, fallback: '?');
  if (safeName == '?') {
    return safeName;
  }
  return String.fromCharCodes(safeName.runes.take(1));
}

bool syncPlayMessageMentionsUsername(String message, String username) {
  if (!isSyncPlayUsernameValid(username) || message.isEmpty) {
    return false;
  }
  final pattern = RegExp(
    r'(^|[\s\(\[\{（【「“‘])@' + RegExp.escape(username) +
        r'(?=$|[\s,.!?！？:：;；\)\]\}）】」”’])',
    caseSensitive: false,
  );
  return pattern.hasMatch(message);
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
  final bool mentionsSelf;

  const SyncPlayChatMessage({
    required this.id,
    required this.username,
    required this.message,
    required this.fromRemote,
    required this.time,
    this.type = SyncPlayChatMessageType.user,
    this.mentionsSelf = false,
  });

  bool canGroupWith(SyncPlayChatMessage other) {
    if (type != SyncPlayChatMessageType.user ||
        other.type != SyncPlayChatMessageType.user ||
        username != other.username ||
        fromRemote != other.fromRemote) {
      return false;
    }
    return time.difference(other.time).inSeconds.abs() <= 60;
  }
}
