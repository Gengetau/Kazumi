import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/pages/player/controller/player_models.dart';
import 'package:kazumi/pages/player/controller/player_syncplay_controller.dart';
import 'package:kazumi/services/player/syncplay_managed_room_models.dart';

import 'syncplay_test_doubles.dart';

const _managedRoom = '+room-a:ABCDEF123456';
const _features = SyncplayServerFeatures(
  managedRooms: true,
  sharedPlaylists: true,
  chat: true,
  readiness: true,
  featureList: true,
);

PlayerSyncPlayController _controllerFor(List<FakeSyncplayClient> clients) {
  var nextClient = 0;
  return PlayerSyncPlayController(
    endpointProvider: () => 'localhost:8996',
    clientFactory: ({required String host, required int port}) {
      return clients[nextClient++];
    },
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
  Iterable<FakeSyncplayClient> clients,
) async {
  await controller.dispose();
  for (final client in clients) {
    await client.closeStreams();
  }
}

Future<void> _joinManagedRoomAsMember(
  PlayerSyncPlayController controller,
  FakeSyncplayClient client,
) async {
  final join = controller.createRoom(_managedRoom, 'alice');
  await _settleUntil(() => client.userListRequests == 1);
  client.emitUserList(const [
    SyncplayRoomUser(
      username: 'server-alice',
      room: _managedRoom,
      isController: false,
    ),
    SyncplayRoomUser(
      username: 'host',
      room: _managedRoom,
      isController: true,
    ),
  ]);
  await join;
}

void main() {
  test('creates and authenticates a managed room transactionally', () async {
    final client = FakeSyncplayClient(serverFeatures: _features);
    final controller = _controllerFor([client]);

    final creation = controller.createManagedRoom('room-a', 'alice');
    await _settleUntil(() => client.controllerAuthRequests.length == 1);
    final password = client.controllerAuthRequests.first.password;
    client.emitControlledRoomCreated(
      roomName: _managedRoom,
      password: password,
    );
    await _settleUntil(() => client.controllerAuthRequests.length == 2);
    client.emitControllerAuth(
      username: 'server-alice',
      room: _managedRoom,
      success: true,
    );
    await _settleUntil(() => client.userListRequests == 1);
    client.emitUserList(const [
      SyncplayRoomUser(
        username: 'server-alice',
        room: _managedRoom,
        isController: true,
      ),
    ]);

    expect(await creation, isTrue);
    expect(controller.connectionState, SyncPlayConnectionState.connected);
    expect(controller.syncplayRoom, _managedRoom);
    expect(controller.roomControlMode, SyncPlayRoomControlMode.managed);
    expect(controller.isRoomOperator, isTrue);
    expect(controller.operatorPassword, password);
    expect(controller.managedRoomBaseName, 'room-a');
    expect(client.roomChangeRequests, [_managedRoom]);

    await _dispose(controller, [client]);
  });

  test('fails managed room creation when the server lacks support', () async {
    final client = FakeSyncplayClient();
    final controller = _controllerFor([client]);

    expect(await controller.createManagedRoom('room-a', 'alice'), isFalse);
    expect(controller.connectionState, SyncPlayConnectionState.failed);
    expect(client.controllerAuthRequests, isEmpty);
    expect(controller.operatorPassword, isNull);

    await _dispose(controller, [client]);
  });

  test('retrying managed room creation never downgrades to a free room',
      () async {
    final firstClient = FakeSyncplayClient();
    final retryClient = FakeSyncplayClient(serverFeatures: _features);
    final controller = _controllerFor([firstClient, retryClient]);

    expect(await controller.createManagedRoom('room-a', 'alice'), isFalse);
    expect(controller.connectionState, SyncPlayConnectionState.failed);

    final retry = controller.retryConnection();
    await _settleUntil(() => retryClient.controllerAuthRequests.length == 1);
    final password = retryClient.controllerAuthRequests.first.password;
    retryClient.emitControlledRoomCreated(
      roomName: _managedRoom,
      password: password,
    );
    await _settleUntil(() => retryClient.controllerAuthRequests.length == 2);
    retryClient.emitControllerAuth(
      username: 'server-alice',
      room: _managedRoom,
      success: true,
    );
    await _settleUntil(() => retryClient.userListRequests == 1);
    retryClient.emitUserList(const [
      SyncplayRoomUser(
        username: 'server-alice',
        room: _managedRoom,
        isController: true,
      ),
    ]);
    await retry;

    expect(controller.connectionState, SyncPlayConnectionState.connected);
    expect(controller.roomControlMode, SyncPlayRoomControlMode.managed);
    expect(controller.syncplayRoom, _managedRoom);
    expect(controller.isRoomOperator, isTrue);
    expect(retryClient.controllerAuthRequests, hasLength(2));

    await _dispose(controller, [firstClient, retryClient]);
  });

  test('joins a managed room as a normal member', () async {
    final client = FakeSyncplayClient(
      acceptedRoom: _managedRoom,
      serverFeatures: _features,
    );
    final controller = _controllerFor([client]);

    await _joinManagedRoomAsMember(controller, client);

    expect(controller.connectionState, SyncPlayConnectionState.connected);
    expect(controller.isManagedRoom, isTrue);
    expect(controller.isRoomOperator, isFalse);
    expect(controller.hasActiveOperator, isTrue);
    expect(controller.canControlPlayback, isFalse);
    expect(controller.canSelectRoomMedia, isFalse);

    await _dispose(controller, [client]);
  });

  test('authenticates a member as a co-host without reconnecting', () async {
    final client = FakeSyncplayClient(
      acceptedRoom: _managedRoom,
      serverFeatures: _features,
    );
    final controller = _controllerFor([client]);
    await _joinManagedRoomAsMember(controller, client);

    final authentication = controller.authenticateAsOperator('AB-123-456');
    await _settleUntil(() => client.controllerAuthRequests.length == 1);
    client.emitControllerAuth(
      username: 'server-alice',
      room: _managedRoom,
      success: true,
    );
    await _settleUntil(() => client.userListRequests == 2);
    client.emitUserList(const [
      SyncplayRoomUser(
        username: 'server-alice',
        room: _managedRoom,
        isController: true,
      ),
      SyncplayRoomUser(
        username: 'host',
        room: _managedRoom,
        isController: true,
      ),
    ]);

    expect(await authentication, isTrue);
    expect(controller.isRoomOperator, isTrue);
    expect(controller.operatorAuthState, SyncPlayOperatorAuthState.operator);
    expect(controller.operatorPassword, 'AB-123-456');

    await _dispose(controller, [client]);
  });

  test('keeps a member connected after a wrong operator password', () async {
    final client = FakeSyncplayClient(
      acceptedRoom: _managedRoom,
      serverFeatures: _features,
    );
    final controller = _controllerFor([client]);
    await _joinManagedRoomAsMember(controller, client);

    final authentication = controller.authenticateAsOperator('AB-123-456');
    await _settleUntil(() => client.controllerAuthRequests.length == 1);
    client.emitControllerAuth(
      username: 'server-alice',
      room: _managedRoom,
      success: false,
    );

    expect(await authentication, isFalse);
    expect(controller.connectionState, SyncPlayConnectionState.connected);
    expect(controller.isRoomOperator, isFalse);
    expect(controller.operatorAuthState, SyncPlayOperatorAuthState.failed);

    await _dispose(controller, [client]);
  });

  test('does not promote another member when the last host leaves', () async {
    final client = FakeSyncplayClient(
      acceptedRoom: _managedRoom,
      serverFeatures: _features,
    );
    final controller = _controllerFor([client]);
    await _joinManagedRoomAsMember(controller, client);

    client.roomMessages.add({'type': 'left', 'username': 'host'});
    await _settleUntil(() => !controller.roomUsers.containsKey('host'));

    expect(controller.hasActiveOperator, isFalse);
    expect(controller.isRoomOperator, isFalse);
    expect(controller.canControlPlayback, isFalse);

    await _dispose(controller, [client]);
  });

  test('accepts managed room media only from confirmed operators', () async {
    final client = FakeSyncplayClient(
      acceptedRoom: _managedRoom,
      serverFeatures: _features,
    );
    final controller = _controllerFor([client]);
    await _joinManagedRoomAsMember(controller, client);

    client.emitFileChanged(
      name: '12345[2]',
      setBy: 'server-alice',
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.currentMedia, isNull);

    client.emitFileChanged(name: '12345[3]', setBy: 'host');
    await _settleUntil(() => controller.currentMedia != null);

    expect(controller.currentMedia?.bangumiId, 12345);
    expect(controller.currentMedia?.episode, 3);
    expect(controller.currentMedia?.selectedBy, 'host');

    await _dispose(controller, [client]);
  });

  test('queues managed media until the sender role is confirmed', () async {
    final client = FakeSyncplayClient(
      acceptedRoom: _managedRoom,
      serverFeatures: _features,
    );
    final controller = _controllerFor([client]);
    await _joinManagedRoomAsMember(controller, client);

    client.emitFileChanged(name: '67890[4]', setBy: 'new-host');
    await Future<void>.delayed(Duration.zero);
    expect(controller.currentMedia, isNull);

    client.emitControllerAuth(
      username: 'new-host',
      room: _managedRoom,
      success: true,
    );
    await _settleUntil(() => controller.currentMedia != null);

    expect(controller.roomUsers['new-host']?.isController, isTrue);
    expect(controller.currentMedia?.bangumiId, 67890);
    expect(controller.currentMedia?.episode, 4);

    await _dispose(controller, [client]);
  });

  test('managed followers cannot publish playback or room media', () async {
    final client = FakeSyncplayClient(
      acceptedRoom: _managedRoom,
      serverFeatures: _features,
    );
    final controller = _controllerFor([client]);
    await _joinManagedRoomAsMember(controller, client);
    client.emitFileChanged(name: '12345[3]', setBy: 'host');
    await _settleUntil(() => controller.currentMedia != null);
    final binding = FakePlaybackBinding(
      bangumiId: 12345,
      currentEpisode: 3,
      playing: false,
    );
    controller.attachPlayback(binding);
    await Future<void>.delayed(Duration.zero);

    expect(
      controller.playbackParticipation,
      SyncPlayPlaybackParticipation.followingRoom,
    );
    expect(controller.canControlLocalPlayback, isFalse);
    expect(controller.canChangePlaybackSpeed, isFalse);
    expect(controller.shouldBroadcastLocalPlayback, isFalse);

    await controller.requestSync(doSeek: true);
    final selected = await controller.selectRoomMedia(
      bangumiId: 12345,
      episode: 4,
    );

    expect(client.syncRequests, isEmpty);
    expect(client.setPlayingNames, isEmpty);
    expect(selected, isFalse);

    await _dispose(controller, [client]);
  });

  test('local-only managed playback remains local for operators', () async {
    final client = FakeSyncplayClient(
      acceptedRoom: _managedRoom,
      serverFeatures: _features,
    );
    final controller = _controllerFor([client]);
    await _joinManagedRoomAsMember(controller, client);

    final authentication = controller.authenticateAsOperator('AB-123-456');
    await _settleUntil(() => client.controllerAuthRequests.length == 1);
    client.emitControllerAuth(
      username: 'server-alice',
      room: _managedRoom,
      success: true,
    );
    await _settleUntil(() => client.userListRequests == 2);
    client.emitUserList(const [
      SyncplayRoomUser(
        username: 'server-alice',
        room: _managedRoom,
        isController: true,
      ),
    ]);
    expect(await authentication, isTrue);

    client.emitFileChanged(name: '12345[3]', setBy: 'server-alice');
    await _settleUntil(() => controller.currentMedia != null);
    controller.attachPlayback(
      FakePlaybackBinding(bangumiId: 67890, currentEpisode: 1),
    );
    await Future<void>.delayed(Duration.zero);

    expect(
      controller.playbackParticipation,
      SyncPlayPlaybackParticipation.localOnly,
    );
    expect(controller.canControlLocalPlayback, isTrue);
    expect(controller.canChangePlaybackSpeed, isTrue);
    expect(controller.shouldBroadcastLocalPlayback, isFalse);

    await controller.requestSync(doSeek: true);
    expect(client.syncRequests, isEmpty);

    await _dispose(controller, [client]);
  });

  test('managed room invitations never expose the operator password', () async {
    final client = FakeSyncplayClient(
      acceptedRoom: _managedRoom,
      serverFeatures: _features,
    );
    final controller = _controllerFor([client]);
    await _joinManagedRoomAsMember(controller, client);

    final authentication = controller.authenticateAsOperator('AB-123-456');
    await _settleUntil(() => client.controllerAuthRequests.length == 1);
    client.emitControllerAuth(
      username: 'server-alice',
      room: _managedRoom,
      success: true,
    );
    await _settleUntil(() => client.userListRequests == 2);
    client.emitUserList(const [
      SyncplayRoomUser(
        username: 'server-alice',
        room: _managedRoom,
        isController: true,
      ),
    ]);
    expect(await authentication, isTrue);

    final invite = controller.syncPlayInviteText();
    expect(invite, contains(_managedRoom));
    expect(invite, isNot(contains('AB-123-456')));

    await _dispose(controller, [client]);
  });

  test('restores operator authentication after reconnect', () async {
    final first = FakeSyncplayClient(
      acceptedRoom: _managedRoom,
      serverFeatures: _features,
    );
    final second = FakeSyncplayClient(
      acceptedRoom: _managedRoom,
      serverFeatures: _features,
    );
    final controller = _controllerFor([first, second]);
    await _joinManagedRoomAsMember(controller, first);

    final authentication = controller.authenticateAsOperator('AB-123-456');
    await _settleUntil(() => first.controllerAuthRequests.length == 1);
    first.emitControllerAuth(
      username: 'server-alice',
      room: _managedRoom,
      success: true,
    );
    await _settleUntil(() => first.userListRequests == 2);
    first.emitUserList(const [
      SyncplayRoomUser(
        username: 'server-alice',
        room: _managedRoom,
        isController: true,
      ),
    ]);
    expect(await authentication, isTrue);

    first.failConnection();
    await _settleUntil(() => second.controllerAuthRequests.length == 1);
    second.emitControllerAuth(
      username: 'server-alice',
      room: _managedRoom,
      success: true,
    );
    await _settleUntil(() => second.userListRequests == 1);
    second.emitUserList(const [
      SyncplayRoomUser(
        username: 'server-alice',
        room: _managedRoom,
        isController: true,
      ),
    ]);
    await _settleUntil(
      () => controller.connectionState == SyncPlayConnectionState.connected,
    );

    expect(controller.syncplayController, same(second));
    expect(controller.isRoomOperator, isTrue);
    expect(controller.operatorPassword, 'AB-123-456');

    await _dispose(controller, [first, second]);
  });

  test('explicit exit clears the in-memory operator password', () async {
    final client = FakeSyncplayClient(
      acceptedRoom: _managedRoom,
      serverFeatures: _features,
    );
    final controller = _controllerFor([client]);
    await _joinManagedRoomAsMember(controller, client);

    final authentication = controller.authenticateAsOperator('AB-123-456');
    await _settleUntil(() => client.controllerAuthRequests.length == 1);
    client.emitControllerAuth(
      username: 'server-alice',
      room: _managedRoom,
      success: true,
    );
    await _settleUntil(() => client.userListRequests == 2);
    client.emitUserList(const [
      SyncplayRoomUser(
        username: 'server-alice',
        room: _managedRoom,
        isController: true,
      ),
    ]);
    expect(await authentication, isTrue);

    await controller.exitRoom();

    expect(controller.operatorPassword, isNull);
    expect(controller.roomUsers, isEmpty);
    expect(controller.roomControlMode, SyncPlayRoomControlMode.free);

    await _dispose(controller, [client]);
  });
}
