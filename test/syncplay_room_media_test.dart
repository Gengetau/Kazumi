import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/pages/player/controller/player_syncplay_controller.dart';
import 'package:kazumi/pages/video/video_playback_args.dart';
import 'package:kazumi/services/player/syncplay_media_codec.dart';
import 'package:kazumi/services/player/syncplay_room_models.dart';

import 'syncplay_test_doubles.dart';

Future<void> _settle([int turns = 5]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

PlayerSyncPlayController _controllerFor(
  FakeSyncplayClient client, {
  Duration? mediaSelectionTimeout,
}) {
  return PlayerSyncPlayController(
    endpointProvider: () => 'localhost:8996',
    mediaSelectionTimeout: mediaSelectionTimeout,
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

  test('selects room media only after a matching server broadcast', () async {
    final client = FakeSyncplayClient();
    final controller = _controllerFor(client);
    await controller.createRoom('room-a', 'alice');

    expect(controller.canControlPlayback, isTrue);
    expect(controller.canSelectRoomMedia, isTrue);
    final selection = controller.selectRoomMedia(bangumiId: 12345, episode: 9);
    await _settle();

    expect(controller.currentMedia, isNull);
    expect(controller.localMediaStatus, SyncPlayLocalMediaStatus.idle);
    expect(client.operations, [
      'setPlaying:12345[9]',
      'paused:true',
      'position:0.0',
      'sync:true',
    ]);

    client.emitFileChanged(name: '12345[9]', setBy: 'alice');

    expect(await selection, isTrue);
    expect(controller.currentMedia!.generation, 1);
    expect(controller.mediaGeneration, 1);
    expect(controller.localMediaStatus, SyncPlayLocalMediaStatus.idle);
    await _disposeController(controller, client);
  });

  test('video-first attachment publishes media when the room is empty',
      () async {
    final client = FakeSyncplayClient();
    final controller = _controllerFor(client);
    await controller.createRoom('room-a', 'alice');
    final binding = FakePlaybackBinding(
      bangumiId: 12345,
      currentEpisode: 9,
    );

    controller.attachPlayback(binding);
    await _settle(8);

    expect(controller.currentMedia, isNull);
    expect(client.setPlayingNames, ['12345[9]']);
    expect(client.syncRequests, [null]);
    await _disposeController(controller, client);
  });

  test('launch intent follows the room media generation', () async {
    final client = FakeSyncplayClient();
    final controller = _controllerFor(client);
    await controller.createRoom('room-a', 'alice');

    const initial = SyncPlayPlaybackLaunchIntent(
      expectedBangumiId: 12345,
      expectedEpisode: 9,
      expectedMediaGeneration: 0,
    );
    expect(controller.isPlaybackLaunchIntentCurrent(initial), isTrue);

    client.emitFileChanged(name: '12345[9]', setBy: 'peer');
    await _settle();

    expect(controller.isPlaybackLaunchIntentCurrent(initial), isFalse);
    final media = controller.currentMedia!;
    final current = SyncPlayPlaybackLaunchIntent(
      expectedBangumiId: media.bangumiId,
      expectedEpisode: media.episode,
      expectedMediaGeneration: media.generation,
    );
    expect(controller.isPlaybackLaunchIntentCurrent(current), isTrue);
    await _disposeController(controller, client);
  });

  test(
    'rejects invalid room media selections without sending protocol data',
    () async {
      final client = FakeSyncplayClient();
      final controller = _controllerFor(client);
      await controller.createRoom('room-a', 'alice');

      expect(
        await controller.selectRoomMedia(bangumiId: 0, episode: 9),
        isFalse,
      );
      expect(
        await controller.selectRoomMedia(bangumiId: 12345, episode: 0),
        isFalse,
      );
      expect(client.operations, isEmpty);
      expect(controller.localMediaStatus, SyncPlayLocalMediaStatus.idle);
      await _disposeController(controller, client);
    },
  );

  test(
    'local media source status is independent and clears for a new room',
    () async {
      final client = FakeSyncplayClient();
      final controller = _controllerFor(client);
      await controller.createRoom('room-a', 'alice');

      controller.setLocalMediaStatus(SyncPlayLocalMediaStatus.resolving);
      expect(controller.localMediaStatus, SyncPlayLocalMediaStatus.resolving);
      expect(controller.localMediaError, isNull);
      controller.setLocalMediaStatus(
        SyncPlayLocalMediaStatus.failed,
        error: 'source unavailable',
      );
      expect(controller.localMediaStatus, SyncPlayLocalMediaStatus.failed);
      expect(controller.localMediaError, 'source unavailable');

      controller.beginChatSession('room-b');

      expect(controller.localMediaStatus, SyncPlayLocalMediaStatus.idle);
      expect(controller.localMediaError, isNull);
      await _disposeController(controller, client);
    },
  );

  test('a newer room media selection invalidates the older wait', () async {
    final client = FakeSyncplayClient();
    final controller = _controllerFor(client);
    await controller.createRoom('room-a', 'alice');

    final first = controller.selectRoomMedia(bangumiId: 12345, episode: 9);
    await _settle();
    final second = controller.selectRoomMedia(bangumiId: 12345, episode: 10);
    await _settle();

    client.emitFileChanged(name: '12345[10]', setBy: 'alice');

    expect(await first, isFalse);
    expect(await second, isTrue);
    expect(controller.currentMedia!.episode, 10);
    expect(controller.mediaGeneration, 1);
    await _disposeController(controller, client);
  });

  test('completes a pending room media selection on timeout', () async {
    final client = FakeSyncplayClient();
    final controller = _controllerFor(
      client,
      mediaSelectionTimeout: const Duration(milliseconds: 1),
    );
    await controller.createRoom('room-a', 'alice');

    expect(
      await controller.selectRoomMedia(bangumiId: 12345, episode: 9),
      isFalse,
    );
    expect(controller.currentMedia, isNull);
    expect(controller.localMediaStatus, SyncPlayLocalMediaStatus.idle);
    await _disposeController(controller, client);
  });

  test(
    'completes a pending room media selection when leaving the room',
    () async {
      final client = FakeSyncplayClient();
      final controller = _controllerFor(client);
      await controller.createRoom('room-a', 'alice');
      final selection = controller.selectRoomMedia(
        bangumiId: 12345,
        episode: 9,
      );
      await _settle();

      await controller.exitRoom();

      expect(await selection, isFalse);
      expect(controller.localMediaStatus, SyncPlayLocalMediaStatus.idle);
      expect(controller.localMediaError, isNull);
      await _disposeController(controller, client);
    },
  );

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

  test('attaching to a same-bangumi room media follows its episode', () async {
    final client = FakeSyncplayClient();
    final controller = _controllerFor(client);
    await controller.createRoom('room-a', 'alice');
    client.emitFileChanged(name: '12345[9]', setBy: 'peer');
    client.emitPosition(position: 25, paused: true, doSeek: true);
    await _settle();

    final binding = FakePlaybackBinding(
      bangumiId: 12345,
      currentEpisode: 8,
      playing: true,
    )..episodeChangeGate = Completer<void>();
    controller.attachPlayback(binding);
    await _settle();

    expect(binding.episodeChanges, [9]);
    expect(binding.seekCalls, isEmpty);
    binding.episodeChangeGate!.complete();
    await _settle();

    expect(binding.currentEpisode, 9);
    expect(binding.seekCalls, [const Duration(seconds: 25)]);
    expect(binding.pauseCalls, 1);
    await _disposeController(controller, client);
  });

  test('attaching to a different-bangumi room media only emits a mismatch',
      () async {
    final client = FakeSyncplayClient();
    final controller = _controllerFor(client);
    await controller.createRoom('room-a', 'alice');
    client.emitFileChanged(name: '67890[3]', setBy: 'peer');
    await _settle();

    final events = <SyncPlayRoomMediaEvent>[];
    final subscription = controller.mediaEvents.listen(events.add);
    final binding = FakePlaybackBinding(
      bangumiId: 12345,
      currentEpisode: 9,
    );
    controller.attachPlayback(binding);
    await _settle();

    expect(binding.episodeChanges, isEmpty);
    final mismatches = events.whereType<SyncPlayRoomMediaMismatch>();
    expect(mismatches, hasLength(1));
    expect(mismatches.single.localBangumiId, 12345);
    expect(mismatches.single.localEpisode, 9);
    await subscription.cancel();
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

  test('does not apply room playback state from a different bangumi',
      () async {
    final client = FakeSyncplayClient();
    final controller = _controllerFor(client);
    await controller.createRoom('room-a', 'alice');
    final binding = FakePlaybackBinding(
      bangumiId: 12345,
      currentEpisode: 9,
      playing: true,
    );
    controller.attachPlayback(binding);
    client.emitFileChanged(name: '67890[3]', setBy: 'friend');
    await _settle();

    client.emitPosition(position: 30, paused: true, doSeek: true);
    await _settle();

    expect(controller.currentMedia!.bangumiId, 67890);
    expect(controller.playbackSnapshot, isNotNull);
    expect(binding.seekCalls, isEmpty);
    expect(binding.pauseCalls, 0);
    expect(binding.playCalls, 0);
    await _disposeController(controller, client);
  });

  test('applies a cached snapshot after same-bangumi episode change',
      () async {
    final client = FakeSyncplayClient();
    final controller = _controllerFor(client);
    await controller.createRoom('room-a', 'alice');
    final binding = FakePlaybackBinding(
      bangumiId: 12345,
      currentEpisode: 8,
      playing: true,
    )..episodeChangeGate = Completer<void>();
    controller.attachPlayback(binding);

    client.emitFileChanged(name: '12345[9]', setBy: 'friend');
    await _settle();
    expect(binding.episodeChanges, [9]);

    client.emitPosition(position: 25, paused: true, doSeek: true);
    await _settle();
    expect(binding.seekCalls, isEmpty);
    expect(binding.pauseCalls, 0);

    binding.episodeChangeGate!.complete();
    await _settle();

    expect(binding.currentEpisode, 9);
    expect(binding.seekCalls, [const Duration(seconds: 25)]);
    expect(binding.pauseCalls, 1);
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
