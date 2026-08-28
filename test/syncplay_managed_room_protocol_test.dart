import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/player/syncplay_client.dart';
import 'package:kazumi/services/player/syncplay_managed_room_models.dart';

void main() {
  test('advertises managed room capability in Hello', () {
    final message = HelloMessage(
      username: 'alice',
      version: '1.7.0',
      room: 'room-a',
    ).toJson();

    expect(message['Hello']['features']['managedRooms'], isTrue);
  });

  test('parses managed room server features', () {
    final features = SyncplayServerFeatures.fromJson({
      'managedRooms': true,
      'sharedPlaylists': true,
      'chat': true,
      'readiness': true,
      'featureList': true,
    });

    expect(features.managedRooms, isTrue);
    expect(features.sharedPlaylists, isTrue);
    expect(features.chat, isTrue);
    expect(features.readiness, isTrue);
    expect(features.featureList, isTrue);
  });

  test('serializes controller authentication requests', () {
    final message = SyncplayControllerAuthMessage(
      room: '+room-a:ABCDEF123456',
      password: 'AB-123-456',
    ).toJson();

    expect(
      message,
      {
        'Set': {
          'controllerAuth': {
            'room': '+room-a:ABCDEF123456',
            'password': 'AB-123-456',
          },
        },
      },
    );
  });

  test('decodes controlled room creation and authentication results', () {
    final created = SyncplayManagedRoomProtocolDecoder.controlledRoomCreated({
      'roomName': '+room-a:ABCDEF123456',
      'password': 'AB-123-456',
    });
    final auth = SyncplayManagedRoomProtocolDecoder.controllerAuth({
      'user': 'alice',
      'room': '+room-a:ABCDEF123456',
      'success': true,
    });

    expect(created?.roomName, '+room-a:ABCDEF123456');
    expect(created?.password, 'AB-123-456');
    expect(auth?.username, 'alice');
    expect(auth?.room, '+room-a:ABCDEF123456');
    expect(auth?.success, isTrue);
  });

  test('decodes controller flags from List snapshots', () {
    final snapshot = SyncplayManagedRoomProtocolDecoder.userList({
      '+room-a:ABCDEF123456': {
        'alice': {'controller': true, 'file': {}},
        'bob': {'controller': false, 'file': {}},
      },
    });

    expect(snapshot, isNotNull);
    expect(snapshot!.users['alice']?.isController, isTrue);
    expect(snapshot.users['bob']?.isController, isFalse);
  });

  test('recognizes managed room names and generates valid passwords', () {
    const room = '+room-a:ABCDEF123456';
    final password = generateSyncPlayOperatorPassword(Random(1));

    expect(isSyncPlayManagedRoomName(room), isTrue);
    expect(syncPlayManagedRoomBaseName(room), 'room-a');
    expect(isSyncPlayOperatorPasswordValid(password), isTrue);
    expect(normalizeSyncPlayOperatorPassword(' ab-123-456 '), 'AB-123-456');
  });
}
