// ignore_for_file: library_private_types_in_public_api

import 'dart:async';

import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/pages/player/controller/player_models.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/player/syncplay_client.dart';
import 'package:kazumi/services/player/syncplay_endpoint.dart';
import 'package:kazumi/utils/async_session.dart';
import 'package:mobx/mobx.dart';

part 'player_syncplay_controller.g.dart';

class PlayerSyncPlayController = _PlayerSyncPlayController
    with _$PlayerSyncPlayController;

abstract class _PlayerSyncPlayController with Store {
  _PlayerSyncPlayController({
    required this.bangumiId,
    required this.currentEpisode,
    required this.currentRoad,
    required this.playing,
    required this.currentPosition,
    required this.playerPosition,
    required this.duration,
    required this.pause,
    required this.play,
    required this.seek,
  });

  final int Function() bangumiId;
  final int Function() currentEpisode;
  final int Function() currentRoad;
  final bool Function() playing;
  final Duration Function() currentPosition;
  final Duration Function() playerPosition;
  final Duration Function() duration;
  final Future<void> Function({bool enableSync}) pause;
  final Future<void> Function({bool enableSync}) play;
  final Future<void> Function(Duration duration, {bool enableSync}) seek;

  /// Set before the socket opens and cleared on teardown, so unlike
  /// [syncplayRoom] it also covers the window where the connection is still
  /// being established.
  @observable
  SyncplayClient? syncplayController;
  final AsyncSessionOwner _connectionSessions = AsyncSessionOwner();
  @observable
  String syncplayRoom = '';
  @observable
  int syncplayClientRtt = 0;

  bool get hasSession => syncplayController != null;

  final ObservableList<SyncPlayChatMessage> chatMessages =
      ObservableList<SyncPlayChatMessage>();

  @observable
  int unreadChatCount = 0;

  @observable
  bool chatVisible = false;

  @observable
  bool chatDanmakuEnabled = true;

  String _activeChatRoom = '';
  int _nextChatMessageId = 1;

  static const int maxChatMessages = 300;
  static const int maxChatMessageLength = 500;

  int get chatMessageLengthLimit => maxChatMessageLength;

  String get activeChatRoom => _activeChatRoom;

  final StreamController<SyncPlayChatMessage> _chatStreamController =
      StreamController<SyncPlayChatMessage>.broadcast();

  Stream<SyncPlayChatMessage> get chatStream => _chatStreamController.stream;

  void beginChatSession(String room, {bool preserveHistory = false}) {
    final shouldClear = !preserveHistory ||
        (_activeChatRoom.isNotEmpty && _activeChatRoom != room);
    if (shouldClear) {
      clearChatSession();
    }
    _activeChatRoom = room;
  }

  void appendUserMessage({
    required String username,
    required String message,
    bool fromRemote = false,
    DateTime? time,
  }) {
    emitChatMessage(
      username: username,
      message: message,
      fromRemote: fromRemote,
      time: time,
    );
  }

  void appendSystemMessage(String message, {String username = '系统'}) {
    emitChatMessage(
      username: username,
      message: message,
      fromRemote: true,
      type: SyncPlayChatMessageType.system,
    );
  }

  void emitChatMessage({
    required String username,
    required String message,
    required bool fromRemote,
    SyncPlayChatMessageType type = SyncPlayChatMessageType.user,
    DateTime? time,
  }) {
    if (_chatStreamController.isClosed) {
      return;
    }

    final chatMessage = SyncPlayChatMessage(
      id: _nextChatMessageId++,
      username: username,
      message: message,
      fromRemote: fromRemote,
      time: time ?? DateTime.now(),
      type: type,
    );
    chatMessages.add(chatMessage);
    while (chatMessages.length > maxChatMessages) {
      chatMessages.removeAt(0);
    }
    if (type == SyncPlayChatMessageType.user && fromRemote && !chatVisible) {
      unreadChatCount++;
    }
    if (type == SyncPlayChatMessageType.user) {
      _chatStreamController.add(chatMessage);
    }
  }

