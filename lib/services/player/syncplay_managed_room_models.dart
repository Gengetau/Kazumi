import 'dart:math';

/// The room-control behavior exposed by Kazumi.
enum SyncPlayRoomControlMode {
  free,
  managed,
}

/// The local user's authentication state inside a managed room.
enum SyncPlayOperatorAuthState {
  none,
  authenticating,
  operator,
  failed,
}

/// Managed-room capabilities advertised by a SyncPlay server.
final class SyncplayServerFeatures {
  final bool managedRooms;
  final bool sharedPlaylists;
  final bool chat;
  final bool readiness;
  final bool featureList;

  const SyncplayServerFeatures({
    this.managedRooms = false,
    this.sharedPlaylists = false,
    this.chat = false,
    this.readiness = false,
    this.featureList = false,
  });

  factory SyncplayServerFeatures.fromJson(Object? value) {
    if (value is! Map) {
      return const SyncplayServerFeatures();
    }
    bool read(String key) => value[key] == true;
    return SyncplayServerFeatures(
      managedRooms: read('managedRooms'),
      sharedPlaylists: read('sharedPlaylists'),
      chat: read('chat'),
      readiness: read('readiness'),
      featureList: read('featureList'),
    );
  }
}

final class SyncplayControlledRoomCreated {
  final String roomName;
  final String password;

  const SyncplayControlledRoomCreated({
    required this.roomName,
    required this.password,
  });
}

final class SyncplayControllerAuthResult {
  final String username;
  final String room;
  final bool success;

  const SyncplayControllerAuthResult({
    required this.username,
    required this.room,
    required this.success,
  });
}

final class SyncplayRoomUser {
  final String username;
  final String room;
  final bool isController;

  const SyncplayRoomUser({
    required this.username,
    required this.room,
    required this.isController,
  });

  SyncplayRoomUser copyWith({
    String? username,
    String? room,
    bool? isController,
  }) {
    return SyncplayRoomUser(
      username: username ?? this.username,
      room: room ?? this.room,
      isController: isController ?? this.isController,
    );
  }
}

final class SyncplayUserListSnapshot {
  final Map<String, SyncplayRoomUser> users;

  const SyncplayUserListSnapshot(this.users);
}

final class SyncplayManagedRoomProtocolDecoder {
  const SyncplayManagedRoomProtocolDecoder._();

  static SyncplayControlledRoomCreated? controlledRoomCreated(Object? value) {
    if (value is! Map) {
      return null;
    }
    final roomName = value['roomName']?.toString() ?? '';
    final password = value['password']?.toString() ?? '';
    if (roomName.isEmpty || password.isEmpty) {
      return null;
    }
    return SyncplayControlledRoomCreated(
      roomName: roomName,
      password: password,
    );
  }

  static SyncplayControllerAuthResult? controllerAuth(Object? value) {
    if (value is! Map) {
      return null;
    }
    final username = value['user']?.toString() ?? '';
    final room = value['room']?.toString() ?? '';
    if (username.isEmpty || room.isEmpty || value['success'] is! bool) {
      return null;
    }
    return SyncplayControllerAuthResult(
      username: username,
      room: room,
      success: value['success'] == true,
    );
  }

  static String? roomChanged(Object? value) {
    if (value is! Map) {
      return null;
    }
    final room = value['name']?.toString().trim() ?? '';
    return room.isEmpty ? null : room;
  }

  static SyncplayUserListSnapshot? userList(Object? value) {
    if (value is! Map) {
      return null;
    }
    final users = <String, SyncplayRoomUser>{};
    for (final roomEntry in value.entries) {
      final room = roomEntry.key.toString();
      final roomUsers = roomEntry.value;
      if (room.isEmpty || roomUsers is! Map) {
        continue;
      }
      for (final userEntry in roomUsers.entries) {
        final username = userEntry.key.toString();
        final details = userEntry.value;
        if (username.isEmpty || details is! Map) {
          continue;
        }
        users[username] = SyncplayRoomUser(
          username: username,
          room: room,
          isController: details['controller'] == true,
        );
      }
    }
    return SyncplayUserListSnapshot(users);
  }
}

final RegExp _managedRoomPattern = RegExp(r'^\+(.*):([A-Za-z0-9_]{12})$');
final RegExp _operatorPasswordPattern = RegExp(r'^[A-Z]{2}-\d{3}-\d{3}$');

bool isSyncPlayManagedRoomName(String roomName) {
  return _managedRoomPattern.hasMatch(roomName.trim());
}

String? syncPlayManagedRoomBaseName(String roomName) {
  return _managedRoomPattern.firstMatch(roomName.trim())?.group(1);
}

String normalizeSyncPlayOperatorPassword(String value) {
  return value.replaceAll(RegExp(r'[^a-zA-Z0-9\-]'), '').toUpperCase();
}

bool isSyncPlayOperatorPasswordValid(String value) {
  return _operatorPasswordPattern
      .hasMatch(normalizeSyncPlayOperatorPassword(value));
}

String generateSyncPlayOperatorPassword([Random? random]) {
  final source = random ?? Random.secure();
  const letters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  String letter() => letters[source.nextInt(letters.length)];
  String digits() => source.nextInt(1000).toString().padLeft(3, '0');
  return '${letter()}${letter()}-${digits()}-${digits()}';
}
