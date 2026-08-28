import 'package:kazumi/pages/player/player_controller.dart';
import 'package:kazumi/services/player/syncplay_playback_binding.dart';

/// Adapter exposing only the playback operations a room session needs.
///
/// Keeping this adapter at the player boundary prevents the app-scoped
/// session from depending on PlayerController or on a VideoPageState.
final class PlayerSyncPlayBinding implements SyncPlayPlaybackBinding {
  final PlayerController player;

  const PlayerSyncPlayBinding(this.player);

  @override
  int get bangumiId => player.currentBangumiId;

  @override
  int get currentEpisode => player.currentPlaybackEpisode;

  @override
  int get currentRoad => player.currentPlaybackRoad;

  @override
  bool get playing => player.playback.playing;

  @override
  Duration get currentPosition => player.playback.currentPosition;

  @override
  Duration get playerPosition => player.playback.playerPosition;

  @override
  Duration get duration => player.playback.duration;

  @override
  Future<void> playFromRoom() => player.play(enableSync: false);

  @override
  Future<void> pauseFromRoom() => player.pause(enableSync: false);

  @override
  Future<void> seekFromRoom(Duration position) =>
      player.seek(position, enableSync: false);

  @override
  Future<void> changeEpisodeFromRoom(
    int episode, {
    int? preferredRoad,
  }) =>
      player.changeEpisodeFromRoom(
        episode,
        preferredRoad: preferredRoad,
      );

  @override
  Future<void> publishCurrentMedia({
    bool? forcePlaying,
    double? forcePosition,
  }) =>
      player.setSyncPlayPlayingBangumi(
        forceSyncPlaying: forcePlaying,
        forceSyncPosition: forcePosition,
      );
}
