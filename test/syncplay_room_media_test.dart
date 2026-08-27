import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/pages/player/controller/player_syncplay_controller.dart';
import 'package:kazumi/services/player/syncplay_media_codec.dart';
import 'package:kazumi/services/player/syncplay_room_models.dart';

import 'syncplay_test_doubles.dart';

Future<void> _settle([int turns = 5]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

PlayerSyncPlayController _controllerFor(FakeSyncplayClient client) {
  return PlayerSyncPlayController(
    endpointProvider: () => 'localhost:8996',
    clientFactory: ({required String host, required int port}) => client,
  );
}

Future<void> _disposeController(
  PlayerSyncPlayController controller,
  FakeSyncplayClient client,
) async {
  await controller.dispose();
  await client.closeStreams();
}

void main() {
  test('encodes and decodes the SyncPlay media name format', () {
    expect(
      SyncPlayMediaCodec.encode(bangumiId: 12345, episode: 9),
      '12345[9]',
    );
    final reference = SyncPlayMediaCodec.tryParse('12345[9]');

    expect(reference, isNotNull);
    expect(reference!.bangumiId, 12345);
    expect(reference.episode, 9);
  });

  test('rejects invalid media ids and episodes', () {
    for (final value in [
      '0[9]',
      '12345[0]',
      '-1[9]',
      '12345[-1]',
      '[9]',
      '12345',
      '12345[9]extra',
      'not-media',
    ]) {
      expect(
        SyncPlayMediaCodec.tryParse(value),
        isNull,
        reason: 'invalid media name should be ignored: $value',
      );
    }
  });

  test('caches remote media while no player is attached', () async {
    final client = FakeSyncplayClient();
    final controller = _controllerFor(client);
    await controller.createRoom('room-a', 'alice');
    final events = <SyncPlayRoomMediaEvent>[];
    final subscription = controller.mediaEvents.listen(events.add);

    client.emitFileChanged(name: '12345[9]', setBy: 'friend');
    await _settle();

    expect(controller.hasPlaybackBinding, isFalse);
    expect(controller.currentMedia, isNotNull);
    expect(controller.currentMedia!.bangumiId, 12345);
    expect(controller.currentMedia!.episode, 9);
    expect(controller.currentMedia!.selectedBy, 'friend');
    expect(controller.currentMedia!.generation, 1);
    expect(events.whereType<SyncPlayRoomMediaChanged>(), hasLength(1));

    await subscription.cancel();
    await _disposeController(controller, client);
  });

  test('increments media generation for each valid room update', () async {
    final client = FakeSyncplayClient();
    final controller = _controllerFor(client);
    await controller.createRoom('room-a', 'alice');

    client.emitFileChanged(name: '12345[9]');
    await _settle();
    expect(controller.mediaGeneration, 1);
    client.emitFileChanged(name: '12345[10]');
    await _settle();

    expect(controller.mediaGeneration, 2);
    expect(controller.currentMedia!.episode, 10);
    expect(controller.currentMedia!.generation, 2);
    await _disposeController(controller, client);
  });

  test('ignores invalid media events without changing cached state', () async {
    final client = FakeSyncplayClient();
    final controller = _controllerFor(client);
    await controller.createRoom('room-a', 'alice');
    client.emitFileChanged(name: '12345[9]');
    await _settle();
    final cachedMedia = controller.currentMedia;

    for (final value in ['0[9]', '12345[0]', 'bad']) {
      client.emitFileChanged(name: value);
    }
    await _settle();

    expect(controller.currentMedia, same(cachedMedia));
    expect(controller.mediaGeneration, 1);
    await _disposeController(controller, client);
  });

  test('changes episode for a same-bangumi remote media update', () async {
    final client = FakeSyncplayClient();
    final controller = _controllerFor(client);
    await controller.createRoom('room-a', 'alice');
    final binding = FakePlaybackBinding(
      bangumiId: 12345,
      currentEpisode: 8,
    );
    controller.attachPlayback(binding);

    client.emitFileChanged(name: '12345[9]', setBy: 'friend');
    await _settle();

    expect(binding.episodeChanges, [9]);
    expect(binding.currentEpisode, 9);
    expect(controller.currentMedia!.episode, 9);
    await _disposeController(controller, client);
  });

  test('does not change episode for an already selected episode', () async {
    final client = FakeSyncplayClient();
    final controller = _controllerFor(client);
    await controller.createRoom('room-a', 'alice');
    final binding = FakePlaybackBinding(
      bangumiId: 12345,
      currentEpisode: 9,
    );
    controller.attachPlayback(binding);

    client.emitFileChanged(name: '12345[9]');
    await _settle();

    expect(binding.episodeChanges, isEmpty);
    expect(controller.currentMedia!.episode, 9);
    await _disposeController(controller, client);
  });

  test('emits a mismatch and never changes episode across bangumis', () async {
    final client = FakeSyncplayClient();
    final controller = _controllerFor(client);
    await controller.createRoom('room-a', 'alice');
    final binding = FakePlaybackBinding(
      bangumiId: 12345,
      currentEpisode: 9,
    );
    controller.attachPlayback(binding);
    final events = <SyncPlayRoomMediaEvent>[];
    final subscription = controller.mediaEvents.listen(events.add);

    client.emitFileChanged(name: '67890[3]', setBy: 'friend');
    await _settle();

    expect(binding.episodeChanges, isEmpty);
    expect(controller.currentMedia!.bangumiId, 67890);
    final mismatches = events.whereType<SyncPlayRoomMediaMismatch>();
    expect(mismatches, hasLength(1));
    expect(mismatches.single.localBangumiId, 12345);
    expect(mismatches.single.roomMedia.episode, 3);

    await subscription.cancel();
    await _disposeController(controller, client);
  });
}
