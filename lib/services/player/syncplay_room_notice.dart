import 'package:kazumi/services/player/syncplay_room_models.dart';

/// UI-neutral events emitted by the room session.
sealed class SyncPlayRoomNotice {
  const SyncPlayRoomNotice();
}

final class SyncPlayRoomConnectionFailed extends SyncPlayRoomNotice {
  final String message;

  const SyncPlayRoomConnectionFailed(this.message);
}

final class SyncPlayRoomReconnecting extends SyncPlayRoomNotice {
  const SyncPlayRoomReconnecting();
}

final class SyncPlayRoomReconnected extends SyncPlayRoomNotice {
  const SyncPlayRoomReconnected();
}

final class SyncPlayRoomRemoteMediaChanged extends SyncPlayRoomNotice {
  final SyncPlayRoomMedia media;

  const SyncPlayRoomRemoteMediaChanged(this.media);
}

final class SyncPlayRoomInitialSync extends SyncPlayRoomNotice {
  /// Empty when the local member is the first member in the room.
  final String username;

  const SyncPlayRoomInitialSync(this.username);
}
