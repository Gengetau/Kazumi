// ignore_for_file: library_private_types_in_public_api

import 'dart:async';

import 'package:kazumi/pages/player/controller/player_models.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/player/syncplay_client.dart';
import 'package:kazumi/services/player/syncplay_endpoint.dart';
import 'package:kazumi/services/player/syncplay_media_codec.dart';
import 'package:kazumi/services/player/syncplay_playback_binding.dart';
import 'package:kazumi/services/player/syncplay_room_models.dart';
import 'package:kazumi/services/player/syncplay_room_notice.dart';
import 'package:kazumi/utils/async_session.dart';
import 'package:mobx/mobx.dart';

part 'player_syncplay_controller.g.dart';

typedef SyncplayClientFactory = SyncplayClient Function({
  required String host,
  required int port,
});

class PlayerSyncPlayController = _PlayerSyncPlayController
    with _$PlayerSyncPlayController;

abstract class _PlayerSyncPlayController with Store {
  _PlayerSyncPlayController({SyncplayClientFactory? clientFactory})
      : _clientFactory = clientFactory ??
            ({required String host, required int port}) =>
                SyncplayClient(host: host, port: port);

  final SyncplayClientFactory _clientFactory;

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

  @observable
  SyncPlayConnectionState connectionState =
      SyncPlayConnectionState.disconnected;

  bool get hasSession => syncplayController != null;

  SyncPlayPlaybackBinding? _playbackBinding;
  int _playbackBindingGeneration = 0;

  /// The current binding generation. Primarily useful for diagnostics and
  /// tests; callers must use [SyncPlayPlaybackAttachment] for detach.
  int get playbackBindingGeneration => _playbackBindingGeneration;

  bool get hasPlaybackBinding => _playbackBinding != null;

  SyncPlayPlaybackBinding? get playbackBinding => _playbackBinding;

  SyncPlayPlaybackAttachment attachPlayback(SyncPlayPlaybackBinding binding) {
    final attachment = SyncPlayPlaybackAttachment(
      generation: ++_playbackBindingGeneration,
      binding: binding,
    );
    _playbackBinding = binding;
    unawaited(_restorePlaybackAttachment(attachment));
    return attachment;
  }

  void detachPlayback(SyncPlayPlaybackAttachment attachment) {
    if (attachment.generation != _playbackBindingGeneration ||
        !identical(attachment.binding, _playbackBinding)) {
      return;
    }
    _playbackBinding = null;
  }

  bool _isCurrentPlayback(SyncPlayPlaybackAttachment attachment) {
    return attachment.generation == _playbackBindingGeneration &&
        identical(attachment.binding, _playbackBinding);
  }

  SyncPlayRoomPlaybackSnapshot? _playbackSnapshot;

  SyncPlayRoomPlaybackSnapshot? get playbackSnapshot => _playbackSnapshot;

  SyncPlayRoomPlaybackSnapshot? get roomPlaybackSnapshot => _playbackSnapshot;

  @observable
  SyncPlayRoomMedia? currentMedia;

  int _mediaGeneration = 0;

  int get mediaGeneration => _mediaGeneration;

  final ObservableList<SyncPlayChatMessage> chatMessages =
      ObservableList<SyncPlayChatMessage>();

  @observable
  int unreadChatCount = 0;

  @observable
  int unreadMentionCount = 0;

  @observable
  bool chatVisible = false;

  @observable
  bool appForeground = true;

  @observable
  bool windowFocused = true;
  final Set<Object> _chatSurfaces = <Object>{};
  final Set<Object> _visibleChatSurfaces = <Object>{};
  final Object _legacyChatSurfaceToken = Object();

  @observable
  bool chatDanmakuEnabled = true;

  final ObservableSet<String> mutedChatUsers = ObservableSet<String>();

  String _activeChatRoom = '';
  String _requestedChatRoom = '';
  String _requestedUsername = '';
  bool _connectionLossHandled = false;
  Future<void>? _retryFuture;
  int _nextChatMessageId = 1;
  final Set<int> _unreadChatMessageIds = <int>{};
  final Set<int> _unreadMentionMessageIds = <int>{};

