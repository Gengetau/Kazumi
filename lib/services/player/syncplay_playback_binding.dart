/// A temporary bridge from an active player to the app-scoped room session.
///
/// The room session must not retain a PlayerController, a page state, or any
/// route callback.  Implementations are short-lived and are replaced whenever
/// a new player route attaches.
abstract interface class SyncPlayPlaybackBinding {
  int get bangumiId;

  int get currentEpisode;

  int get currentRoad;

  bool get playing;

  Duration get currentPosition;

  Duration get playerPosition;

  Duration get duration;

  Future<void> playFromRoom();

  Future<void> pauseFromRoom();

  Future<void> seekFromRoom(Duration position);

  Future<void> changeEpisodeFromRoom(
    int episode, {
    int? preferredRoad,
  });

  Future<void> publishCurrentMedia({
    bool? forcePlaying,
    double? forcePosition,
  });
}

/// A generation-tagged player attachment.
///
/// A route can finish disposing after a replacement player has already
/// attached.  Session code must compare this token before detaching or before
/// invoking any asynchronous playback operation.
final class SyncPlayPlaybackAttachment {
  final int generation;
  final SyncPlayPlaybackBinding binding;

  const SyncPlayPlaybackAttachment({
    required this.generation,
    required this.binding,
  });
}
