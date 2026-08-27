import 'dart:async';

import 'package:kazumi/services/player/syncplay_client.dart';
import 'package:kazumi/services/player/syncplay_playback_binding.dart';

/// A network-free SyncPlay client for room-session tests.
///
/// The production client is deliberately single-use, so this fake keeps all
/// event streams under test control and records every outbound operation.
class FakeSyncplayClient extends SyncplayClient {
  FakeSyncplayClient({
    this.acceptedUsername = 'server-alice',
    this.acceptedRoom,
  }) : super(host: 'fake.invalid', port: 8996);

  final String acceptedUsername;
  final String? acceptedRoom;

  final StreamController<Map<String, dynamic>> generalMessages =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<Map<String, dynamic>> roomMessages =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<Map<String, dynamic>> chatMessages =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<Map<String, dynamic>> fileChangedMessages =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<Map<String, dynamic>> positionMessages =
      StreamController<Map<String, dynamic>>.broadcast();

  bool connectCalled = false;
  bool connected = false;
  int disconnectCalls = 0;
  int joinCalls = 0;
  String? joinedRoom;
  String? joinedUsername;
  Completer<SyncplayHello>? joinGate;

  final List<String> setPlayingNames = <String>[];
  final List<double> setPlayingDurations = <double>[];
  final List<int> setPlayingSizes = <int>[];
  final List<bool> pausedValues = <bool>[];
  final List<double> positions = <double>[];
  final List<bool?> syncRequests = <bool?>[];
  final List<String> sentChatMessages = <String>[];
  final List<String> operations = <String>[];

  @override
  bool get isConnected => connected;

  @override
  String? get username => acceptedUsername;

  @override
  Stream<Map<String, dynamic>> get onGeneralMessage => generalMessages.stream;

  @override
  Stream<Map<String, dynamic>> get onRoomMessage => roomMessages.stream;

  @override
  Stream<Map<String, dynamic>> get onChatMessage => chatMessages.stream;

  @override
  Stream<Map<String, dynamic>> get onFileChangedMessage =>
      fileChangedMessages.stream;

  @override
  Stream<Map<String, dynamic>> get onPositionChangedMessage =>
      positionMessages.stream;

  @override
  Future<void> connect({required bool enableTLS}) async {
    connectCalled = true;
    connected = true;
  }

  @override
  Future<SyncplayHello> joinRoom(String room, String username) async {
    joinCalls++;
    joinedRoom = room;
    joinedUsername = username;
    final gate = joinGate;
    if (gate != null) {
      return gate.future;
    }
    return SyncplayHello(
      username: acceptedUsername,
      room: acceptedRoom ?? room,
    );
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    connected = false;
  }

  @override
  Future<void> sendChatMessage(String message) async {
    sentChatMessages.add(message);
  }

  @override
  Future<void> setSyncPlayPlaying(
    String bangumiName,
    double duration,
    int size,
  ) async {
    operations.add('setPlaying:$bangumiName');
    setPlayingNames.add(bangumiName);
    setPlayingDurations.add(duration);
    setPlayingSizes.add(size);
  }

  @override
  Future<void> sendSyncPlaySyncRequest({bool? doSeek}) async {
    operations.add('sync:$doSeek');
    syncRequests.add(doSeek);
  }

  @override
  void setPaused(bool paused) {
    operations.add('paused:$paused');
    pausedValues.add(paused);
  }

  @override
  void setPosition(double position) {
    operations.add('position:$position');
    positions.add(position);
  }

  void emitChat({required String username, required String message}) {
    chatMessages.add({'username': username, 'message': message});
  }

  void emitPosition({
    required double position,
    required bool paused,
    bool doSeek = false,
    String setBy = 'peer',
  }) {
    positionMessages.add({
      'calculatedPositon': position,
      'position': position,
      'paused': paused,
      'doSeek': doSeek,
      'setBy': setBy,
    });
  }

  void emitFileChanged({required String name, String setBy = 'peer'}) {
    fileChangedMessages.add({'name': name, 'setBy': setBy});
  }

  void failConnection([Object? error]) {
    generalMessages.addError(
      error ?? SyncplayConnectionException('fake connection lost'),
    );
  }

  Future<void> closeStreams() async {
    await Future.wait<void>([
      generalMessages.close(),
      roomMessages.close(),
      chatMessages.close(),
      fileChangedMessages.close(),
      positionMessages.close(),
    ]);
  }
}

class FakePlaybackBinding implements SyncPlayPlaybackBinding {
  FakePlaybackBinding({
    required this.bangumiId,
    required this.currentEpisode,
    this.currentRoad = 0,
    this.playing = false,
    this.currentPosition = Duration.zero,
    this.playerPosition = Duration.zero,
    this.duration = const Duration(minutes: 20),
  });

  @override
  int bangumiId;

  @override
  int currentEpisode;

  @override
  int currentRoad;

  @override
  bool playing;

  @override
  Duration currentPosition;

  @override
  Duration playerPosition;

  @override
  Duration duration;

  final List<Duration> seekCalls = <Duration>[];
  final List<int> episodeChanges = <int>[];
  int playCalls = 0;
  int pauseCalls = 0;
  int publishCalls = 0;
  Completer<void>? seekGate;
  Completer<void>? episodeChangeGate;

  @override
  Future<void> playFromRoom() async {
    playCalls++;
    playing = true;
  }

  @override
  Future<void> pauseFromRoom() async {
    pauseCalls++;
    playing = false;
  }

  @override
  Future<void> seekFromRoom(Duration position) async {
    seekCalls.add(position);
    final gate = seekGate;
    if (gate != null) {
      await gate.future;
    }
    playerPosition = position;
    currentPosition = position;
  }

  @override
  Future<void> changeEpisodeFromRoom(int episode) async {
    episodeChanges.add(episode);
    final gate = episodeChangeGate;
    if (gate != null) {
      await gate.future;
    }
    currentEpisode = episode;
  }

  @override
  Future<void> publishCurrentMedia({
    bool? forcePlaying,
    double? forcePosition,
  }) async {
    publishCalls++;
  }
}