  static const int maxChatMessages = 300;
  static const int maxChatMessageLength = 500;

  int get chatMessageLengthLimit => maxChatMessageLength;

  String get activeChatRoom => _activeChatRoom;

  /// The username accepted by the server for the current socket.
  ///
  /// This intentionally does not fall back to the username entered in the
  /// room sheet. Until Hello arrives there is no local identity to compare
  /// against incoming chat messages.
  String get confirmedUsername {
    final username = syncplayController?.username;
    return isSyncPlayUsernameValid(username)
        ? normalizeSyncPlayUsername(username)
        : '';
  }

  bool get isChatConnected =>
      syncplayController != null &&
      syncplayRoom.isNotEmpty &&
      (connectionState == SyncPlayConnectionState.connected ||
          // A manually assembled controller is useful in isolated widget
          // tests; a real connection always transitions through connecting.
          connectionState == SyncPlayConnectionState.disconnected);

  final StreamController<SyncPlayChatMessage> _chatStreamController =
      StreamController<SyncPlayChatMessage>.broadcast();

  Stream<SyncPlayChatMessage> get chatStream => _chatStreamController.stream;

  final StreamController<SyncPlayRoomMediaEvent>
      _mediaEventStreamController =
      StreamController<SyncPlayRoomMediaEvent>.broadcast();

  Stream<SyncPlayRoomMediaEvent> get mediaEvents =>
      _mediaEventStreamController.stream;

  final StreamController<SyncPlayRoomNotice> _noticeStreamController =
      StreamController<SyncPlayRoomNotice>.broadcast();

  Stream<SyncPlayRoomNotice> get notices => _noticeStreamController.stream;

  Future<void> _restorePlaybackAttachment(
    SyncPlayPlaybackAttachment attachment,
  ) async {
    if (!_isCurrentPlayback(attachment)) {
      return;
    }
    final binding = attachment.binding;
    final media = currentMedia;
    if (media != null) {
      if (media.bangumiId != binding.bangumiId) {
        _emitMediaEvent(
          SyncPlayRoomMediaMismatch(
            roomMedia: media,
            localBangumiId: binding.bangumiId,
          ),
        );
      } else if (media.episode != binding.currentEpisode) {
        await binding.changeEpisodeFromRoom(media.episode);
        if (!_isCurrentPlayback(attachment)) {
          return;
        }
      }
    }

    final snapshot = _playbackSnapshot;
    if (snapshot == null || !_isCurrentPlayback(attachment)) {
      return;
    }
    await _applyPlaybackSnapshot(attachment, snapshot);
  }

  Future<void> _applyPlaybackSnapshot(
    SyncPlayPlaybackAttachment attachment,
    SyncPlayRoomPlaybackSnapshot snapshot,
  ) async {
    if (!_isCurrentPlayback(attachment)) {
      return;
    }
    final binding = attachment.binding;
    final elapsed = snapshot.paused
        ? Duration.zero
        : DateTime.now().difference(snapshot.receivedAt);
    final compensated = snapshot.position +
        (elapsed.isNegative ? Duration.zero : elapsed);
    if (binding.duration > Duration.zero &&
        (snapshot.doSeek ||
            (binding.playerPosition - compensated).inMilliseconds.abs() >
                1000)) {
      await binding.seekFromRoom(compensated);
      if (!_isCurrentPlayback(attachment)) {
        return;
      }
    }
    if (!_isCurrentPlayback(attachment)) {
      return;
    }
    if (snapshot.paused) {
      if (binding.playing) {
        await binding.pauseFromRoom();
      }
    } else if (!binding.playing) {
      await binding.playFromRoom();
    }
  }

  void _emitMediaEvent(SyncPlayRoomMediaEvent event) {
    if (!_mediaEventStreamController.isClosed) {
      _mediaEventStreamController.add(event);
    }
  }

  void _emitNotice(SyncPlayRoomNotice notice) {
    if (!_noticeStreamController.isClosed) {
      _noticeStreamController.add(notice);
    }
  }