  void setChatVisible(bool visible) {
    chatVisible = visible;
    if (visible) {
      markChatRead();
    }
  }

  void markChatRead() {
    unreadChatCount = 0;
  }

  void clearChatSession() {
    chatMessages.clear();
    unreadChatCount = 0;
    _activeChatRoom = '';
  }

  void setChatDanmakuEnabled(bool enabled) {
    chatDanmakuEnabled = enabled;
    try {
      unawaited(
        GStorage.putSetting<bool>(
          SettingsKeys.syncPlayChatDanmakuEnabled,
          enabled,
        ).catchError((_) {}),
      );
    } catch (_) {
      // Isolated state tests do not initialize Hive.
    }
  }

  void loadChatDanmakuSetting() {
    try {
      chatDanmakuEnabled =
          GStorage.getSetting<bool>(SettingsKeys.syncPlayChatDanmakuEnabled);
    } catch (_) {
      // The player may be constructed before storage has been initialized.
    }
  }

  Future<void> createRoom(
      String room,
      String username,
      Future<void> Function(int episode, {int currentRoad, int offset})
          changeEpisode,
      {bool preserveChatHistory = false}) async {
    if (_connectionSessions.isClosed) {
      return;
    }
    final session = _connectionSessions.begin();
    final previousClient = syncplayController;
    syncplayController = null;
    syncplayRoom = '';
    syncplayClientRtt = 0;
    beginChatSession(room, preserveHistory: preserveChatHistory);
    if (preserveChatHistory) {
      appendSystemMessage('正在重新连接');
    }
    await previousClient?.disconnect();
    if (session.isStale) {
      return;
    }
    final String syncPlayEndPoint =
        GStorage.getSetting(SettingsKeys.syncPlayEndPoint);
    KazumiLogger().i('SyncPlay: connecting to $syncPlayEndPoint');
    final parsed = parseSyncPlayEndPoint(syncPlayEndPoint);
    if (parsed == null) {
      KazumiDialog.showToast(
        message: 'SyncPlay: 服务器地址不合法 $syncPlayEndPoint',
      );
      KazumiLogger().e('SyncPlay: invalid server address $syncPlayEndPoint');
      return;
    }
    final enableTLS = isOfficialSyncPlayEndPoint(parsed);
    final client = SyncplayClient(host: parsed.host, port: parsed.port);
    syncplayController = client;
    try {
      await client.connect(enableTLS: enableTLS);
      if (!_isCurrentConnection(session, client)) {
        await client.disconnect();
        return;
      }
      KazumiLogger().i('SyncPlay: connected to ${parsed.host}:${parsed.port}');
      client.onGeneralMessage.listen(
        null,
        onError: (error) {
          if (!_isCurrentConnection(session, client)) {
            return;
          }
          final message =
              error is SyncplayException ? error.message : error.toString();
          KazumiLogger().e('SyncPlay: error $message', error: error);
          if (error is SyncplayConnectionException) {
            unawaited(_disconnect(
              clearChatSession: false,
              systemMessage: '连接已中断',
            ));
            KazumiDialog.showToast(
              message: 'SyncPlay: 同步中断 $message',
              duration: const Duration(seconds: 5),
              showActionButton: true,
              actionLabel: '重新连接',
              onActionPressed: () => createRoom(
                room,
                username,
                changeEpisode,
                preserveChatHistory: true,
              ),
            );
          }
        },
      );
      client.onRoomMessage.listen(
        (message) {
          if (!_isCurrentConnection(session, client)) {
            return;
          }
          if (message['type'] == 'init') {
            if (message['username'] == '') {
              KazumiDialog.showToast(
                  message: 'SyncPlay: 您是当前房间中的唯一用户',
                  duration: const Duration(seconds: 5));
              setPlayingBangumi();
            } else {
              KazumiDialog.showToast(
                  message:
                      'SyncPlay: 您不是当前房间中的唯一用户, 当前以用户 ${message['username']} 进度为准');
            }
          }
          if (message['type'] == 'left') {
            appendSystemMessage('${message['username']} 离开了房间');
            KazumiDialog.showToast(
                message: 'SyncPlay: ${message['username']} 离开了房间',
                duration: const Duration(seconds: 5));
          }
          if (message['type'] == 'joined') {
            appendSystemMessage('${message['username']} 加入了房间');
            KazumiDialog.showToast(
                message: 'SyncPlay: ${message['username']} 加入了房间',
                duration: const Duration(seconds: 5));
          }
        },
      );
      client.onFileChangedMessage.listen(
        (message) {
          if (!_isCurrentConnection(session, client)) {
            return;
          }
          KazumiLogger().i(
              'SyncPlay: file changed by ${message['setBy']}: ${message['name']}');
          RegExp regExp = RegExp(r'(\d+)\[(\d+)\]');
          Match? match = regExp.firstMatch(message['name']);
          if (match != null) {
            int bangumiID = int.tryParse(match.group(1) ?? '0') ?? 0;
            int episode = int.tryParse(match.group(2) ?? '0') ?? 0;
            if (bangumiID != 0 && episode != 0 && episode != currentEpisode()) {
              KazumiDialog.showToast(
                  message:
                      'SyncPlay: ${message['setBy'] ?? 'unknown'} 切换到第 $episode 话',
                  duration: const Duration(seconds: 3));
              changeEpisode(episode, currentRoad: currentRoad());
            }
          }
        },
      );
      client.onChatMessage.listen(
        (message) {
          if (!_isCurrentConnection(session, client)) {
            return;
          }
          final String sender = (message['username'] ?? '').toString();
          final String text = (message['message'] ?? '').toString();
          final bool fromRemote = message['username'] != username;

          emitChatMessage(
            username: sender,
            message: text,
            fromRemote: fromRemote,
          );
        },
        onError: (error) {
          if (!_isCurrentConnection(session, client)) {
            return;
          }
          final message =
              error is SyncplayException ? error.message : error.toString();
          KazumiLogger().e('SyncPlay: error $message', error: error);
        },
      );
      client.onPositionChangedMessage.listen(
        (message) {
          if (!_isCurrentConnection(session, client)) {
            return;
          }
          syncplayClientRtt = (message['clientRtt'].toDouble() * 1000).toInt();
          KazumiLogger().i(
              'SyncPlay: position changed by ${message['setBy']}: [${DateTime.now().millisecondsSinceEpoch / 1000.0}] calculatedPosition ${message['calculatedPositon']} position: ${message['position']} doSeek: ${message['doSeek']} paused: ${message['paused']} clientRtt: ${message['clientRtt']} serverRtt: ${message['serverRtt']} fd: ${message['fd']}');
          if (message['paused'] != !playing()) {
            if (message['paused']) {
              if (message['position'] != 0) {
                KazumiDialog.showToast(
                    message: 'SyncPlay: ${message['setBy'] ?? 'unknown'} 暂停了播放',
                    duration: const Duration(seconds: 3));
                pause(enableSync: false);
              }
            } else {
              if (message['position'] != 0) {
                KazumiDialog.showToast(
                    message: 'SyncPlay: ${message['setBy'] ?? 'unknown'} 开始了播放',
                    duration: const Duration(seconds: 3));
                play(enableSync: false);
              }
            }
          }
          if ((((playerPosition().inMilliseconds -
                              (message['calculatedPositon'].toDouble() * 1000)
                                  .toInt())
                          .abs() >
                      1000) ||
                  message['doSeek']) &&
              duration().inMilliseconds > 0) {
            seek(
                Duration(
                    milliseconds:
                        (message['calculatedPositon'].toDouble() * 1000)
                            .toInt()),
                enableSync: false);
          }
        },
      );
      await client.joinRoom(room, username);
      if (!_isCurrentConnection(session, client)) {
        await client.disconnect();
        return;
      }
      syncplayRoom = room;
      if (preserveChatHistory) {
        appendSystemMessage('已重新连接');
      }
    } catch (e) {
      KazumiLogger().e('SyncPlay: error', error: e);
      if (!_isCurrentConnection(session, client)) {
        await client.disconnect();
        return;
      }
      await _disconnect(
        clearChatSession: false,
        client: client,
        systemMessage: '连接已中断',
      );
      final message = e is SyncplayException ? e.message : e.toString();
      KazumiDialog.showToast(
        message: 'SyncPlay: 连接失败 $message',
        duration: const Duration(seconds: 5),
      );
    }
  }

