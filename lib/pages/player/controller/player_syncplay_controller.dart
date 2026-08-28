// ignore_for_file: library_private_types_in_public_api

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:kazumi/pages/player/controller/player_models.dart';
import 'package:kazumi/pages/video/video_playback_args.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/player/syncplay_client.dart';
import 'package:kazumi/services/player/syncplay_endpoint.dart';
import 'package:kazumi/services/player/syncplay_invite.dart';
import 'package:kazumi/services/player/syncplay_managed_room_models.dart';
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

const Duration _roomMediaSelectionTimeout = Duration(seconds: 10);
const Duration _managedRoomOperationTimeout = Duration(seconds: 10);

final class _PendingRoomMediaSelection {
  _PendingRoomMediaSelection({
    required this.token,
    required this.bangumiId,
    required this.episode,
  });

  final int token;
  final int bangumiId;
  final int episode;
  final Completer<bool> completer = Completer<bool>();
  Timer? timeout;
}

class PlayerSyncPlayController = _PlayerSyncPlayController
    with _$PlayerSyncPlayController;

abstract class _PlayerSyncPlayController with Store {
  _PlayerSyncPlayController({
    SyncplayClientFactory? clientFactory,
    @visibleForTesting String Function()? endpointProvider,
    @visibleForTesting Duration? mediaSelectionTimeout,
  })  : _clientFactory = clientFactory ??
            (({required String host, required int port}) =>
                SyncplayClient(host: host, port: port)),
        _endpointProvider = endpointProvider,
        _mediaSelectionTimeout =
            mediaSelectionTimeout ?? _roomMediaSelectionTimeout;

  final SyncplayClientFactory _clientFactory;

  /// Supplies the configured endpoint in production. Tests may inject a
  /// deterministic endpoint while using a fake client, without touching
  /// Hive-backed application settings or a real socket.
  final String Function()? _endpointProvider;
  final Duration _mediaSelectionTimeout;

  /// Set before the socket opens and cleared on teardown, so unlike
  /// [syncplayRoom] it also covers the window where the connection is still
  /// being established.
  @observable
  SyncplayClient? syncplayController;
  final AsyncSessionOwner _connectionSessions = AsyncSessionOwner();
  AsyncSession? _activeConnectionSession;
  @observable
  String syncplayRoom = '';
  @observable
  int syncplayClientRtt = 0;

  @observable
  SyncPlayConnectionState connectionState =
      SyncPlayConnectionState.disconnected;

  final Observable<SyncPlayRoomControlMode> _roomControlMode =
      Observable(SyncPlayRoomControlMode.free);
  final Observable<SyncPlayOperatorAuthState> _operatorAuthState =
      Observable(SyncPlayOperatorAuthState.none);
  final Observable<SyncplayServerFeatures> _serverFeatures =
      Observable(const SyncplayServerFeatures());
  final Observable<String?> _operatorPassword = Observable(null);
  final Observable<String?> _managedRoomBaseName = Observable(null);
  final Observable<SyncPlayPlaybackParticipation> _playbackParticipation =
      Observable(SyncPlayPlaybackParticipation.detached);

  final ObservableMap<String, SyncplayRoomUser> roomUsers =
      ObservableMap<String, SyncplayRoomUser>();

  SyncPlayRoomControlMode get roomControlMode => _roomControlMode.value;

  SyncPlayOperatorAuthState get operatorAuthState => _operatorAuthState.value;

  SyncplayServerFeatures get serverFeatures => _serverFeatures.value;

  String? get operatorPassword => _operatorPassword.value;

  String? get managedRoomBaseName => _managedRoomBaseName.value;

  SyncPlayPlaybackParticipation get playbackParticipation =>
      _playbackParticipation.value;

  bool get serverSupportsManagedRooms => serverFeatures.managedRooms;

  bool get isManagedRoom =>
      roomControlMode == SyncPlayRoomControlMode.managed ||
      isSyncPlayManagedRoomName(syncplayRoom);

  bool get isRoomOperator {
    final username = confirmedUsername;
    if (username.isEmpty) {
      return false;
    }
    return roomUsers[username]?.isController == true;
  }

  bool get hasActiveOperator =>
      roomUsers.values.any((user) => user.isController);

  bool get canControlLocalPlayback =>
      !isManagedRoom ||
      isRoomOperator ||
      playbackParticipation != SyncPlayPlaybackParticipation.followingRoom;

  bool get shouldBroadcastLocalPlayback =>
      !isManagedRoom ||
      (isRoomOperator &&
          playbackParticipation == SyncPlayPlaybackParticipation.followingRoom);

  bool get canChangePlaybackSpeed =>
      !isManagedRoom ||
      playbackParticipation == SyncPlayPlaybackParticipation.localOnly;

  bool get hasSession => syncplayController != null;

  SyncPlayPlaybackBinding? _playbackBinding;
  int _playbackBindingGeneration = 0;

  /// The current binding generation. Primarily useful for diagnostics and
  /// tests; callers must use [SyncPlayPlaybackAttachment] for detach.
  int get playbackBindingGeneration => _playbackBindingGeneration;

  bool get hasPlaybackBinding => _playbackBinding != null;

  SyncPlayPlaybackBinding? get playbackBinding => _playbackBinding;

  /// Returns whether a route opened for [intent] still points at the current
  /// room media snapshot.  Generation zero represents a video-first route
  /// entering a room that has not selected media yet.
  bool isPlaybackLaunchIntentCurrent(SyncPlayPlaybackLaunchIntent intent) {
    if (!intent.isValid || syncplayRoom.isEmpty) {
      return false;
    }
    if (_mediaGeneration != intent.expectedMediaGeneration) {
      return false;
    }
    final media = currentMedia;
    if (media == null) {
      return intent.expectedMediaGeneration == 0;
    }
    return media.generation == intent.expectedMediaGeneration &&
        media.bangumiId == intent.expectedBangumiId &&
        media.episode == intent.expectedEpisode;
  }

