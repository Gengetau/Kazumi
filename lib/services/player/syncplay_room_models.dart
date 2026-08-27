/// The most recent room playstate received from SyncPlay.
///
/// This snapshot is intentionally independent from a local media player and
/// remains available while no player is attached.
final class SyncPlayRoomPlaybackSnapshot {
  final bool paused;
  final Duration position;
  final String setBy;
  final bool doSeek;
  final DateTime receivedAt;

  const SyncPlayRoomPlaybackSnapshot({
    required this.paused,
    required this.position,
    required this.setBy,
    required this.doSeek,
    required this.receivedAt,
  });
}

/// The room's shared media choice.  Source URLs, rules and cookies remain
/// local to each member and are deliberately not represented here.
final class SyncPlayRoomMedia {
  final int bangumiId;
  final int episode;
  final String selectedBy;
  final DateTime updatedAt;
  final int generation;

  const SyncPlayRoomMedia({
    required this.bangumiId,
    required this.episode,
    required this.selectedBy,
    required this.updatedAt,
    required this.generation,
  });
}

/// Local-only status while this device resolves or loads a playable video
/// source for the room's selected media.
///
/// This state describes work performed by this device. It is deliberately
/// separate from [SyncPlayRoomMedia], which is only updated after the server
/// broadcasts the room's authoritative file choice.
enum SyncPlayLocalMediaStatus { idle, resolving, ready, failed }

/// A media event observed by a page.  Session emits events; navigation and
/// other UI decisions remain outside the service layer.
sealed class SyncPlayRoomMediaEvent {
  const SyncPlayRoomMediaEvent();
}

final class SyncPlayRoomMediaChanged extends SyncPlayRoomMediaEvent {
  final SyncPlayRoomMedia media;

  const SyncPlayRoomMediaChanged(this.media);
}

final class SyncPlayRoomMediaMismatch extends SyncPlayRoomMediaEvent {
  final SyncPlayRoomMedia roomMedia;
  final int localBangumiId;

  const SyncPlayRoomMediaMismatch({
    required this.roomMedia,
    required this.localBangumiId,
  });
}