  bool _isCurrentConnection(AsyncSession session, SyncplayClient client) {
    return session.isActive && identical(syncplayController, client);
  }

  void setCurrentPosition({bool? forceSyncPlaying, double? forceSyncPosition}) {
    if (syncplayController == null) {
      return;
    }
    forceSyncPlaying ??= playing();
    syncplayController!.setPaused(!forceSyncPlaying);
    syncplayController!.setPosition((forceSyncPosition ??
        (((currentPosition().inMilliseconds - playerPosition().inMilliseconds)
                    .abs() >
                2000)
            ? currentPosition().inMilliseconds.toDouble() / 1000
            : playerPosition().inMilliseconds.toDouble() / 1000)));
  }

  Future<void> setPlayingBangumi(
      {bool? forceSyncPlaying, double? forceSyncPosition}) async {
    final client = syncplayController;
    if (client == null) {
      return;
    }
    await _runBestEffortSync(() async {
      await client.setSyncPlayPlaying(
          "${bangumiId()}[${currentEpisode()}]", 10800, 220514438);
      if (!identical(syncplayController, client)) {
        return;
      }
      setCurrentPosition(
          forceSyncPlaying: forceSyncPlaying,
          forceSyncPosition: forceSyncPosition);
      await client.sendSyncPlaySyncRequest(doSeek: null);
    });
  }