  void beginChatSession(String room, {bool preserveHistory = false}) {
    final shouldClear = !preserveHistory ||
        (_activeChatRoom.isNotEmpty && _activeChatRoom != room);
    if (shouldClear) {
      clearChatSession();
      _clearRoomPlaybackState();
    }
    _activeChatRoom = room;
  }

  void _clearRoomPlaybackState() {
    _playbackSnapshot = null;
    currentMedia = null;
    _mediaGeneration = 0;
  }

  void appendUserMessage({
    required String username,
    required String message,
    bool fromRemote = false,
    DateTime? time,
    bool? mentionsSelf,
  }) {
    if (fromRemote && isChatUserMuted(username)) {
      return;
    }
    emitChatMessage(
      username: username,
      message: message,
      fromRemote: fromRemote,
      time: time,
      mentionsSelf: mentionsSelf,
    );
  }

  void appendSystemMessage(String message, {String username = '系统'}) {
    if (chatMessages.isNotEmpty) {
      final previous = chatMessages.last;
      if (previous.type == SyncPlayChatMessageType.system &&
          previous.username == normalizeSyncPlayUsername(username) &&
          previous.message == message) {
        return;
      }
    }
    emitChatMessage(
      username: normalizeSyncPlayUsername(username),
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
    bool? mentionsSelf,
  }) {
    if (_chatStreamController.isClosed) {
      return;
    }

    final validUsername = isSyncPlayUsernameValid(username);
    final hasText = message.trim().isNotEmpty;
    if (fromRemote && validUsername && isChatUserMuted(username)) {
      return;
    }
    final effectiveType =
        type == SyncPlayChatMessageType.user && (!validUsername || !hasText)
            ? SyncPlayChatMessageType.system
            : type;
    final safeUsername =
        validUsername ? normalizeSyncPlayUsername(username) : '系统';
    final effectiveMention = effectiveType == SyncPlayChatMessageType.user &&
        (mentionsSelf ?? _messageMentionsCurrentUser(message));
    final chatMessage = SyncPlayChatMessage(
      id: _nextChatMessageId++,
      username: safeUsername,
      message: hasText ? message : '收到一条空消息',
      fromRemote: fromRemote,
      time: time ?? DateTime.now(),
      type: effectiveType,
      mentionsSelf: effectiveMention,
    );
    chatMessages.add(chatMessage);
    while (chatMessages.length > maxChatMessages) {
      final removed = chatMessages.removeAt(0);
      _unreadChatMessageIds.remove(removed.id);
      _unreadMentionMessageIds.remove(removed.id);
    }
    if (effectiveType == SyncPlayChatMessageType.user &&
        fromRemote &&
        !chatVisible) {
      _unreadChatMessageIds.add(chatMessage.id);
      if (effectiveMention) {
        _unreadMentionMessageIds.add(chatMessage.id);
      }
    }
    _syncUnreadCounts();
    if (effectiveType == SyncPlayChatMessageType.user) {
      _chatStreamController.add(chatMessage);
    }
  }

  /// Registers a chat UI surface with this app-scoped room session.
  ///
  /// Each surface owns its token. This lets a room page and a player page
  /// coexist without one page's disposal hiding the other page's chat.
  Object registerChatSurface() {
    final token = Object();
    _chatSurfaces.add(token);
    return token;
  }

  /// Updates visibility for one previously registered chat surface.
  void setChatSurfaceVisible(Object token, bool visible) {
    if (!_chatSurfaces.contains(token)) {
      return;
    }
    if (visible) {
      _visibleChatSurfaces.add(token);
    } else {
      _visibleChatSurfaces.remove(token);
    }
    _updateChatVisibility();
  }

  /// Removes a chat surface and its visibility state.
  void unregisterChatSurface(Object token) {
    final wasRegistered = _chatSurfaces.remove(token);
    final wasVisible = _visibleChatSurfaces.remove(token);
    if (wasRegistered || wasVisible) {
      _updateChatVisibility();
    }
  }

