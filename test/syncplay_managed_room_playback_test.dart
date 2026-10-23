import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/pages/player/controller/player_syncplay_controller.dart';
import 'package:kazumi/services/player/syncplay_managed_room_models.dart';

import 'syncplay_test_doubles.dart';

const _managedRoom = '+room-a:ABCDEF123456';
const _managedFeatures = SyncplayServerFeatures(
  managedRooms: true,
  sharedPlaylists: true,
  chat: true,
  readiness: true,
  featureList: true,
);

PlayerSyncPlayController _controllerFor(FakeSyncplayClient client) {
  return PlayerSyncPlayController(
    endpointProvider: () => 'localhost:8996',
    clientFactory: ({required String host, required int port}) => client,
  );
}

Future<void> _settleUntil(bool Function() predicate) async {
  for (var i = 0; i < 100; i++) {
    if (predicate()) {
      return;
    }
    await Future<void>.delayed(Duration.zero);
  }
  fail('Condition did not settle');
}

Future<void> _dispose(
  PlayerSyncPlayController controller,
  FakeSyncplayClient client,
) async {
  await controller.dispose();
  await client.closeStreams();
}

Future<void> _joinManagedRoom(
  PlayerSyncPlayController controller,
  FakeSyncplayClient client, {
  required bool localOperator,
}) async {
  final join = controller.createRoom(_managedRoom, 'alice');
  await _settleUntil(() => client.userListRequests == 1);
  client.emitUserList([
    SyncplayRoomUser(
      username: 'server-alice',
      room: _managedRoom,
      isController: localOperator,
    ),
    if (!localOperator)
      const SyncplayRoomUser(
        username: 'host',
        room: _managedRoom,
        isController: true,
      ),
  ]);
  await join;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('free rooms keep publishing local playback state', () async {
    final client = FakeSyncplayClient();
    final controller = _controllerFor(client);
    await controller.createRoom('room-a', 'alice');
    controller.attachPlayback(
      FakePlaybackBinding(
        bangumiId: 12345,
        currentEpisode: 1,
        playing: true,
        currentPosition: const Duration(seconds: 12),
        playerPosition: const Duration(seconds: 12),
      ),
    );
    await _settleUntil(() => client.syncRequests.isNotEmpty);
    client.pausedValues.clear();
    client.positions.clear();
    client.syncRequests.clear();

    expect(controller.canControlLocalPlayback, isTrue);
    expect(controller.shouldBroadcastLocalPlayback, isTrue);
    expect(controller.canChangePlaybackSpeed, isTrue);

    controller.setCurrentPosition();
    await controller.requestSync(doSeek: true);

    expect(client.pausedValues, [false]);
    expect(client.positions, [12.0]);
    expect(client.syncRequests, [true]);

    await _dispose(controller, client);
  });

  test('managed followers cannot publish but still apply room state', () async {
    final client = FakeSyncplayClient(
      acceptedRoom: _managedRoom,
      serverFeatures: _managedFeatures,
    );
    final controller = _controllerFor(client);
    await _joinManagedRoom(controller, client, localOperator: false);
    client.emitFileChanged(name: '12345[3]', setBy: 'host');
    await _settleUntil(() => controller.currentMedia != null);
    final binding = FakePlaybackBinding(
      bangumiId: 12345,
      currentEpisode: 3,
      currentPosition: const Duration(seconds: 4),
      playerPosition: const Duration(seconds: 4),
    );
    controller.attachPlayback(binding);
    await Future<void>.delayed(Duration.zero);

    controller.setCurrentPosition();
    await controller.requestSync(doSeek: true);

    expect(controller.canControlLocalPlayback, isFalse);
    expect(controller.shouldBroadcastLocalPlayback, isFalse);
    expect(client.pausedValues, isEmpty);
    expect(client.positions, isEmpty);
    expect(client.syncRequests, isEmpty);

    client.emitPosition(
      position: 30,
      paused: false,
      doSeek: true,
      setBy: 'host',
    );
    await _settleUntil(
      () => binding.seekCalls.isNotEmpty && binding.playCalls == 1,
    );

    expect(binding.seekCalls.single.inMilliseconds, closeTo(30000, 50));
    expect(binding.playing, isTrue);

    await _dispose(controller, client);
  });

  test('player-first members become local-only in an empty managed room',
      () async {
    final client = FakeSyncplayClient(
      acceptedRoom: _managedRoom,
      serverFeatures: _managedFeatures,
    );
    final controller = _controllerFor(client);
    final binding = FakePlaybackBinding(
      bangumiId: 12345,
      currentEpisode: 1,
      playing: true,
    );
    controller.attachPlayback(binding);

    await _joinManagedRoom(controller, client, localOperator: false);

    expect(controller.currentMedia, isNull);
    expect(
      controller.playbackParticipation,
      SyncPlayPlaybackParticipation.localOnly,
    );
    expect(controller.canControlLocalPlayback, isTrue);
    expect(controller.shouldBroadcastLocalPlayback, isFalse);
    expect(controller.canChangePlaybackSpeed, isTrue);

    await _dispose(controller, client);
  });

  test('managed operators control the shared timeline and media', () async {
    final client = FakeSyncplayClient(
      acceptedRoom: _managedRoom,
      serverFeatures: _managedFeatures,
    );
    final controller = _controllerFor(client);
    await _joinManagedRoom(controller, client, localOperator: true);
    client.emitFileChanged(name: '12345[3]', setBy: 'server-alice');
    await _settleUntil(() => controller.currentMedia != null);
    final binding = FakePlaybackBinding(
      bangumiId: 12345,
      currentEpisode: 3,
      playing: false,
      currentPosition: const Duration(seconds: 18),
      playerPosition: const Duration(seconds: 18),
    );
    controller.attachPlayback(binding);
    await Future<void>.delayed(Duration.zero);

    controller.setCurrentPosition();
    await controller.requestSync(doSeek: true);

    expect(controller.isRoomOperator, isTrue);
    expect(controller.canControlLocalPlayback, isTrue);
    expect(controller.shouldBroadcastLocalPlayback, isTrue);
    expect(controller.canChangePlaybackSpeed, isFalse);
    expect(client.pausedValues, [true]);
    expect(client.positions, [18.0]);
    expect(client.syncRequests, [true]);

    final selection = controller.selectRoomMedia(
      bangumiId: 12345,
      episode: 4,
      localRoad: 2,
    );
    await _settleUntil(() => client.setPlayingNames.contains('12345[4]'));
    client.emitFileChanged(name: '12345[4]', setBy: 'server-alice');
    expect(await selection, isTrue);
    await _settleUntil(() => binding.episodeChanges.contains(4));
    expect(binding.episodeChangeRoads, [2]);

    await _dispose(controller, client);
  });

  test('local-only operator playback never drives the shared timeline',
      () async {
    final client = FakeSyncplayClient(
      acceptedRoom: _managedRoom,
      serverFeatures: _managedFeatures,
    );
    final controller = _controllerFor(client);
    await _joinManagedRoom(controller, client, localOperator: true);
    client.emitFileChanged(name: '12345[3]', setBy: 'server-alice');
    await _settleUntil(() => controller.currentMedia != null);
    final binding = FakePlaybackBinding(
      bangumiId: 67890,
      currentEpisode: 1,
      playing: true,
      currentPosition: const Duration(seconds: 40),
      playerPosition: const Duration(seconds: 40),
    );
    controller.attachPlayback(binding);
    await Future<void>.delayed(Duration.zero);

    expect(
      controller.playbackParticipation,
      SyncPlayPlaybackParticipation.localOnly,
    );
    expect(controller.canControlLocalPlayback, isTrue);
    expect(controller.shouldBroadcastLocalPlayback, isFalse);
    expect(controller.canChangePlaybackSpeed, isTrue);

    controller.setCurrentPosition();
    await controller.requestSync(doSeek: true);
    expect(client.pausedValues, isEmpty);
    expect(client.positions, isEmpty);
    expect(client.syncRequests, isEmpty);

    client.emitPosition(
      position: 8,
      paused: true,
      doSeek: true,
      setBy: 'server-alice',
    );
    await Future<void>.delayed(Duration.zero);

    expect(binding.seekCalls, isEmpty);
    expect(binding.pauseCalls, 0);
    expect(binding.playing, isTrue);

    await _dispose(controller, client);
  });
}