  Future<void> requestSync({bool? doSeek}) async {
    final client = syncplayController;
    if (client == null) {
      return;
    }
    await _runBestEffortSync(
        () => client.sendSyncPlaySyncRequest(doSeek: doSeek));
  }

  Future<bool> trySendChatMessage(String rawMessage) async {
    final message = rawMessage.trim();
    if (message.isEmpty || message.length > maxChatMessageLength) {
      return false;
    }
    final client = syncplayController;
    if (client == null || syncplayRoom.isEmpty || !client.isConnected) {
      return false;
    }
    try {
      await client.sendChatMessage(message);
      return true;
    } on SyncplayConnectionException {
      return false;
    } catch (error, stackTrace) {
      KazumiLogger().w(
        'SyncPlay: failed to send chat message',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  Future<void> sendChatMessage(String message) async {
    await trySendChatMessage(message);
  }

  Future<void> _runBestEffortSync(Future<void> Function() operation) async {
    try {
      await operation();
    } on SyncplayConnectionException {
      // Socket handlers report active connection failures.
    }
  }

  @action
  Future<void> exitRoom() async {
    await _disconnect(clearChatSession: true);
  }

  Future<void> _disconnect({
    required bool clearChatSession,
    SyncplayClient? client,
    String? systemMessage,
  }) async {
    _connectionSessions.cancel();
    final controller = client ?? syncplayController;
    if (client == null || identical(syncplayController, client)) {
      syncplayController = null;
      syncplayRoom = '';
      syncplayClientRtt = 0;
    }
    if (clearChatSession) {
      this.clearChatSession();
    } else if (systemMessage != null) {
      appendSystemMessage(systemMessage);
    }
    await controller?.disconnect();
  }

  Future<void> dispose() async {
    _connectionSessions.close();
    await exitRoom();
    chatMessages.clear();
    await _chatStreamController.close();
  }
}