  /// Compatibility shim for existing non-UI callers and legacy tests.
  ///
  /// New UI code must use a token returned by [registerChatSurface].
  @Deprecated('Use registerChatSurface and setChatSurfaceVisible instead.')
  void setChatVisible(bool visible) {
    _chatSurfaces.add(_legacyChatSurfaceToken);
    setChatSurfaceVisible(_legacyChatSurfaceToken, visible);
  }

  void setAppForeground(bool foreground) {
    appForeground = foreground;
    _updateChatVisibility();
  }

  void setWindowFocused(bool focused) {
    windowFocused = focused;
    _updateChatVisibility();
  }

  void _updateChatVisibility() {
    final visible =
        _visibleChatSurfaces.isNotEmpty && appForeground && windowFocused;
    chatVisible = visible;
    if (visible) {
      markChatRead();
    }
  }

  void markChatRead() {
    _clearUnreadTracking();
  }

  void _clearUnreadTracking() {
    _unreadChatMessageIds.clear();
    _unreadMentionMessageIds.clear();
    _syncUnreadCounts();
  }

  void clearChatSession() {
    chatMessages.clear();
    _clearUnreadTracking();
    mutedChatUsers.clear();
    _activeChatRoom = '';
  }

  /// Clears messages without leaving the currently joined room.
  void clearChatHistory() {
    chatMessages.clear();
    _clearUnreadTracking();
    mutedChatUsers.clear();
  }

  bool isChatUserMuted(String username) {
    final safeName = normalizeSyncPlayUsername(username);
    return safeName != '系统' && mutedChatUsers.contains(safeName);
  }

  void setChatUserMuted(String username, bool muted) {
    if (!isSyncPlayUsernameValid(username)) {
      return;
    }
    final safeName = normalizeSyncPlayUsername(username);
    if (muted) {
      mutedChatUsers.add(safeName);
      final removedIds = chatMessages
          .where(
            (message) =>
                message.type == SyncPlayChatMessageType.user &&
                message.fromRemote &&
                message.username == safeName,
          )
          .map((message) => message.id)
          .toSet();
      chatMessages.removeWhere(
        (message) => removedIds.contains(message.id),
      );
      _unreadChatMessageIds.removeAll(removedIds);
      _unreadMentionMessageIds.removeAll(removedIds);
      _syncUnreadCounts();
    } else {
      mutedChatUsers.remove(safeName);
    }
  }

  void toggleChatUserMuted(String username) {
    setChatUserMuted(username, !isChatUserMuted(username));
  }

  String get unreadChatLabel {
    if (unreadMentionCount > 0) {
      return '@${unreadMentionCount > 99 ? '99+' : unreadMentionCount}';
    }
    return unreadChatCount > 99 ? '99+' : '$unreadChatCount';
  }

  bool _messageMentionsCurrentUser(String message) {
    final username = confirmedUsername;
    return syncPlayMessageMentionsUsername(message, username);
  }