  SyncPlayPlaybackAttachment attachPlayback(SyncPlayPlaybackBinding binding) {
    final attachment = SyncPlayPlaybackAttachment(
      generation: ++_playbackBindingGeneration,
      binding: binding,
    );
    _playbackBinding = binding;
    _updatePlaybackParticipation(binding);
    unawaited(_restorePlaybackAttachment(attachment));
    return attachment;
  }

  void detachPlayback(SyncPlayPlaybackAttachment attachment) {
    if (attachment.generation != _playbackBindingGeneration ||
        !identical(attachment.binding, _playbackBinding)) {
      return;
    }
    _playbackBinding = null;
    _playbackParticipation.value = SyncPlayPlaybackParticipation.detached;
  }

  void _updatePlaybackParticipation(SyncPlayPlaybackBinding binding) {
    if (!isManagedRoom) {
      _playbackParticipation.value =
          SyncPlayPlaybackParticipation.followingRoom;
      return;
    }
    final media = currentMedia;
    _playbackParticipation.value = media != null &&
            media.bangumiId == binding.bangumiId &&
            media.episode == binding.currentEpisode
        ? SyncPlayPlaybackParticipation.followingRoom
        : SyncPlayPlaybackParticipation.localOnly;
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

  /// Local video-source resolution/loading state. This is never encoded into
  /// SyncPlay protocol messages or broadcast as room media.
  @observable
  SyncPlayLocalMediaStatus localMediaStatus = SyncPlayLocalMediaStatus.idle;

  /// A local resolution error, if [localMediaStatus] is [failed].
  @observable
  String? localMediaError;

  int _mediaGeneration = 0;

  int _mediaSelectionToken = 0;
  _PendingRoomMediaSelection? _pendingMediaSelection;

  int get mediaGeneration => _mediaGeneration;

  bool get canControlPlayback => !isManagedRoom || isRoomOperator;

  bool get canSelectRoomMedia => !isManagedRoom || isRoomOperator;

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
  SyncPlayRoomControlMode _requestedControlMode = SyncPlayRoomControlMode.free;
  bool _requestedManagedRoomCreation = false;
  String? _requestedOperatorPassword;
  bool _connectionLossHandled = false;
  Future<void>? _retryFuture;
  Future<bool>? _operatorAuthenticationFuture;
  final List<Map<String, dynamic>> _pendingManagedMediaEvents =
      <Map<String, dynamic>>[];
  Timer? _pendingManagedMediaEventsTimer;
  bool _chatEntryPromptShown = false;
  bool? _lastConfirmedProtocolPaused;
  String? _lastPlaybackNoticeFingerprint;
  DateTime? _lastPlaybackNoticeAt;
  int _nextChatMessageId = 1;
  final Set<int> _unreadChatMessageIds = <int>{};
  final Set<int> _unreadMentionMessageIds = <int>{};

  static const int maxChatMessages = 300;
  static const int maxChatMessageLength = 500;

  int get chatMessageLengthLimit => maxChatMessageLength;

  Future<bool> ensureSyncPlayChatReady({
    required Future<void> Function() promptJoin,
    bool forcePrompt = false,
  }) async {
    if (isChatConnected) {
      _chatEntryPromptShown = false;
      return true;
    }
    if (!forcePrompt && _chatEntryPromptShown) {
      return false;
    }
    _chatEntryPromptShown = true;
    await promptJoin();
    return isChatConnected;
  }

  void resetSyncPlayChatEntryPrompt() {
    _chatEntryPromptShown = false;
  }

  bool? get lastConfirmedProtocolPaused => _lastConfirmedProtocolPaused;

  void resetPlaybackNoticeBaseline() {
    _lastConfirmedProtocolPaused = null;
    _lastPlaybackNoticeFingerprint = null;
    _lastPlaybackNoticeAt = null;
  }

  /// Updates media resolution state owned by this device.
  ///
  /// This setter is intentionally independent from [currentMedia]: the
  /// latter only changes after an authoritative server broadcast.
  @action
  void setLocalMediaStatus(SyncPlayLocalMediaStatus status, {String? error}) {
    localMediaStatus = status;
    localMediaError = status == SyncPlayLocalMediaStatus.failed ? error : null;
  }

  bool _isCurrentMediaSelection(_PendingRoomMediaSelection selection) {
    return identical(_pendingMediaSelection, selection) &&
        selection.token == _mediaSelectionToken;
  }

  void _completeMediaSelection(
    _PendingRoomMediaSelection selection,
    bool result,
  ) {
    if (!_isCurrentMediaSelection(selection)) {
      return;
    }
    selection.timeout?.cancel();
    selection.timeout = null;
    _pendingMediaSelection = null;
    if (!selection.completer.isCompleted) {
      selection.completer.complete(result);
    }
  }

  void _cancelMediaSelection() {
    final selection = _pendingMediaSelection;
    if (selection == null) {
      return;
    }
    selection.timeout?.cancel();
    selection.timeout = null;
    _pendingMediaSelection = null;
    _mediaSelectionToken++;
    if (!selection.completer.isCompleted) {
      selection.completer.complete(false);
    }
  }

  void _failMediaSelection(
    _PendingRoomMediaSelection selection,
    String reason,
  ) {
    if (!_isCurrentMediaSelection(selection)) {
      return;
    }
    KazumiLogger().w('SyncPlay: room media selection failed: $reason');
    _completeMediaSelection(selection, false);
  }

  void _onMediaSelectionTimeout(_PendingRoomMediaSelection selection) {
    _failMediaSelection(selection, '等待服务器确认媒体超时');
  }

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

  final StreamController<SyncPlayRoomMediaEvent> _mediaEventStreamController =
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
      final mediaGeneration = media.generation;
      if (media.bangumiId != binding.bangumiId) {
        _playbackParticipation.value = SyncPlayPlaybackParticipation.localOnly;
        _emitMediaEvent(
          SyncPlayRoomMediaMismatch(
            roomMedia: media,
            localBangumiId: binding.bangumiId,
            localEpisode: binding.currentEpisode,
          ),
        );
        return;
      } else if (media.episode != binding.currentEpisode) {
        _playbackParticipation.value =
            SyncPlayPlaybackParticipation.followingRoom;
        // The room already selected this Bangumi, so use the normal player
        // episode transition before restoring its latest position/state.
        await binding.changeEpisodeFromRoom(media.episode);
        final latestMedia = currentMedia;
        if (!_isCurrentPlayback(attachment) ||
            latestMedia == null ||
            latestMedia.generation != mediaGeneration ||
            latestMedia.bangumiId != media.bangumiId ||
            latestMedia.episode != media.episode) {
          return;
        }
      }
      if (_isCurrentPlayback(attachment) &&
          media.bangumiId == binding.bangumiId &&
          media.episode == binding.currentEpisode) {
        _playbackParticipation.value =
            SyncPlayPlaybackParticipation.followingRoom;
      }
    } else if (connectionState == SyncPlayConnectionState.connected &&
        syncplayRoom.isNotEmpty &&
        (syncplayController?.isConnected ?? false)) {
      // Video-first entry owns the first media publication when the room has
      // not selected one yet.  RoomPage has no playback binding, so it never
      // publishes a local URL or source choice here.
      if (canSelectRoomMedia) {
        _playbackParticipation.value =
            SyncPlayPlaybackParticipation.followingRoom;
        unawaited(_publishVideoFirstMedia(attachment, _mediaGeneration));
      } else {
        _playbackParticipation.value = SyncPlayPlaybackParticipation.localOnly;
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
    if (!_isCurrentPlayback(attachment) ||
        !_canApplyPlaybackSnapshot(attachment)) {
      return;
    }
    final binding = attachment.binding;
    final elapsed = snapshot.paused
        ? Duration.zero
        : DateTime.now().difference(snapshot.receivedAt);
    final compensated =
        snapshot.position + (elapsed.isNegative ? Duration.zero : elapsed);
    if (binding.duration > Duration.zero &&
        (snapshot.doSeek ||
            (binding.playerPosition - compensated).inMilliseconds.abs() >
                1000)) {
      await binding.seekFromRoom(compensated);
      if (!_isCurrentPlayback(attachment) ||
          !_canApplyPlaybackSnapshot(attachment)) {
        return;
      }
    }
    if (!_isCurrentPlayback(attachment) ||
        !_canApplyPlaybackSnapshot(attachment)) {
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

  Future<void> _publishVideoFirstMedia(
    SyncPlayPlaybackAttachment attachment,
    int expectedMediaGeneration,
  ) async {
    final client = syncplayController;
    if (client == null ||
        !_canPublishVideoFirstMedia(
          attachment,
          expectedMediaGeneration,
          client,
        )) {
      return;
    }
    final activeClient = client;
    await _runBestEffortSync(() async {
      final binding = attachment.binding;
      await activeClient.setSyncPlayPlaying(
        SyncPlayMediaCodec.encode(
          bangumiId: binding.bangumiId,
          episode: binding.currentEpisode,
        ),
        10800,
        220514438,
      );
      if (!_canPublishVideoFirstMedia(
        attachment,
        expectedMediaGeneration,
        activeClient,
      )) {
        return;
      }
      setCurrentPosition();
      await activeClient.sendSyncPlaySyncRequest(doSeek: null);
    });
  }

  bool _canPublishVideoFirstMedia(
    SyncPlayPlaybackAttachment attachment,
    int expectedMediaGeneration,
    SyncplayClient? client,
  ) {
    return client != null &&
        client.isConnected &&
        connectionState == SyncPlayConnectionState.connected &&
        syncplayRoom.isNotEmpty &&
        canSelectRoomMedia &&
        currentMedia == null &&
        _mediaGeneration == expectedMediaGeneration &&
        _isCurrentPlayback(attachment);
  }

  bool _canApplyPlaybackSnapshot(SyncPlayPlaybackAttachment attachment) {
    if (playbackParticipation == SyncPlayPlaybackParticipation.localOnly) {
      return false;
    }
    final media = currentMedia;
    return media == null ||
        (media.bangumiId == attachment.binding.bangumiId &&
            media.episode == attachment.binding.currentEpisode);
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
    _cancelMediaSelection();
    _playbackSnapshot = null;
    currentMedia = null;
    _mediaGeneration = 0;
    setLocalMediaStatus(SyncPlayLocalMediaStatus.idle);
    resetPlaybackNoticeBaseline();
  }

  void _clearManagedRoomState() {
    _pendingManagedMediaEventsTimer?.cancel();
    _pendingManagedMediaEventsTimer = null;
    _pendingManagedMediaEvents.clear();
    roomUsers.clear();
    _roomControlMode.value = SyncPlayRoomControlMode.free;
    _operatorAuthState.value = SyncPlayOperatorAuthState.none;
    _serverFeatures.value = const SyncplayServerFeatures();
    _operatorPassword.value = null;
    _managedRoomBaseName.value = null;
    _requestedOperatorPassword = null;
    _playbackParticipation.value = _playbackBinding == null
        ? SyncPlayPlaybackParticipation.detached
        : SyncPlayPlaybackParticipation.followingRoom;
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
  }) {
    return _connectRoom(
      room,
      username,
      preserveChatHistory: preserveChatHistory,
      requestedControlMode: isSyncPlayManagedRoomName(room)
          ? SyncPlayRoomControlMode.managed
          : SyncPlayRoomControlMode.free,
      operatorPassword: preserveChatHistory ? _requestedOperatorPassword : null,
    );
  }

  Future<bool> createManagedRoom(
    String roomBaseName,
    String username,
  ) async {
    final password = generateSyncPlayOperatorPassword();
    await _connectRoom(
      roomBaseName,
      username,
      requestedControlMode: SyncPlayRoomControlMode.managed,
      operatorPassword: password,
      createManagedRoom: true,
    );
    return connectionState == SyncPlayConnectionState.connected &&
        isManagedRoom &&
        isRoomOperator;
  }

  Future<void> _connectRoom(
    String room,
    String username, {
    bool preserveChatHistory = false,
    required SyncPlayRoomControlMode requestedControlMode,
    String? operatorPassword,
    bool createManagedRoom = false,
  }) async {
    if (_connectionSessions.isClosed) {
      return;
    }
    _cancelMediaSelection();
    _requestedChatRoom = room;
    _requestedUsername = username;
    _requestedControlMode = requestedControlMode;
    _requestedManagedRoomCreation = createManagedRoom;
    _requestedOperatorPassword = operatorPassword;
    final session = _connectionSessions.begin();
    _activeConnectionSession = session;
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
    roomUsers.clear();
    _serverFeatures.value = const SyncplayServerFeatures();
    _roomControlMode.value = requestedControlMode;
    _operatorAuthState.value =
        requestedControlMode == SyncPlayRoomControlMode.managed
            ? SyncPlayOperatorAuthState.authenticating
            : SyncPlayOperatorAuthState.none;
    _operatorPassword.value = operatorPassword;
    _managedRoomBaseName.value =
        requestedControlMode == SyncPlayRoomControlMode.managed ? room : null;
    beginChatSession(room, preserveHistory: preserveChatHistory);
    resetPlaybackNoticeBaseline();
    await previousClient?.disconnect();
    if (session.isStale) {
      return;
    }
    final String syncPlayEndPoint = _endpointProvider?.call() ??
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
            roomUsers.remove(sender);
            appendSystemMessage('$sender 离开了房间');
          }
          if (message['type'] == 'joined') {
            final sender = normalizeSyncPlayUsername(message['username']);
            roomUsers.putIfAbsent(
              sender,
              () => SyncplayRoomUser(
                username: sender,
                room: syncplayRoom.isNotEmpty ? syncplayRoom : room,
                isController: false,
              ),
            );
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
          _handleRemotePlaybackNotice(snapshot);
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
          if (attachment != null && _canApplyPlaybackSnapshot(attachment)) {
            unawaited(_applyRemotePlaybackSnapshot(attachment, snapshot));
          }
        },
      );
      client.onControllerAuthResult.listen(
        (result) {
          if (!_isCurrentConnection(session, client)) {
            return;
          }
          _applyControllerAuthResult(result);
        },
      );
      client.onUserListChanged.listen(
        (snapshot) {
          if (!_isCurrentConnection(session, client)) {
            return;
          }
          _applyUserListSnapshot(snapshot);
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
      _serverFeatures.value = hello.features;
      var authoritativeRoom = hello.room.trim();
      var effectiveControlMode = isSyncPlayManagedRoomName(authoritativeRoom)
          ? SyncPlayRoomControlMode.managed
          : SyncPlayRoomControlMode.free;
      var activeOperatorPassword = operatorPassword;

      if (createManagedRoom) {
        if (!hello.features.managedRooms) {
          throw SyncplayProtocolException('当前服务器不支持房主控制房间');
        }
        final password = normalizeSyncPlayOperatorPassword(
          operatorPassword ?? '',
        );
        if (!isSyncPlayOperatorPasswordValid(password)) {
          throw SyncplayProtocolException('主持密码格式无效');
        }
        final createdFuture = client.onControlledRoomCreated.first.timeout(
          _managedRoomOperationTimeout,
          onTimeout: () => throw SyncplayConnectionException(
            'SyncPlay: 创建房主控制房间超时',
          ),
        );
        await client.requestControlledRoom(authoritativeRoom, password);
        final created = await createdFuture;
        if (!_isCurrentConnection(session, client)) {
          await client.disconnect();
          return;
        }
        authoritativeRoom = created.roomName.trim();
        if (!isSyncPlayManagedRoomName(authoritativeRoom)) {
          throw SyncplayProtocolException('服务器返回了无效的房主控制房间');
        }
        final roomChangedFuture = client.onRoomChanged
            .firstWhere((roomName) => roomName == authoritativeRoom)
            .timeout(
              _managedRoomOperationTimeout,
              onTimeout: () => throw SyncplayConnectionException(
                'SyncPlay: 切换房主控制房间超时',
              ),
            );
        await client.changeRoom(authoritativeRoom);
        await roomChangedFuture;
        final authenticated = await _authenticateClientAsOperator(
          session: session,
          client: client,
          room: authoritativeRoom,
          password: password,
        );
        if (!authenticated) {
          throw SyncplayProtocolException('主持身份认证失败');
        }
        activeOperatorPassword = password;
        effectiveControlMode = SyncPlayRoomControlMode.managed;
        _requestedChatRoom = authoritativeRoom;
        _requestedManagedRoomCreation = false;
        _requestedOperatorPassword = password;
      } else if (effectiveControlMode == SyncPlayRoomControlMode.managed) {
        if (!hello.features.managedRooms) {
          throw SyncplayProtocolException('当前服务器不支持房主控制房间');
        }
        final password = operatorPassword == null
            ? null
            : normalizeSyncPlayOperatorPassword(operatorPassword);
        if (password != null && password.isNotEmpty) {
          final authenticated = await _authenticateClientAsOperator(
            session: session,
            client: client,
            room: authoritativeRoom,
            password: password,
          );
          if (!authenticated && preserveChatHistory) {
            appendSystemMessage('主持身份恢复失败');
          }
        }
        activeOperatorPassword = password;
        _requestedChatRoom = authoritativeRoom;
        _requestedOperatorPassword = password;
      }

      if (effectiveControlMode == SyncPlayRoomControlMode.managed) {
        await _requestManagedRoomUserList(
          session: session,
          client: client,
          requireLocalOperator: createManagedRoom,
        );
      }
      if (!_isCurrentConnection(session, client)) {
        await client.disconnect();
        return;
      }

      // Room and invite data become formal only after the complete managed
      // room transaction. The returned username is also the identity used to
      // classify local chat echoes.
      beginChatSession(authoritativeRoom, preserveHistory: preserveChatHistory);
      syncplayRoom = authoritativeRoom;
      _roomControlMode.value = effectiveControlMode;
      _operatorPassword.value =
          effectiveControlMode == SyncPlayRoomControlMode.managed
              ? activeOperatorPassword
              : null;
      _managedRoomBaseName.value =
          effectiveControlMode == SyncPlayRoomControlMode.managed
              ? syncPlayManagedRoomBaseName(authoritativeRoom)
              : null;
      if (effectiveControlMode == SyncPlayRoomControlMode.free) {
        _operatorAuthState.value = SyncPlayOperatorAuthState.none;
        roomUsers.clear();
      } else if (isRoomOperator) {
        _operatorAuthState.value = SyncPlayOperatorAuthState.operator;
      } else if (_operatorAuthState.value ==
          SyncPlayOperatorAuthState.authenticating) {
        _operatorAuthState.value = SyncPlayOperatorAuthState.none;
      }
      connectionState = SyncPlayConnectionState.connected;
      final binding = _playbackBinding;
      if (binding != null) {
        // The player can be attached before the Hello transaction reveals
        // that this is a managed room. Re-evaluate participation against the
        // authoritative room mode instead of keeping the pre-connect value.
        _updatePlaybackParticipation(binding);
      }
      if (currentMedia == null && binding != null) {
        // Video-first entry publishes the local media only after the server
        // has confirmed the room.  A room-first page has no binding and
        // therefore remains media-free until a member chooses one.
        unawaited(
          _publishVideoFirstMedia(
            SyncPlayPlaybackAttachment(
              generation: _playbackBindingGeneration,
              binding: binding,
            ),
            _mediaGeneration,
          ),
        );
      }
    } catch (e) {
      KazumiLogger().e('SyncPlay: error', error: e);
      if (!_isCurrentConnection(session, client)) {
        await client.disconnect();
        return;
      }
      await _disconnect(clearChatSession: false, client: client);
      _cancelMediaSelection();
      if (createManagedRoom) {
        roomUsers.clear();
        _roomControlMode.value = SyncPlayRoomControlMode.managed;
        _operatorAuthState.value = SyncPlayOperatorAuthState.failed;
        _operatorPassword.value = null;
        _managedRoomBaseName.value = null;
        _requestedOperatorPassword = null;
      }
      connectionState = SyncPlayConnectionState.failed;
      final message = e is SyncplayException ? e.message : e.toString();
      _emitNotice(SyncPlayRoomConnectionFailed('连接失败 $message'));
    }
  }

  Future<bool> authenticateAsOperator(String rawPassword) {
    final active = _operatorAuthenticationFuture;
    if (active != null) {
      return active;
    }
    final future = _authenticateAsOperatorOnce(rawPassword);
    _operatorAuthenticationFuture = future;
    return future.whenComplete(() {
      if (identical(_operatorAuthenticationFuture, future)) {
        _operatorAuthenticationFuture = null;
      }
    });
  }

  Future<bool> _authenticateAsOperatorOnce(String rawPassword) async {
    final client = syncplayController;
    final room = syncplayRoom;
    final password = normalizeSyncPlayOperatorPassword(rawPassword);
    if (connectionState != SyncPlayConnectionState.connected ||
        client == null ||
        room.isEmpty ||
        !isManagedRoom ||
        !serverSupportsManagedRooms ||
        !isSyncPlayOperatorPasswordValid(password)) {
      return false;
    }
    final session = _activeConnectionSession;
    if (session == null || !session.isActive) {
      return false;
    }
    _operatorAuthState.value = SyncPlayOperatorAuthState.authenticating;
    try {
      final authenticated = await _authenticateClientAsOperator(
        session: session,
        client: client,
        room: room,
        password: password,
      );
      if (!authenticated || !_isCurrentConnection(session, client)) {
        _operatorAuthState.value = SyncPlayOperatorAuthState.failed;
        return false;
      }
      _operatorPassword.value = password;
      _requestedOperatorPassword = password;
      await _requestManagedRoomUserList(
        session: session,
        client: client,
        requireLocalOperator: true,
      );
      if (!isRoomOperator) {
        _operatorAuthState.value = SyncPlayOperatorAuthState.failed;
        return false;
      }
      _operatorAuthState.value = SyncPlayOperatorAuthState.operator;
      appendSystemMessage(
        '${confirmedUsername.isEmpty ? '当前用户' : confirmedUsername} 已成为主持人',
      );
      return true;
    } on SyncplayException catch (error) {
      KazumiLogger().w(
        'SyncPlay: operator authentication failed',
        error: error,
      );
      _operatorAuthState.value = SyncPlayOperatorAuthState.failed;
      return false;
    } on TimeoutException catch (error) {
      KazumiLogger().w(
        'SyncPlay: operator authentication timed out',
        error: error,
      );
      _operatorAuthState.value = SyncPlayOperatorAuthState.failed;
      return false;
    }
  }

  Future<bool> _authenticateClientAsOperator({
    required AsyncSession session,
    required SyncplayClient client,
    required String room,
    required String password,
  }) async {
    final normalizedPassword = normalizeSyncPlayOperatorPassword(password);
    if (!isSyncPlayOperatorPasswordValid(normalizedPassword)) {
      return false;
    }
    _operatorAuthState.value = SyncPlayOperatorAuthState.authenticating;
    final username = client.username ?? confirmedUsername;
    final resultFuture = client.onControllerAuthResult
        .firstWhere(
          (result) =>
              result.room == room &&
              (username.isEmpty || result.username == username),
        )
        .timeout(
          _managedRoomOperationTimeout,
          onTimeout: () => throw SyncplayConnectionException(
            'SyncPlay: 主持身份认证超时',
          ),
        );
    await client.requestControlledRoom(room, normalizedPassword);
    final result = await resultFuture;
    if (!_isCurrentConnection(session, client)) {
      return false;
    }
    _applyControllerAuthResult(result);
    return result.success;
  }

  Future<void> _requestManagedRoomUserList({
    required AsyncSession session,
    required SyncplayClient client,
    required bool requireLocalOperator,
  }) async {
    final snapshotFuture = client.onUserListChanged.first.timeout(
      _managedRoomOperationTimeout,
      onTimeout: () => throw SyncplayConnectionException(
        'SyncPlay: 获取房间成员列表超时',
      ),
    );
    await client.requestUserList();
    final snapshot = await snapshotFuture;
    if (!_isCurrentConnection(session, client)) {
      return;
    }
    _applyUserListSnapshot(snapshot);
    if (requireLocalOperator && !isRoomOperator) {
      throw SyncplayProtocolException('服务器未确认当前用户的主持身份');
    }
  }

  void _applyControllerAuthResult(SyncplayControllerAuthResult result) {
    final room = syncplayRoom.isNotEmpty
        ? syncplayRoom
        : syncplayController?.currentRoom ?? _requestedChatRoom;
    if (result.room != room || !isSyncPlayUsernameValid(result.username)) {
      return;
    }
    final username = normalizeSyncPlayUsername(result.username);
    final existing = roomUsers[username];
    if (result.success) {
      roomUsers[username] = (existing ??
              SyncplayRoomUser(
                username: username,
                room: result.room,
                isController: false,
              ))
          .copyWith(room: result.room, isController: true);
    }
    if (username == confirmedUsername) {
      _operatorAuthState.value = result.success
          ? SyncPlayOperatorAuthState.operator
          : SyncPlayOperatorAuthState.failed;
    }
    _drainPendingManagedMediaEvents(
      resolvedUsername: username,
      resolvedIsController: result.success,
    );
  }

  void _applyUserListSnapshot(SyncplayUserListSnapshot snapshot) {
    final room = syncplayRoom.isNotEmpty
        ? syncplayRoom
        : syncplayController?.currentRoom ?? _requestedChatRoom;
    final filtered = snapshot.users.values.where(
      (user) => user.room == room && isSyncPlayUsernameValid(user.username),
    );
    roomUsers
      ..clear()
      ..addEntries(
        filtered.map(
          (user) => MapEntry(
            normalizeSyncPlayUsername(user.username),
            user.copyWith(username: normalizeSyncPlayUsername(user.username)),
          ),
        ),
      );
    final username = confirmedUsername;
    if (username.isNotEmpty && roomUsers[username]?.isController == true) {
      _operatorAuthState.value = SyncPlayOperatorAuthState.operator;
    } else if (_operatorAuthState.value != SyncPlayOperatorAuthState.failed) {
      _operatorAuthState.value = SyncPlayOperatorAuthState.none;
    }
    _drainPendingManagedMediaEvents(authoritativeSnapshot: true);
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
    if (_requestedManagedRoomCreation) {
      await _connectRoom(
        room,
        username,
        preserveChatHistory: true,
        requestedControlMode: SyncPlayRoomControlMode.managed,
        operatorPassword: generateSyncPlayOperatorPassword(),
        createManagedRoom: true,
      );
      return;
    }
    await _connectRoom(
      room,
      username,
      preserveChatHistory: true,
      requestedControlMode: _requestedControlMode,
      operatorPassword: _requestedOperatorPassword,
    );
  }

  void _finishFailedConnection(AsyncSession session) {
    if (!session.isActive) {
      return;
    }
    if (identical(_activeConnectionSession, session)) {
      _activeConnectionSession = null;
    }
    _cancelMediaSelection();
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
    _activeConnectionSession = null;
    _cancelMediaSelection();
    syncplayController = null;
    syncplayRoom = '';
    syncplayClientRtt = 0;
    resetPlaybackNoticeBaseline();
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

  void _handleRemotePlaybackNotice(SyncPlayRoomPlaybackSnapshot snapshot) {
    final actor = normalizeSyncPlayUsername(snapshot.setBy, fallback: '');
    final roundedPosition = snapshot.position.inMilliseconds / 1000;
    final fingerprint = '$actor|${snapshot.paused}|${roundedPosition.round()}';
    final receivedAt = snapshot.receivedAt;
    final previousPaused = _lastConfirmedProtocolPaused;
    final isDuplicate = _lastPlaybackNoticeFingerprint == fingerprint &&
        _lastPlaybackNoticeAt != null &&
        receivedAt.difference(_lastPlaybackNoticeAt!).abs() <=
            const Duration(milliseconds: 1100);

    _lastConfirmedProtocolPaused = snapshot.paused;
    _lastPlaybackNoticeFingerprint = fingerprint;
    _lastPlaybackNoticeAt = receivedAt;

    if (actor.isEmpty || isDuplicate || previousPaused == null) {
      return;
    }
    final localUsername = confirmedUsername;
    if (localUsername.isNotEmpty && actor == localUsername) {
      return;
    }
    if (previousPaused == snapshot.paused) {
      return;
    }

    final notice = SyncPlayRoomRemotePlaybackChanged(
      actor: actor,
      paused: snapshot.paused,
      position: snapshot.position,
      snapshot: snapshot,
    );
    appendSystemMessage(
      snapshot.paused ? '$actor 已暂停播放' : '$actor 开始播放',
    );
    _emitNotice(notice);
  }

  Future<void> _applyRemotePlaybackSnapshot(
    SyncPlayPlaybackAttachment attachment,
    SyncPlayRoomPlaybackSnapshot snapshot,
  ) async {
    if (!_isCurrentPlayback(attachment) ||
        !_canApplyPlaybackSnapshot(attachment)) {
      return;
    }
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

  void _queueManagedMediaEvent(Map<String, dynamic> message) {
    if (_pendingManagedMediaEvents.length >= 8) {
      _pendingManagedMediaEvents.removeAt(0);
    }
    _pendingManagedMediaEvents.add(Map<String, dynamic>.from(message));
    _pendingManagedMediaEventsTimer?.cancel();
    _pendingManagedMediaEventsTimer = Timer(
      const Duration(seconds: 2),
      () {
        _pendingManagedMediaEvents.clear();
        _pendingManagedMediaEventsTimer = null;
      },
    );
  }

  void _drainPendingManagedMediaEvents({
    String? resolvedUsername,
    bool? resolvedIsController,
    bool authoritativeSnapshot = false,
  }) {
    if (_pendingManagedMediaEvents.isEmpty) {
      return;
    }
    final pending = List<Map<String, dynamic>>.from(
      _pendingManagedMediaEvents,
    );
    final retained = <Map<String, dynamic>>[];
    for (final message in pending) {
      final sender = normalizeSyncPlayUsername(
        message['setBy'],
        fallback: '',
      );
      if (sender.isEmpty) {
        continue;
      }
      if (authoritativeSnapshot) {
        if (roomUsers[sender]?.isController == true) {
          _handleRemoteMediaChanged(message, allowRoleWait: false);
        }
        continue;
      }
      if (sender != resolvedUsername) {
        retained.add(message);
        continue;
      }
      if (resolvedIsController == true) {
        _handleRemoteMediaChanged(message, allowRoleWait: false);
      }
    }
    _pendingManagedMediaEvents
      ..clear()
      ..addAll(retained);
    if (_pendingManagedMediaEvents.isEmpty) {
      _pendingManagedMediaEventsTimer?.cancel();
      _pendingManagedMediaEventsTimer = null;
    }
  }

  void _handleRemoteMediaChanged(
    Map<String, dynamic> message, {
    bool allowRoleWait = true,
  }) {
    final rawName = message['name'];
    if (rawName is! String) {
      return;
    }
    final reference = SyncPlayMediaCodec.tryParse(rawName);
    if (reference == null) {
      return;
    }
    resetPlaybackNoticeBaseline();
    final rawSetBy = message['setBy'];
    final selectedBy = rawSetBy is String ? rawSetBy : '';
    if (isManagedRoom) {
      final normalizedSender = normalizeSyncPlayUsername(
        selectedBy,
        fallback: '',
      );
      if (normalizedSender.isEmpty) {
        return;
      }
      final sender = roomUsers[normalizedSender];
      if (sender == null) {
        if (allowRoleWait) {
          _queueManagedMediaEvent(message);
        }
        return;
      }
      if (!sender.isController) {
        KazumiLogger().w(
          'SyncPlay: ignored managed room media from a non-operator',
        );
        return;
      }
    }
    final media = SyncPlayRoomMedia(
      bangumiId: reference.bangumiId,
      episode: reference.episode,
      selectedBy: selectedBy,
      updatedAt: DateTime.now(),
      generation: ++_mediaGeneration,
    );
    currentMedia = media;
    final pendingSelection = _pendingMediaSelection;
    if (pendingSelection != null) {
      if (pendingSelection.bangumiId == media.bangumiId &&
          pendingSelection.episode == media.episode) {
        _completeMediaSelection(pendingSelection, true);
      } else {
        _failMediaSelection(pendingSelection, '房间媒体已被其他选择覆盖');
      }
    }
    _emitMediaEvent(SyncPlayRoomMediaChanged(media));
    _emitNotice(SyncPlayRoomRemoteMediaChanged(media));

    final binding = _playbackBinding;
    if (binding == null || binding.bangumiId != media.bangumiId) {
      if (binding != null) {
        _playbackParticipation.value = SyncPlayPlaybackParticipation.localOnly;
        _emitMediaEvent(
          SyncPlayRoomMediaMismatch(
            roomMedia: media,
            localBangumiId: binding.bangumiId,
            localEpisode: binding.currentEpisode,
          ),
        );
      }
      return;
    }
    if (binding.currentEpisode == media.episode) {
      _playbackParticipation.value =
          SyncPlayPlaybackParticipation.followingRoom;
      return;
    }
    _playbackParticipation.value = SyncPlayPlaybackParticipation.followingRoom;
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
      final latestMedia = currentMedia;
      if (!_isCurrentPlayback(attachment) ||
          latestMedia == null ||
          latestMedia.generation != media.generation ||
          latestMedia.bangumiId != media.bangumiId ||
          latestMedia.episode != media.episode) {
        return;
      }
      final snapshot = _playbackSnapshot;
      if (snapshot != null) {
        await _applyPlaybackSnapshot(attachment, snapshot);
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
    if (syncplayController == null ||
        binding == null ||
        !shouldBroadcastLocalPlayback) {
      return;
    }
    forceSyncPlaying ??= binding.playing;
    syncplayController!.setPaused(!forceSyncPlaying);
    syncplayController!.setPosition((forceSyncPosition ??
        (((binding.currentPosition.inMilliseconds -
                        binding.playerPosition.inMilliseconds)
                    .abs() >
                2000)
            ? binding.currentPosition.inMilliseconds.toDouble() / 1000
            : binding.playerPosition.inMilliseconds.toDouble() / 1000)));
  }

  Future<void> setPlayingBangumi(
      {bool? forceSyncPlaying, double? forceSyncPosition}) async {
    final client = syncplayController;
    final binding = _playbackBinding;
    if (client == null || binding == null || !canSelectRoomMedia) {
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

  /// Requests a new room media choice and waits for the server's file
  /// broadcast to confirm it. The room's [currentMedia] and generation are
  /// never changed by this local request.
  Future<bool> selectRoomMedia({
    required int bangumiId,
    required int episode,
  }) async {
    // A later request must invalidate an earlier wait even when its own
    // arguments are invalid. Otherwise the old operation could eventually
    // affect the newer request.
    _cancelMediaSelection();
    if (bangumiId <= 0 || episode <= 0 || !canSelectRoomMedia) {
      return false;
    }

    final client = syncplayController;
    if (connectionState != SyncPlayConnectionState.connected ||
        syncplayRoom.isEmpty ||
        client == null ||
        !client.isConnected) {
      return false;
    }

    final selection = _PendingRoomMediaSelection(
      token: ++_mediaSelectionToken,
      bangumiId: bangumiId,
      episode: episode,
    );
    _pendingMediaSelection = selection;
    try {
      final fileName = SyncPlayMediaCodec.encode(
        bangumiId: bangumiId,
        episode: episode,
      );
      await client.setSyncPlayPlaying(
        fileName,
        10800,
        220514438,
      );
      if (!_isCurrentMediaSelection(selection)) {
        return await selection.completer.future;
      }

      // The server receives a paused, zero-position state and must echo the
      // resulting file before this request is considered successful.
      client.setPaused(true);
      client.setPosition(0);
      await client.sendSyncPlaySyncRequest(doSeek: true);
      if (!_isCurrentMediaSelection(selection)) {
        return await selection.completer.future;
      }
      if (!client.isConnected) {
        _failMediaSelection(selection, '聊天室连接已中断');
        return await selection.completer.future;
      }

      selection.timeout = Timer(
        _mediaSelectionTimeout,
        () => _onMediaSelectionTimeout(selection),
      );
      return await selection.completer.future;
    } catch (error, stackTrace) {
      if (!_isCurrentMediaSelection(selection)) {
        return await selection.completer.future;
      }
      final message =
          error is SyncplayException ? error.message : '发送房间媒体失败：$error';
      KazumiLogger().w(
        'SyncPlay: failed to select room media',
        error: error,
        stackTrace: stackTrace,
      );
      _failMediaSelection(selection, message);
      return await selection.completer.future;
    }
  }

  String _configuredSyncPlayEndPoint() {
    try {
      final endpoint = _endpointProvider?.call() ??
          GStorage.getSetting<String>(SettingsKeys.syncPlayEndPoint);
      return endpoint.isEmpty ? defaultSyncPlayEndPoint : endpoint;
    } catch (_) {
      return defaultSyncPlayEndPoint;
    }
  }

  /// Builds the shareable room invitation from app-scoped room state.
  ///
  /// Media ids are included only when the server has already broadcast a
  /// valid room choice; a local player must not fabricate shared state.
  String syncPlayInviteText({String? localTitle, int? localBangumiId}) {
    final endpoint = _configuredSyncPlayEndPoint();
    final room = syncplayRoom;
    final media = currentMedia;
    final safeTitle = media != null && localBangumiId == media.bangumiId
        ? localTitle?.trim().replaceAll(RegExp(r'[\r\n]+'), ' ')
        : null;
    final viewing = media == null
        ? '尚未选择'
        : [
            if (safeTitle != null && safeTitle.isNotEmpty) safeTitle,
            'Bangumi #${media.bangumiId}',
            '第 ${media.episode} 集',
          ].join(' · ');

    var uri = '';
    if (room.isNotEmpty && media != null) {
      try {
        uri = SyncPlayInviteCodec.encode(
          room: room,
          server: endpoint,
          episode: media.episode,
          bangumi: media.bangumiId,
        );
      } catch (_) {
        // The readable legacy body remains useful when a custom endpoint is
        // not parseable by the versioned URI codec.
      }
    }

    final mediaDetails = media == null
        ? ''
        : '番剧 ID：${media.bangumiId}\n剧集：第 ${media.episode} 集\n';
    return '''Kazumi 一起看邀请
房间：$room
服务器：$endpoint
当前观看：$viewing
$mediaDetails${uri.isEmpty ? '' : '$uri\n'}
打开 Kazumi → 聊天室 → 加入房间''';
  }

  Future<void> requestSync({bool? doSeek}) async {
    final client = syncplayController;
    if (client == null || !shouldBroadcastLocalPlayback) {
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
    resetSyncPlayChatEntryPrompt();
  }

  Future<void> _disconnect({
    required bool clearChatSession,
    SyncplayClient? client,
    String? systemMessage,
  }) async {
    _connectionSessions.cancel();
    _activeConnectionSession = null;
    final controller = client ?? syncplayController;
    if (clearChatSession ||
        client == null ||
        identical(syncplayController, client)) {
      _cancelMediaSelection();
    }
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
      _clearManagedRoomState();
      _requestedChatRoom = '';
      _requestedUsername = '';
      _requestedControlMode = SyncPlayRoomControlMode.free;
      _requestedManagedRoomCreation = false;
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
