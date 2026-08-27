import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/pages/player/controller/player_models.dart';
import 'package:kazumi/pages/player/controller/player_syncplay_controller.dart';
import 'package:kazumi/services/player/syncplay_client.dart';
import 'package:kazumi/services/player/syncplay_room_models.dart';
import 'package:kazumi/services/player/syncplay_room_session_controller.dart';

import 'syncplay_test_doubles.dart';

Future<void> _settle([int turns = 5]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

PlayerSyncPlayController _controllerFor(
  List<FakeSyncplayClient> clients,
) {
  var nextClient = 0;
  return PlayerSyncPlayController(
    endpointProvider: () => 'localhost:8996',
    clientFactory: ({required String host, required int port}) {
      final index =
          nextClient < clients.length ? nextClient++ : clients.length - 1;
      return clients[index];
    },
  );
}

Future<void> _disposeController(
  PlayerSyncPlayController controller,
  Iterable<FakeSyncplayClient> clients,
) async {
  await controller.dispose();
  for (final client in clients) {
    await client.closeStreams();
  }
}

void main() {
  test('the concrete room session is a Modular Disposable', () async {
    final controller = SyncPlayRoomSessionController();

    expect(controller, isA<Disposable>());
    await controller.dispose();
  });

  test('chat readiness prompts once until its page budget resets', () async {
    final controller = SyncPlayRoomSessionController();
    var prompts = 0;
    Future<void> prompt() async => prompts++;

    expect(await controller.ensureSyncPlayChatReady(promptJoin: prompt), isFalse);
    expect(await controller.ensureSyncPlayChatReady(promptJoin: prompt), isFalse);
    expect(prompts, 1);
    controller.resetSyncPlayChatEntryPrompt();
    expect(await controller.ensureSyncPlayChatReady(promptJoin: prompt), isFalse);
    expect(prompts, 2);
    await controller.dispose();
  });

  test('deduplicates protocol-confirmed remote playback notices', () async {
    final client = FakeSyncplayClient(acceptedUsername: 'alice');
    final controller = _controllerFor([client]);
    await controller.createRoom('room-a', 'alice');

    client.emitPosition(position: 10, paused: false, setBy: 'friend');
    await _settle();
    client.emitPosition(position: 10, paused: true, setBy: 'friend');
    client.emitPosition(position: 10, paused: true, setBy: 'friend');
    client.emitPosition(
      position: 40,
      paused: true,
      doSeek: true,
      setBy: 'friend',
    );
    await _settle();

    final notices = controller.chatMessages
        .where((message) => message.message == 'friend 已暂停播放');
    expect(notices, hasLength(1));
    await _disposeController(controller, [client]);
  });

  test('connects a room without a playback binding', () async {
    final client = FakeSyncplayClient();
    final controller = _controllerFor([client]);

    await controller.createRoom('room-a', 'requested-name');

    expect(client.connectCalled, isTrue);
    expect(client.joinCalls, 1);
    expect(client.joinedRoom, 'room-a');
    expect(client.joinedUsername, 'requested-name');
    expect(client.connected, isTrue);
    expect(controller.connectionState, SyncPlayConnectionState.connected);
    expect(controller.syncplayRoom, 'room-a');
    expect(controller.activeChatRoom, 'room-a');
    expect(controller.hasPlaybackBinding, isFalse);

    await _disposeController(controller, [client]);
  });

  test('attaching a player applies the latest remote playback snapshot',
      () async {
    final client = FakeSyncplayClient();
    final controller = _controllerFor([client]);
    await controller.createRoom('room-a', 'alice');

    client.emitPosition(
      position: 42,
      paused: true,
      doSeek: true,
      setBy: 'peer',
    );
    await _settle();

    final binding = FakePlaybackBinding(
      bangumiId: 12345,
      currentEpisode: 9,
      playing: true,
    );
    controller.attachPlayback(binding);
    await _settle();

    expect(controller.playbackSnapshot, isA<SyncPlayRoomPlaybackSnapshot>());
    expect(controller.playbackSnapshot!.paused, isTrue);
    expect(controller.playbackSnapshot!.position, const Duration(seconds: 42));
    expect(binding.seekCalls, [const Duration(seconds: 42)]);
    expect(binding.pauseCalls, 1);
    expect(binding.playCalls, 0);

    await _disposeController(controller, [client]);
  });

  test('detaching a player stops an in-flight remote callback', () async {
    final client = FakeSyncplayClient();
    final controller = _controllerFor([client]);
    await controller.createRoom('room-a', 'alice');
    final binding = FakePlaybackBinding(
      bangumiId: 12345,
      currentEpisode: 9,
    )..seekGate = Completer<void>();
    final attachment = controller.attachPlayback(binding);

    client.emitPosition(
      position: 12,
      paused: true,
      doSeek: true,
    );
    await _settle();
    expect(binding.seekCalls, hasLength(1));

    controller.detachPlayback(attachment);
    binding.seekGate!.complete();
    await _settle();

    expect(binding.pauseCalls, 0);
    expect(controller.hasPlaybackBinding, isFalse);
    await _disposeController(controller, [client]);
  });

  test('a stale attachment cannot detach its replacement', () async {
    final client = FakeSyncplayClient();
    final controller = _controllerFor([client]);
    await controller.createRoom('room-a', 'alice');
    final oldBinding = FakePlaybackBinding(bangumiId: 12345, currentEpisode: 9);
    final newBinding = FakePlaybackBinding(bangumiId: 12345, currentEpisode: 9);
    final oldAttachment = controller.attachPlayback(oldBinding);
    final newAttachment = controller.attachPlayback(newBinding);

    controller.detachPlayback(oldAttachment);

    expect(controller.playbackBinding, same(newBinding));
    expect(controller.playbackBindingGeneration, newAttachment.generation);
    controller.detachPlayback(newAttachment);
    expect(controller.hasPlaybackBinding, isFalse);
    await _disposeController(controller, [client]);
  });

  test('detaching the player leaves the room session alive', () async {
    final client = FakeSyncplayClient();
    final controller = _controllerFor([client]);
    await controller.createRoom('room-a', 'alice');
    final attachment = controller.attachPlayback(
      FakePlaybackBinding(bangumiId: 12345, currentEpisode: 9),
    );

    // PlayerController.dispose() uses this detach seam and must not own the
    // app-scoped room session or disconnect its client.
    controller.detachPlayback(attachment);

    expect(controller.connectionState, SyncPlayConnectionState.connected);
    expect(controller.syncplayRoom, 'room-a');
    expect(client.connected, isTrue);
    expect(client.disconnectCalls, 0);
    await _disposeController(controller, [client]);
  });

  test('explicit exit clears the connection, media and chat state', () async {
    final client = FakeSyncplayClient();
    final controller = _controllerFor([client]);
    await controller.createRoom('room-a', 'alice');
    controller.appendUserMessage(
      username: 'peer',
      message: 'hello',
      fromRemote: true,
    );
    client.emitFileChanged(name: '12345[9]');
    client.emitPosition(position: 10, paused: false);
    await _settle();

    expect(controller.currentMedia, isNotNull);
    expect(controller.playbackSnapshot, isNotNull);
    expect(controller.chatMessages, isNotEmpty);

    await controller.exitRoom();

    expect(client.connected, isFalse);
    expect(client.disconnectCalls, 1);
    expect(controller.syncplayController, isNull);
    expect(controller.syncplayRoom, isEmpty);
    expect(controller.activeChatRoom, isEmpty);
    expect(controller.connectionState, SyncPlayConnectionState.disconnected);
    expect(controller.currentMedia, isNull);
    expect(controller.playbackSnapshot, isNull);
    expect(controller.chatMessages, isEmpty);
    expect(controller.unreadChatCount, 0);

    await _disposeController(controller, [client]);
  });

  test('a binding replacement during reconnect cannot call the old binding',
      () async {
    final firstClient = FakeSyncplayClient();
    final secondClient = FakeSyncplayClient(acceptedUsername: 'server-bob');
    secondClient.joinGate = Completer<SyncplayHello>();
    final controller = _controllerFor([firstClient, secondClient]);
    await controller.createRoom('room-a', 'alice');

    final oldBinding = FakePlaybackBinding(
      bangumiId: 12345,
      currentEpisode: 9,
    )..seekGate = Completer<void>();
    final oldAttachment = controller.attachPlayback(oldBinding);
    firstClient.emitPosition(position: 20, paused: true, doSeek: true);
    await _settle();
    expect(oldBinding.seekCalls, hasLength(1));

    firstClient.failConnection();
    await _settle(8);
    expect(controller.connectionState, SyncPlayConnectionState.reconnecting);
    expect(secondClient.connectCalled, isTrue);
    expect(secondClient.joinCalls, 1);

    final newBinding = FakePlaybackBinding(
      bangumiId: 12345,
      currentEpisode: 9,
    );
    final newAttachment = controller.attachPlayback(newBinding);
    controller.detachPlayback(oldAttachment);
    oldBinding.seekGate!.complete();
    await _settle();

    expect(controller.playbackBinding, same(newBinding));
    expect(controller.playbackBindingGeneration, newAttachment.generation);
    expect(oldBinding.pauseCalls, 0);

    secondClient.joinGate!.complete(
      const SyncplayHello(username: 'server-bob', room: 'room-a'),
    );
    await _settle(8);
    expect(controller.connectionState, SyncPlayConnectionState.connected);
    expect(controller.syncplayRoom, 'room-a');
    expect(controller.confirmedUsername, 'server-bob');

    await _disposeController(controller, [firstClient, secondClient]);
  });

  test('chat echoes use the server-confirmed identity and unread count',
      () async {
    final client = FakeSyncplayClient(acceptedUsername: 'server-alice');
    final controller = _controllerFor([client]);
    await controller.createRoom('room-a', 'requested-alice');
    final events = <SyncPlayChatMessage>[];
    final subscription = controller.chatStream.listen(events.add);

    client.emitChat(username: 'server-alice', message: 'my echo');
    client.emitChat(username: 'friend', message: 'hello');
    await _settle();

    expect(events, hasLength(2));
    expect(events.first.fromRemote, isFalse);
    expect(events.last.fromRemote, isTrue);
    expect(controller.unreadChatCount, 1);
    expect(await controller.trySendChatMessage('  outgoing  '), isTrue);
    expect(client.sentChatMessages, ['outgoing']);

    await subscription.cancel();
    await _disposeController(controller, [client]);
  });

  test('publishes play, pause and seek state through the room client',
      () async {
    final client = FakeSyncplayClient();
    final controller = _controllerFor([client]);
    await controller.createRoom('room-a', 'alice');
    final binding = FakePlaybackBinding(
      bangumiId: 12345,
      currentEpisode: 9,
    );
    controller.attachPlayback(binding);

    await controller.setPlayingBangumi(
      forceSyncPlaying: true,
      forceSyncPosition: 4.5,
    );
    controller.setCurrentPosition(
      forceSyncPlaying: false,
      forceSyncPosition: 8,
    );
    await controller.requestSync(doSeek: true);

    expect(client.setPlayingNames, ['12345[9]']);
    expect(client.pausedValues, [false, true]);
    expect(client.positions, [4.5, 8]);
    expect(client.syncRequests, [null, true]);

    await _disposeController(controller, [client]);
  });

  test(
    'keeps chat visibility when one of several surfaces is removed',
    () async {
      final controller = PlayerSyncPlayController();
      final firstSurface = controller.registerChatSurface();
      final secondSurface = controller.registerChatSurface();

      controller.setChatSurfaceVisible(firstSurface, true);
      controller.setChatSurfaceVisible(secondSurface, true);
      controller.unregisterChatSurface(firstSurface);
      expect(controller.chatVisible, isTrue);

      controller.unregisterChatSurface(secondSurface);
      expect(controller.chatVisible, isFalse);
      await controller.dispose();
    },
  );

  test('does not write to room streams after session disposal', () async {
    final client = FakeSyncplayClient();
    final controller = _controllerFor([client]);
    await controller.createRoom('room-a', 'alice');
    final events = <SyncPlayRoomMediaEvent>[];
    final subscription = controller.mediaEvents.listen(events.add);

    await controller.dispose();
    client.emitFileChanged(name: '12345[9]');
    client.emitPosition(position: 10, paused: false);
    client.emitChat(username: 'friend', message: 'late');
    await _settle();

    expect(events, isEmpty);
    expect(controller.currentMedia, isNull);
    expect(controller.chatMessages, isEmpty);
    await subscription.cancel();
    await client.closeStreams();
  });
}