  void _syncUnreadCounts() {
    unreadChatCount = _unreadChatMessageIds.length;
    unreadMentionCount = _unreadMentionMessageIds.length;
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
    String username, {
    bool preserveChatHistory = false,
  }) async {
    if (_connectionSessions.isClosed) {
      return;
    }
    _requestedChatRoom = room;
    _requestedUsername = username;
    final session = _connectionSessions.begin();
    final reconnecting = preserveChatHistory ||
        connectionState == SyncPlayConnectionState.reconnecting;
    final previousClient = syncplayController;
    _connectionLossHandled = false;
    connectionState = reconnecting
        ? SyncPlayConnectionState.reconnecting
        : SyncPlayConnectionState.connecting;
    syncplayController = null;
    syncplayRoom = '';
    syncplayClientRtt = 0;
    beginChatSession(room, preserveHistory: preserveChatHistory);
    await previousClient?.disconnect();
    if (session.isStale) {
      return;
    }
    final String syncPlayEndPoint =
        GStorage.getSetting(SettingsKeys.syncPlayEndPoint);
    KazumiLogger().i('SyncPlay: connecting to $syncPlayEndPoint');
    final parsed = parseSyncPlayEndPoint(syncPlayEndPoint);
    if (parsed == null) {
      _finishFailedConnection(
        session,
      );
      _emitNotice(
        SyncPlayRoomConnectionFailed('服务器地址不合法 $syncPlayEndPoint'),
      );
      KazumiLogger().e('SyncPlay: invalid server address $syncPlayEndPoint');
      return;
    }
    final enableTLS = isOfficialSyncPlayEndPoint(parsed);
    final client = _clientFactory(host: parsed.host, port: parsed.port);
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
            unawaited(_handleConnectionLoss(session, client, message));
          }
        },
      );
      client.onRoomMessage.listen(
        (message) {
          if (!_isCurrentConnection(session, client)) {
            return;
          }
          if (message['type'] == 'init') {
            final username = message['username'];
            final initialUsername = username is String ? username : '';
            _emitNotice(SyncPlayRoomInitialSync(initialUsername));
            if (initialUsername.isEmpty) {
              setPlayingBangumi();
            }
          }
          if (message['type'] == 'left') {
            final sender = normalizeSyncPlayUsername(message['username']);
            appendSystemMessage('$sender 离开了房间');
          }
          if (message['type'] == 'joined') {
            final sender = normalizeSyncPlayUsername(message['username']);
            appendSystemMessage('$sender 加入了房间');
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
          _handleRemoteMediaChanged(message);
        },
      );
      client.onChatMessage.listen(
        (message) {
          if (!_isCurrentConnection(session, client)) {
            return;
          }
          final rawSender = message['username'];
          final String sender = rawSender is String ? rawSender : '';
          final String text = (message['message'] ?? '').toString();
          final String normalizedSender = normalizeSyncPlayUsername(sender);
          final String confirmed = confirmedUsername;
          final bool fromRemote =
              confirmed.isEmpty || normalizedSender != confirmed;

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
          final binding = _playbackBinding;
          final snapshot = _snapshotFromPositionMessage(message);
          _playbackSnapshot = snapshot;
          final attachment = binding == null
              ? null
              : SyncPlayPlaybackAttachment(
                  generation: _playbackBindingGeneration,
                  binding: binding,
                );
          final clientRtt = message['clientRtt'];
          if (clientRtt is num) {
            syncplayClientRtt = (clientRtt.toDouble() * 1000).toInt();
          }
          KazumiLogger().i(
              'SyncPlay: position changed by ${message['setBy']}: [${DateTime.now().millisecondsSinceEpoch / 1000.0}] calculatedPosition ${message['calculatedPositon']} position: ${message['position']} doSeek: ${message['doSeek']} paused: ${message['paused']} clientRtt: ${message['clientRtt']} serverRtt: ${message['serverRtt']} fd: ${message['fd']}');
          if (attachment != null) {
            unawaited(_applyRemotePlaybackSnapshot(attachment, snapshot));
          }
        },
      );
      final hello = await client.joinRoom(room, username);
      if (!_isCurrentConnection(session, client)) {
        await client.disconnect();
        return;
      }
      if (hello.room.trim().isEmpty) {
        throw SyncplayProtocolException('SyncPlay: Hello 未确认房间');
      }
      // Room and invite data become formal only after Hello. The returned
      // username is also the identity used to classify local chat echoes.
      beginChatSession(hello.room, preserveHistory: preserveChatHistory);
      syncplayRoom = hello.room;
      connectionState = SyncPlayConnectionState.connected;
    } catch (e) {
      KazumiLogger().e('SyncPlay: error', error: e);
      if (!_isCurrentConnection(session, client)) {
        await client.disconnect();
        return;
      }
      await _disconnect(clearChatSession: false, client: client);
      connectionState = SyncPlayConnectionState.failed;
      final message = e is SyncplayException ? e.message : e.toString();
      _emitNotice(SyncPlayRoomConnectionFailed('连接失败 $message'));
    }
  }

  /// Repeats the last requested room using the existing session's history.
  Future<void> retryConnection() {
    final activeRetry = _retryFuture;
    if (activeRetry != null) {
      return activeRetry;
    }
    final retry = _retryConnectionOnce();
    _retryFuture = retry;
    return retry.whenComplete(() {
      if (identical(_retryFuture, retry)) {
        _retryFuture = null;
      }
    });
  }

  Future<void> _retryConnectionOnce() async {
    final room = _requestedChatRoom;
    final username = _requestedUsername;
    if (room.isEmpty ||
        connectionState == SyncPlayConnectionState.disconnected) {
      if (connectionState != SyncPlayConnectionState.disconnected) {
        connectionState = SyncPlayConnectionState.failed;
      }
      return;
    }
    await createRoom(
      room,
      username,
      preserveChatHistory: true,
    );
  }

  void _finishFailedConnection(AsyncSession session) {
    if (!session.isActive) {
      return;
    }
    syncplayController = null;
    syncplayRoom = '';
    syncplayClientRtt = 0;
    connectionState = SyncPlayConnectionState.failed;
  }

  Future<void> _handleConnectionLoss(
    AsyncSession session,
    SyncplayClient client,
    String error,
  ) async {
    if (!_isCurrentConnection(session, client) || _connectionLossHandled) {
      return;
    }
    _connectionLossHandled = true;
    _connectionSessions.cancel();
    syncplayController = null;
    syncplayRoom = '';
    syncplayClientRtt = 0;
    connectionState = SyncPlayConnectionState.reconnecting;
    appendSystemMessage('连接已中断');
    _emitNotice(SyncPlayRoomReconnecting());
    await client.disconnect();
    await retryConnection();
    if (connectionState == SyncPlayConnectionState.connected) {
      appendSystemMessage('已重新连接');
      _emitNotice(SyncPlayRoomReconnected());
    } else if (connectionState != SyncPlayConnectionState.disconnected &&
        connectionState != SyncPlayConnectionState.failed) {
      connectionState = SyncPlayConnectionState.failed;
    }
  }

  bool _isCurrentConnection(AsyncSession session, SyncplayClient client) {
    return session.isActive && identical(syncplayController, client);
  }

  SyncPlayRoomPlaybackSnapshot _snapshotFromPositionMessage(
    Map<String, dynamic> message,
  ) {
    final rawPosition = message['calculatedPositon'];
    final fallbackPosition = message['position'];
    final positionSeconds = rawPosition is num
        ? rawPosition.toDouble()
        : fallbackPosition is num
            ? fallbackPosition.toDouble()
            : 0.0;
    final rawPaused = message['paused'];
    final rawDoSeek = message['doSeek'];
    final rawSetBy = message['setBy'];
    return SyncPlayRoomPlaybackSnapshot(
      paused: rawPaused is bool ? rawPaused : true,
      position: Duration(
        milliseconds:
            (positionSeconds * 1000).round().clamp(0, 1 << 31).toInt(),
      ),
      setBy: rawSetBy is String ? rawSetBy : '',
      doSeek: rawDoSeek is bool && rawDoSeek,
      receivedAt: DateTime.now(),
    );
  }

  Future<void> _applyRemotePlaybackSnapshot(
    SyncPlayPlaybackAttachment attachment,
    SyncPlayRoomPlaybackSnapshot snapshot,
  ) async {
    try {
      await _applyPlaybackSnapshot(attachment, snapshot);
    } catch (error, stackTrace) {
      // A player can disappear between two generation checks if its native
      // resources are being torn down. Keep that failure local to the stale
      // remote event and never let it surface as an unhandled stream error.
      if (_isCurrentPlayback(attachment)) {
        KazumiLogger().w(
          'SyncPlay: failed to apply remote playback state',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
  }

  void _handleRemoteMediaChanged(Map<String, dynamic> message) {
    final rawName = message['name'];
    if (rawName is! String) {
      return;
    }
    final reference = SyncPlayMediaCodec.tryParse(rawName);
    if (reference == null) {
      return;
    }
    final rawSetBy = message['setBy'];
    final selectedBy = rawSetBy is String ? rawSetBy : '';
    final media = SyncPlayRoomMedia(
      bangumiId: reference.bangumiId,
      episode: reference.episode,
      selectedBy: selectedBy,
      updatedAt: DateTime.now(),
      generation: ++_mediaGeneration,
    );
    currentMedia = media;
    _emitMediaEvent(SyncPlayRoomMediaChanged(media));
    _emitNotice(SyncPlayRoomRemoteMediaChanged(media));

    final binding = _playbackBinding;
    if (binding == null || binding.bangumiId != media.bangumiId) {
      if (binding != null) {
        _emitMediaEvent(
          SyncPlayRoomMediaMismatch(
            roomMedia: media,
            localBangumiId: binding.bangumiId,
          ),
        );
      }
      return;
    }
    if (binding.currentEpisode == media.episode) {
      return;
    }
    final attachment = SyncPlayPlaybackAttachment(
      generation: _playbackBindingGeneration,
      binding: binding,
    );
    unawaited(_applyRemoteMediaChange(attachment, media));
  }

  Future<void> _applyRemoteMediaChange(
    SyncPlayPlaybackAttachment attachment,
    SyncPlayRoomMedia media,
  ) async {
    if (!_isCurrentPlayback(attachment) ||
        attachment.binding.bangumiId != media.bangumiId ||
        attachment.binding.currentEpisode == media.episode) {
      return;
    }
    try {
      await attachment.binding.changeEpisodeFromRoom(media.episode);
      // The route may have detached or been replaced while episode loading
      // was in flight.  Do not let a completed stale callback continue into
      // any follow-up room state application.
      if (!_isCurrentPlayback(attachment)) {
        return;
      }
    } catch (error, stackTrace) {
      if (_isCurrentPlayback(attachment)) {
        KazumiLogger().w(
          'SyncPlay: failed to follow remote episode',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
  }

  void setCurrentPosition({bool? forceSyncPlaying, double? forceSyncPosition}) {
    final binding = _playbackBinding;
    if (syncplayController == null || binding == null) {
      return;
    }
    forceSyncPlaying ??= binding.playing;
    syncplayController!.setPaused(!forceSyncPlaying);
    syncplayController!.setPosition((forceSyncPosition ??
        (((binding.currentPosition.inMilliseconds - binding.playerPosition.inMilliseconds)
                    .abs() >
                2000)
            ? binding.currentPosition.inMilliseconds.toDouble() / 1000
            : binding.playerPosition.inMilliseconds.toDouble() / 1000)));
  }

  Future<void> setPlayingBangumi(
      {bool? forceSyncPlaying, double? forceSyncPosition}) async {
    final client = syncplayController;
    final binding = _playbackBinding;
    if (client == null || binding == null) {
      return;
    }
    final attachment = SyncPlayPlaybackAttachment(
      generation: _playbackBindingGeneration,
      binding: binding,
    );
    await _runBestEffortSync(() async {
      await client.setSyncPlayPlaying(
          SyncPlayMediaCodec.encode(
            bangumiId: binding.bangumiId,
            episode: binding.currentEpisode,
          ),
          10800,
          220514438);
      if (!identical(syncplayController, client) ||
          !_isCurrentPlayback(attachment)) {
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
      if (clearChatSession) {
        connectionState = SyncPlayConnectionState.disconnected;
      }
    }
    if (clearChatSession) {
      this.clearChatSession();
      _clearRoomPlaybackState();
      _requestedChatRoom = '';
      _requestedUsername = '';
      _connectionLossHandled = true;
    } else if (systemMessage != null) {
      appendSystemMessage(systemMessage);
    }
    await controller?.disconnect();
  }

  Future<void> dispose() async {
    _connectionSessions.close();
    _playbackBinding = null;
    _playbackBindingGeneration++;
    await exitRoom();
    chatMessages.clear();
    await _chatStreamController.close();
    await _mediaEventStreamController.close();
    await _noticeStreamController.close();
  }
}
