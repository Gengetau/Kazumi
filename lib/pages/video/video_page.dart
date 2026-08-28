import 'dart:async';
import 'package:canvas_danmaku/models/danmaku_content_item.dart';
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/pages/player/player_controller.dart';
import 'package:kazumi/pages/video/video_controller.dart';
import 'package:kazumi/pages/video/danmaku_send_sheet.dart';
import 'package:kazumi/pages/video/video_playback_args.dart';
import 'package:kazumi/pages/history/history_controller.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/pages/player/player_item.dart';
import 'package:kazumi/pages/player/syncplay_chat_panel.dart';
import 'package:kazumi/pages/player/syncplay_sheet.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/player/pip_utils.dart';
import 'package:kazumi/bean/appbar/drag_to_move_bar.dart' as dtb;
import 'package:kazumi/bean/dialog/adaptive_bottom_sheet.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:screen_brightness_platform_interface/screen_brightness_platform_interface.dart';
import 'package:scrollview_observer/scrollview_observer.dart';
import 'package:kazumi/pages/player/episode_comments_sheet.dart';
import 'package:window_manager/window_manager.dart';
import 'package:kazumi/bean/widget/embedded_native_control_area.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/pages/download/download_episode_sheet.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/services/player/timed_shutdown_service.dart';
import 'package:kazumi/utils/device.dart';
import 'package:kazumi/services/platform/display_mode_service.dart';
import 'package:kazumi/services/player/syncplay_managed_room_models.dart';
import 'package:kazumi/services/player/syncplay_room_session_controller.dart';
import 'package:kazumi/services/player/syncplay_room_notice.dart';
import 'package:kazumi/services/player/syncplay_room_models.dart';
import 'package:kazumi/services/player/syncplay_clipboard_invite_service.dart';
import 'package:kazumi/services/player/syncplay_invite.dart';
import 'package:mobx/mobx.dart' as mobx;

class VideoPage extends StatefulWidget {
  const VideoPage({
    super.key,
    required this.args,
    required this.playerController,
    required this.videoPageController,
    required this.historyController,
    required this.downloadController,
    required this.roomSession,
  });

  final VideoPlaybackArgs args;
  final PlayerController playerController;
  final VideoPageController videoPageController;
  final HistoryController historyController;
  final DownloadController downloadController;
  final SyncPlayRoomSessionController roomSession;

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage>
    with TickerProviderStateMixin, WindowListener {
  PlayerController get playerController => widget.playerController;
  SyncPlayRoomSessionController get roomSession => widget.roomSession;
  SyncPlayClipboardInviteService get inviteService =>
      inject<SyncPlayClipboardInviteService>();
  VideoPageController get videoPageController => widget.videoPageController;
  bool _didInitializePlayback = false;
  bool _isClosing = false;
  HistoryController get historyController => widget.historyController;
  DownloadController get downloadController => widget.downloadController;
  late bool playResume;
  bool showDebugLog = false;
  List<String> webviewLogLines = [];
  StreamSubscription<String>? _logSubscription;
  final FocusNode keyboardFocus =
      FocusNode(debugLabel: 'Video player shortcut scope');

  ScrollController scrollController = ScrollController();
  late GridObserverController observerController;
  late AnimationController animation;
  late Animation<Offset> _rightOffsetAnimation;
  late Animation<double> _maskOpacityAnimation;
  late TabController tabController;

  int visibleRoad = 0;
  bool _tabBodyTargetVisible = true;
  int _tabBodyAnimationRun = 0;

  late final bool disableAnimations;

  StreamSubscription<SyncPlayRoomNotice>? _syncNoticeSubscription;
  StreamSubscription<SyncPlayRoomMediaEvent>? _syncMediaSubscription;
  StreamSubscription<SyncPlayInvite>? _pendingInviteSubscription;
  late final Object _chatSurfaceToken;
  late final mobx.ReactionDisposer _pipModeListener;
  bool _roomMismatchDialogShown = false;

  static const Duration _offlinePlayerInitDelay = Duration(milliseconds: 400);
  static const Duration _sideTabAnimationDuration = Duration(milliseconds: 120);

  @override
  void initState() {
    super.initState();
    _chatSurfaceToken = roomSession.registerChatSurface();
    playerController.resetSyncPlayChatEntryPrompt();
    playerController.bindSyncPlayEpisodeChange(_changeEpisodeFromRoom);
    videoPageController.setPlaybackLaunchIntentValidator(
      _isPlaybackLaunchIntentCurrent,
    );
    videoPageController.applyPlaybackArgs(widget.args);
    windowManager.addListener(this);
    // Window fullscreen can be changed outside this page through system chrome.
    videoPageController.isDesktopFullscreen();
    tabController = TabController(length: 3, vsync: this);
    tabController.addListener(handleTabChanged);
    _pendingInviteSubscription =
        inviteService.pendingStream.listen(_handlePendingInvite);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final pending = inviteService.pending;
      if (pending != null) unawaited(_handlePendingInvite(pending));
    });
    observerController = GridObserverController(controller: scrollController);
    animation = AnimationController(
      duration: _sideTabAnimationDuration,
      vsync: this,
    );
    _rightOffsetAnimation = Tween<Offset>(
      begin: const Offset(1.0, 0.0),
      end: const Offset(0.0, 0.0),
    ).animate(CurvedAnimation(
      parent: animation,
      curve: Curves.easeOut,
    ));
    _maskOpacityAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: animation,
      curve: Curves.easeIn,
    ));

    playResume = GStorage.getSetting(SettingsKeys.playResume);
    disableAnimations =
        GStorage.getSetting(SettingsKeys.playerDisableAnimations);
    _pipModeListener = mobx.reaction<bool>(
      (_) => videoPageController.isPip,
      (_) {
        _syncFullscreenWithWindowShape();
        syncChatVisibility();
      },
    );
    _syncNoticeSubscription = roomSession.notices.listen(_handleRoomNotice);
    _syncMediaSubscription =
        roomSession.mediaEvents.listen(_handleRoomMediaEvent);
  }

  bool _isPlaybackLaunchIntentCurrent() {
    final intent = widget.args.launchIntent;
    return intent == null || roomSession.isPlaybackLaunchIntentCurrent(intent);
  }

  void _handleRoomMediaEvent(SyncPlayRoomMediaEvent event) {
    if (!mounted ||
        event is! SyncPlayRoomMediaMismatch ||
        _roomMismatchDialogShown) {
      return;
    }
    _roomMismatchDialogShown = true;
    unawaited(_showRoomMediaMismatch(event));
  }

  Future<void> _showRoomMediaMismatch(SyncPlayRoomMediaMismatch event) async {
    final sameBangumi = event.localBangumiId == event.roomMedia.bangumiId;
    final action = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          sameBangumi ? '房间已经切换到第 ${event.roomMedia.episode} 集' : '房间已经切换到其他番剧',
        ),
        content: Text(
          sameBangumi
              ? '是否跟随房间切换到第 ${event.roomMedia.episode} 集？'
              : '房间当前媒体为 Bangumi #${event.roomMedia.bangumiId}，当前播放器不会自动切换番剧。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('暂不跟随'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(sameBangumi ? '跟随房间' : '返回聊天室'),
          ),
        ],
      ),
    );
    if (!mounted) {
      return;
    }
    _roomMismatchDialogShown = false;
    if (action != true) {
      return;
    }
    if (sameBangumi) {
      final latest = roomSession.currentMedia;
      if (latest == null ||
          latest.generation != event.roomMedia.generation ||
          latest.bangumiId != event.roomMedia.bangumiId ||
          latest.episode != event.roomMedia.episode) {
        return;
      }
      await _changeEpisodeFromRoom(event.roomMedia.episode);
    } else {
      await context.pushNamed('/syncplay-room/');
    }
  }

  void _handleRoomNotice(SyncPlayRoomNotice notice) {
    if (!mounted) {
      return;
    }
    switch (notice) {
      case SyncPlayRoomConnectionFailed(:final message):
        KazumiDialog.showToast(
          message: 'SyncPlay: $message',
          duration: const Duration(seconds: 5),
          showActionButton: true,
          actionLabel: '重新连接',
          onActionPressed: roomSession.retryConnection,
        );
      case SyncPlayRoomReconnecting():
        KazumiDialog.showToast(
          message: 'SyncPlay: 同步中断，正在重新连接',
          duration: const Duration(seconds: 3),
        );
      case SyncPlayRoomReconnected():
        KazumiDialog.showToast(
          message: 'SyncPlay: 已重新连接',
          duration: const Duration(seconds: 3),
        );
      case SyncPlayRoomInitialSync(:final username):
        if (username.isEmpty) {
          KazumiDialog.showToast(
            message: 'SyncPlay: 您是当前房间中的唯一用户',
            duration: const Duration(seconds: 5),
          );
        } else {
          KazumiDialog.showToast(
            message: 'SyncPlay: 您不是当前房间中的唯一用户, 当前以用户 $username 进度为准',
          );
        }
      case SyncPlayRoomRemoteMediaChanged():
        // PR1 keeps media events UI-neutral.  A future room page can render a
        // mismatch or follow prompt without changing the player lifecycle.
        break;
      case SyncPlayRoomRemotePlaybackChanged():
        break;
    }
  }

  bool get _windowIsLandscape {
    final Size window = MediaQuery.sizeOf(context);
    return window.width > window.height;
  }

  /// The fullscreen switch has two inputs, the window shape and the picture in
  /// picture state, and they arrive over different channels in either order, so
  /// it settles on both. A picture in picture window is not an orientation.
  void _syncFullscreenWithWindowShape() {
    if (isDesktop() || videoPageController.isPip) {
      return;
    }
    final bool landscape = _windowIsLandscape;
    if (landscape && !videoPageController.isFullscreen) {
      _hideTabBodyImmediately();
      videoPageController.enterFullScreen();
    } else if (!landscape && videoPageController.isFullscreen) {
      videoPageController.exitFullScreen();
      _showTabBodyImmediately();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didInitializePlayback) {
      return;
    }
    _didInitializePlayback = true;
    _initializePlayback();
  }

  void _initializePlayback() {
    if (videoPageController.isOfflineMode) {
      _initOfflineMode(playerController);
    } else {
      _initOnlineMode(playerController);
    }
  }

  void _initOfflineMode(PlayerController playerController) {
    final identity = videoPageController.currentHistoryIdentity;
    videoPageController.historyOffset = identity == null
        ? 0
        : videoPageController.getHistoryOffsetFor(identity);
    visibleRoad = videoPageController.selectedEpisode.road;
    _showTabBodyImmediately();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Future.delayed(_offlinePlayerInitDelay);
      if (!mounted) {
        return;
      }

      await changeEpisode(
        videoPageController.selectedEpisode.episode,
        currentRoad: videoPageController.selectedEpisode.road,
        offset: videoPageController.historyOffset,
      );
    });
  }

  void _initOnlineMode(PlayerController playerController) {
    videoPageController.historyOffset = 0;

    // A room-first route carries an authoritative room episode.  Do not let
    // local watch history replace it before the first asynchronous resolve.
    if (videoPageController.playbackLaunchIntent == null) {
      var progress = historyController.lastWatching(
          videoPageController.bangumiItem,
          videoPageController.currentPlugin.name);
      if (progress != null) {
        if (videoPageController.roadList.length > progress.road) {
          if (videoPageController.roadList[progress.road].data.length >=
              progress.episode) {
            videoPageController.resetEpisodeState(
              episode: progress.episode,
              road: progress.road,
            );
            if (playResume) {
              videoPageController.historyOffset = progress.progress.inSeconds;
            }
          }
        }
      }
    }
    visibleRoad = videoPageController.selectedEpisode.road;
    _showTabBodyImmediately();

    _logSubscription = videoPageController.logStream.listen((log) {
      if (mounted) {
        setState(() {
          webviewLogLines.add(log);
          if (webviewLogLines.length > 100) {
            webviewLogLines.removeAt(0);
          }
        });
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      changeEpisode(videoPageController.selectedEpisode.episode,
          currentRoad: videoPageController.selectedEpisode.road,
          offset: videoPageController.historyOffset);
    });
  }

  @override
  void dispose() {
    try {
      windowManager.removeListener(this);
    } catch (_) {}
    try {
      scrollController.dispose();
    } catch (_) {}
    try {
      animation.dispose();
    } catch (_) {}
    try {
      _syncNoticeSubscription?.cancel();
    } catch (_) {}
    try {
      _syncMediaSubscription?.cancel();
    } catch (_) {}
    try {
      _pendingInviteSubscription?.cancel();
    } catch (_) {}
    try {
      _logSubscription?.cancel();
    } catch (_) {}
    _pipModeListener();
    tabController.removeListener(handleTabChanged);
    roomSession.unregisterChatSurface(_chatSurfaceToken);
    // Cancellation and log-stream teardown happen in VideoPageController's
    // own dispose when Modular releases the route scope.
    if (!isDesktop()) {
      try {
        ScreenBrightnessPlatform.instance.resetApplicationScreenBrightness();
      } catch (_) {}
    }
    DisplayModeService.unlockScreenRotation();
    keyboardFocus.dispose();
    tabController.dispose();
    TimedShutdownService().cancel();
    super.dispose();
  }

  @override
  void onWindowEnterFullScreen() {
    _hideTabBodyImmediately();
    videoPageController.handleOnEnterFullScreen();
    syncChatVisibility();
  }

  @override
  void onWindowLeaveFullScreen() {
    videoPageController.handleOnExitFullScreen();
    syncChatVisibility();
  }

  void openSyncPlayChat() {
    unawaited(_openSyncPlayChat(forcePrompt: true));
  }

  Future<bool> _ensureSyncPlayQuickChatReady() async {
    if (videoPageController.isPip) return false;
    final ready = await playerController.ensureSyncPlayChatReady(
      forcePrompt: true,
      promptJoin: () async {
        if (!mounted) return;
        await showSyncPlaySheet(
          context,
          playerController: playerController,
          changeEpisode: _changeEpisodeFromRoom,
        );
      },
    );
    if (!mounted) return false;
    final session = playerController.syncplay;
    final connecting =
        session.connectionState == SyncPlayConnectionState.connecting ||
            session.connectionState == SyncPlayConnectionState.reconnecting;
    return ready || session.isChatConnected || session.hasSession || connecting;
  }

  Future<void> _openSyncPlayChat({required bool forcePrompt}) async {
    if (videoPageController.isPip) {
      return;
    }
    final ready = await playerController.ensureSyncPlayChatReady(
      forcePrompt: forcePrompt,
      promptJoin: () async {
        if (!mounted) {
          return;
        }
        await showSyncPlaySheet(
          context,
          playerController: playerController,
          changeEpisode: _changeEpisodeFromRoom,
        );
      },
    );
    if (!mounted) {
      return;
    }
    final session = playerController.syncplay;
    final connecting =
        session.connectionState == SyncPlayConnectionState.connecting ||
            session.connectionState == SyncPlayConnectionState.reconnecting;
    if (!ready &&
        !session.isChatConnected &&
        !session.hasSession &&
        !connecting) {
      return;
    }
    if (tabController.index != 2) {
      tabController.animateTo(2);
    }
    if (_isSideTabLayout && !_tabBodyTargetVisible) {
      _openTabBodyAnimated();
    } else {
      syncChatVisibility();
    }
  }

  void _joinSyncPlayRoomFromChat() {
    unawaited(_openSyncPlayChat(forcePrompt: true));
  }

  void syncChatVisibility() {
    if (!mounted) {
      return;
    }
    final bool chatTabVisible = tabController.index == 2;
    final bool contentVisible = _isSideTabLayout
        ? videoPageController.showTabBody && _tabBodyTargetVisible
        : videoPageController.showTabBody && !videoPageController.isFullscreen;
    roomSession.setChatSurfaceVisible(
      _chatSurfaceToken,
      chatTabVisible && contentVisible && !videoPageController.isPip,
    );
  }

  void handleTabChanged() {
    if (!mounted) {
      return;
    }
    if (tabController.index == 0) {
      menuJumpToCurrentEpisode();
    } else if (tabController.index == 2) {
      unawaited(_openSyncPlayChat(forcePrompt: false));
    }
    syncChatVisibility();
  }

  void showDebugConsole() {
    setState(() {
      showDebugLog = true;
    });
  }

  void hideDebugConsole() {
    setState(() {
      showDebugLog = false;
    });
  }

  void switchDebugConsole() {
    setState(() {
      showDebugLog = !showDebugLog;
    });
  }

  void clearWebviewLog() {
    setState(() {
      webviewLogLines.clear();
    });
  }

  Future<void> changeEpisode(int episode,
      {int currentRoad = 0, int offset = 0}) async {
    final currentEpisode = videoPageController.selectedEpisode.episode;
    if (episode != currentEpisode) {
      if (!roomSession.canControlLocalPlayback) {
        KazumiDialog.showToast(message: '当前由主持人控制选集');
        return;
      }
      final roomMedia = roomSession.currentMedia;
      final localBangumiId = playerController.currentBangumiId;
      final shouldSelectThroughRoom =
          roomSession.connectionState == SyncPlayConnectionState.connected &&
              roomSession.syncplayRoom.isNotEmpty &&
              roomSession.playbackParticipation ==
                  SyncPlayPlaybackParticipation.followingRoom &&
              roomSession.canSelectRoomMedia &&
              localBangumiId > 0 &&
              (roomMedia == null || roomMedia.bangumiId == localBangumiId);
      if (shouldSelectThroughRoom) {
        final selected = await roomSession.selectRoomMedia(
          bangumiId: localBangumiId,
          episode: episode,
          localRoad: currentRoad,
        );
        if (!selected && mounted) {
          KazumiDialog.showToast(message: '切换房间选集失败，请重试');
        }
        return;
      }
    }
    await _changeEpisodeInternal(
      episode,
      currentRoad: currentRoad,
      offset: offset,
    );
  }

  Future<void> _changeEpisodeFromRoom(
    int episode, {
    int currentRoad = 0,
    int offset = 0,
  }) {
    return _changeEpisodeInternal(
      episode,
      currentRoad: currentRoad,
      offset: offset,
    );
  }

  Future<void> _changeEpisodeInternal(
    int episode, {
    int currentRoad = 0,
    int offset = 0,
  }) async {
    if (!mounted) {
      return;
    }
    clearWebviewLog();
    hideDebugConsole();
    await videoPageController.changeEpisode(episode,
        currentRoad: currentRoad,
        offset: offset,
        playerController: playerController);
  }

  void menuJumpToCurrentEpisode() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // GridViewObserver binds its sliver context in its own post-frame callback.
      // Wait until the current frame's callbacks have all completed first.
      await Future<void>.delayed(Duration.zero);
      if (!mounted || !scrollController.hasClients) {
        return;
      }
      final int index = videoPageController.selectedEpisode.episode - 1;
      await observerController.jumpTo(
        index: index < 0 ? 0 : index,
        isFixedHeight: true,
      );
    });
  }

  bool get _isSideTabLayout => _windowIsLandscape;

  bool get _canAnimateSideTab =>
      mounted && _isSideTabLayout && !disableAnimations;

  void _openTabBodyAnimated() {
    _setTabBodyVisible(true, animated: true);
    menuJumpToCurrentEpisode();
  }

  void _closeTabBodyAnimated() {
    _setTabBodyVisible(false, animated: true);
    keyboardFocus.requestFocus();
  }

  void _toggleTabBodyAnimated() {
    if (_tabBodyTargetVisible) {
      _closeTabBodyAnimated();
    } else {
      _openTabBodyAnimated();
    }
  }

  void _showTabBodyImmediately() {
    _setTabBodyVisible(true, animated: false);
    menuJumpToCurrentEpisode();
  }

  void _hideTabBodyImmediately() {
    _setTabBodyVisible(false, animated: false);
  }

  void _setTabBodyVisible(bool visible, {required bool animated}) {
    _tabBodyTargetVisible = visible;
    final int animationRun = ++_tabBodyAnimationRun;

    if (visible) {
      if (!videoPageController.showTabBody) {
        animation.value = 0.0;
        videoPageController.showTabBody = true;
      }
      if (_canAnimateSideTab && animated) {
        animation.forward(from: animation.value);
      } else {
        animation.value = 1.0;
      }
      syncChatVisibility();
      return;
    }

    if (!videoPageController.showTabBody) {
      animation.value = 0.0;
      syncChatVisibility();
      return;
    }

    if (_canAnimateSideTab && animated && animation.value > 0.0) {
      animation.reverse().whenComplete(() {
        if (!mounted || animationRun != _tabBodyAnimationRun) {
          return;
        }
        videoPageController.showTabBody = false;
        animation.value = 0.0;
        syncChatVisibility();
      });
      return;
    }

    videoPageController.showTabBody = false;
    animation.value = 0.0;
    syncChatVisibility();
  }

  void _syncTabBodyAnimationAfterLayout() {
    if (!_tabBodyTargetVisible) {
      if (!videoPageController.showTabBody) {
        animation.value = 0.0;
      }
      return;
    }
    if (!videoPageController.showTabBody) {
      animation.value = 0.0;
      return;
    }
    if (!_isSideTabLayout || disableAnimations) {
      animation.value = 1.0;
      return;
    }
    if (animation.value == 0.0 && animation.status != AnimationStatus.reverse) {
      animation.forward();
    }
  }

  void onBackPressed(BuildContext context) async {
    if (KazumiDialog.observer.hasKazumiDialog) {
      KazumiDialog.dismiss();
      return;
    }
    if (videoPageController.isPip && isDesktop()) {
      PipUtils.exitDesktopPIPWindow();
      videoPageController.isPip = false;
      return;
    }
    if (videoPageController.isFullscreen && !isTablet()) {
      menuJumpToCurrentEpisode();
      await DisplayModeService.exitFullScreen();
      _hideTabBodyImmediately();
      videoPageController.isFullscreen = false;
      return;
    }
    if (videoPageController.isFullscreen) {
      await DisplayModeService.exitFullScreen();
      videoPageController.isFullscreen = false;
    }
    if (_isClosing) {
      return;
    }
    _isClosing = true;
    // VideoPage owns only the temporary playback binding.  The app-scoped
    // room session must survive navigation so the room, chat and selected
    // media remain available when the user opens another surface.
    playerController.beginShutdown();
    if (!context.mounted) {
      return;
    }
    context.pop();
  }

  void pauseForTimedShutdown() {
    if (playerController.playback.playing) {
      playerController.pause();
    }
  }

  Future<void> _handlePendingInvite(SyncPlayInvite invite) async {
    if (!mounted) return;
    if (inviteService.pending?.fingerprint != invite.fingerprint) {
      return;
    }
    await GStorage.putSetting<String>(
      SettingsKeys.syncPlayEndPoint,
      invite.server,
    );
    var username =
        GStorage.getSetting<String>(SettingsKeys.syncPlayUserName).trim();
    if (username.isEmpty) {
      username = 'Kazumi${DateTime.now().millisecondsSinceEpoch % 10000}';
      await GStorage.putSetting<String>(
        SettingsKeys.syncPlayUserName,
        username,
      );
    }
    await playerController.createSyncPlayRoom(
      invite.room,
      username,
      changeEpisode,
    );
    if (roomSession.connectionState == SyncPlayConnectionState.connected) {
      inviteService.takePending();
    }
  }

  bool sendDanmaku(String msg) {
    keyboardFocus.requestFocus();
    if (msg.isEmpty) {
      KazumiDialog.showToast(message: '弹幕内容为空');
      return false;
    } else if (msg.length > 100) {
      KazumiDialog.showToast(message: '弹幕内容过长');
      return false;
    }
    if (playerController.danmaku.danDanmakus.isEmpty) {
      KazumiDialog.showToast(
        message: '当前剧集不支持弹幕发送的说',
      );
      return false;
    }
    playerController.danmaku.canvasController
        .addDanmaku(DanmakuContentItem(msg, selfSend: true));

    return true;
  }

  Future<void> showMobileDanmakuInput() async {
    final message = await showMobileDanmakuInputSheet(context);

    if (!mounted || message == null) {
      return;
    }
    sendDanmaku(message);
  }

  @override
  Widget build(BuildContext context) {
    final bool isLandscape = _windowIsLandscape;
    _syncFullscreenWithWindowShape();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _syncTabBodyAnimationAfterLayout();
    });
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) {
          return;
        }
        onBackPressed(context);
      },
      child: Observer(builder: (context) {
        final bool isPip = videoPageController.isPip;
        final bool videoFillsWindow = isLandscape || isPip;
        return Scaffold(
          appBar: null,
          body: SafeArea(
              top: !videoPageController.isFullscreen && !isPip,
              // set iOS and Android navigation bar to immersive
              bottom: false,
              left: !videoPageController.isFullscreen && !isPip,
              right: !videoPageController.isFullscreen && !isPip,
              child: Stack(
                alignment: Alignment.centerRight,
                children: [
                  Column(
                    children: [
                      Flexible(
                        flex: videoFillsWindow ? 1 : 0,
                        child: Container(
                          color: Colors.black,
                          height: videoFillsWindow
                              ? MediaQuery.sizeOf(context).height
                              : MediaQuery.sizeOf(context).width * 9 / 16,
                          width: MediaQuery.sizeOf(context).width,
                          child: Focus(
                            focusNode: keyboardFocus,
                            autofocus: true,
                            child: playerBody,
                          ),
                        ),
                      ),
                      if (!videoFillsWindow) Expanded(child: tabBody),
                    ],
                  ),
                  if (isLandscape &&
                      videoPageController.showTabBody &&
                      !isPip) ...[
                    if (disableAnimations) ...[
                      sideTabMask,
                      sideTabBody,
                    ] else ...[
                      FadeTransition(
                        opacity: _maskOpacityAnimation,
                        child: sideTabMask,
                      ),
                      SlideTransition(
                        position: _rightOffsetAnimation,
                        child: sideTabBody,
                      ),
                    ],
                  ],
                ],
              )),
        );
      }),
    );
  }

  Widget get sideTabBody {
    return SizedBox(
      height: MediaQuery.sizeOf(context).height,
      width: (!isDesktop() && !isTablet())
          ? MediaQuery.sizeOf(context).height
          : (MediaQuery.sizeOf(context).width / 3 > 420
              ? 420
              : MediaQuery.sizeOf(context).width / 3),
      child: Container(
        color: Theme.of(context).canvasColor,
        child: (isDesktop() || isTablet())
            ? tabBody
            : AnimatedBuilder(
                animation: tabController,
                builder: (context, child) {
                  if (tabController.index == 2) {
                    return tabBody;
                  }
                  return GridViewObserver(
                    controller: observerController,
                    child: Column(
                      children: [
                        menuBar,
                        menuBody,
                      ],
                    ),
                  );
                },
              ),
      ),
    );
  }

  Widget get sideTabMask {
    return GestureDetector(
      onTap: _closeTabBodyAnimated,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [
              Colors.black.withValues(alpha: 0.5),
              Colors.transparent,
            ],
          ),
        ),
        width: double.infinity,
        height: double.infinity,
      ),
    );
  }

  Widget get playerBody {
    final bool playerLoading = playerController.playback.loading;
    return Stack(
      children: [
        Positioned.fill(
          child: Stack(
            children: [
              if (videoPageController.loading ||
                  playerLoading ||
                  videoPageController.errorMessage != null)
                Container(
                  color: Colors.black,
                  child: Observer(builder: (context) {
                    return Center(
                      child: videoPageController.errorMessage != null
                          ? Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.error_outline,
                                    color: Theme.of(context).colorScheme.error,
                                    size: 48),
                                const SizedBox(height: 16),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 32),
                                  child: Text(
                                    videoPageController.errorMessage!,
                                    style: const TextStyle(
                                        color: Colors.white, fontSize: 16),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ],
                            )
                          : Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                CircularProgressIndicator(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .tertiaryContainer),
                                const SizedBox(height: 10),
                                Text(
                                  videoPageController.loading
                                      ? '视频资源解析中'
                                      : '视频资源解析成功, 播放器加载中',
                                  style: const TextStyle(color: Colors.white),
                                ),
                              ],
                            ),
                    );
                  }),
                ),
              Visibility(
                visible: (videoPageController.loading || playerLoading) &&
                    showDebugLog,
                child: Container(
                  color: Colors.black,
                  child: Align(
                    alignment: Alignment.center,
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: webviewLogLines.length,
                      itemBuilder: (context, index) {
                        return Text(
                          webviewLogLines.isEmpty ? '' : webviewLogLines[index],
                          style: const TextStyle(
                            color: Colors.white,
                          ),
                          textAlign: TextAlign.center,
                        );
                      },
                    ),
                  ),
                ),
              ),
              Stack(
                children: [
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: EmbeddedNativeControlArea(
                      requireOffset: !videoPageController.isFullscreen,
                      child: Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.arrow_back,
                                color: Colors.white),
                            onPressed: () => onBackPressed(context),
                          ),
                          const Expanded(
                              child: dtb.DragToMoveArea(
                                  child: SizedBox(height: 40))),
                          IconButton(
                            icon: const Icon(Icons.refresh_outlined,
                                color: Colors.white),
                            onPressed: () {
                              changeEpisode(
                                  videoPageController.selectedEpisode.episode,
                                  currentRoad:
                                      videoPageController.selectedEpisode.road);
                            },
                          ),
                          Visibility(
                            visible: MediaQuery.sizeOf(context).width >
                                MediaQuery.sizeOf(context).height,
                            child: IconButton(
                              onPressed: () {
                                _toggleTabBodyAnimated();
                              },
                              icon: Icon(
                                _tabBodyTargetVisible
                                    ? Icons.menu_open
                                    : Icons.menu_open_outlined,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: Icon(
                                showDebugLog
                                    ? Icons.bug_report
                                    : Icons.bug_report_outlined,
                                color: Colors.white),
                            onPressed: () {
                              switchDebugConsole();
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        Positioned.fill(
          child: playerController.playback.loading
              ? Container()
              : PlayerItem(
                  playerController: playerController,
                  videoPageController: videoPageController,
                  toggleMenu: _toggleTabBodyAnimated,
                  showMenuImmediately: _showTabBodyImmediately,
                  hideMenuImmediately: _hideTabBodyImmediately,
                  changeEpisode: changeEpisode,
                  onBackPressed: onBackPressed,
                  keyboardFocus: keyboardFocus,
                  sendDanmaku: sendDanmaku,
                  openSyncPlayChat: openSyncPlayChat,
                  ensureSyncPlayQuickChatReady: _ensureSyncPlayQuickChatReady,
                  disableAnimations: disableAnimations,
                  pauseForTimedShutdown: pauseForTimedShutdown,
                ),
        ),
      ],
    );
  }

  Widget get menuBar {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text(' 合集 '),
          Expanded(
            child: Text(
              videoPageController.title,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
          ),
          const SizedBox(width: 10),
          MenuAnchor(
            consumeOutsideTap: true,
            builder: (_, MenuController controller, __) {
              return SizedBox(
                height: 34,
                child: TextButton(
                  style: ButtonStyle(
                    padding: WidgetStateProperty.all(EdgeInsets.zero),
                  ),
                  onPressed: () {
                    if (controller.isOpen) {
                      controller.close();
                    } else {
                      controller.open();
                    }
                  },
                  child: Text(
                    visibleRoad >= 0 &&
                            visibleRoad < videoPageController.roadList.length
                        ? '${videoPageController.roadList[visibleRoad].name} '
                        : '播放线路${visibleRoad + 1} ',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              );
            },
            menuChildren: List<MenuItemButton>.generate(
              videoPageController.roadList.length,
              (int i) => MenuItemButton(
                onPressed: () {
                  setState(() {
                    visibleRoad = i;
                  });
                },
                child: Container(
                  height: 48,
                  constraints: BoxConstraints(minWidth: 112),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      videoPageController.roadList[i].name,
                      style: TextStyle(
                        color: i == visibleRoad
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  DownloadEpisode? _getEpisodeFromRecords(
      int episodeNumber, String episodePageUrl) {
    final bangumiId = videoPageController.bangumiItem.id;
    final pluginName = videoPageController.currentPlugin.name;

    for (final record in downloadController.records) {
      if (record.bangumiId == bangumiId && record.pluginName == pluginName) {
        if (episodePageUrl.isNotEmpty) {
          for (final episode in record.episodes.values) {
            if (episode.episodePageUrl == episodePageUrl) {
              return episode;
            }
          }
        }
        return record.episodes[episodeNumber];
      }
    }
    return null;
  }

  Widget _buildDownloadStatusIcon(int episodeNumber, String episodePageUrl) {
    if (videoPageController.isOfflineMode) return const SizedBox.shrink();
    final episode = _getEpisodeFromRecords(episodeNumber, episodePageUrl);
    if (episode == null) return const SizedBox.shrink();
    switch (episode.status) {
      case DownloadStatus.completed:
        return Icon(Icons.offline_pin,
            size: 16, color: Theme.of(context).colorScheme.primary);
      case DownloadStatus.downloading:
        return SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
            value: episode.progressPercent,
            strokeWidth: 2,
          ),
        );
      case DownloadStatus.failed:
        return Icon(Icons.error_outline,
            size: 16, color: Theme.of(context).colorScheme.error);
      case DownloadStatus.paused:
        return Icon(Icons.pause_circle_outline,
            size: 16, color: Theme.of(context).colorScheme.outline);
      case DownloadStatus.pending:
      case DownloadStatus.resolving:
        return SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  Widget get menuBody {
    return Observer(
      builder: (context) {
        var cardList = <Widget>[];
        if (visibleRoad >= 0 &&
            visibleRoad < videoPageController.roadList.length) {
          final road = videoPageController.roadList[visibleRoad];
          int count = 1;
          for (var urlItem in road.data) {
            int count0 = count;
            final episodeName = count0 - 1 < road.identifier.length
                ? road.identifier[count0 - 1]
                : '第$count0集';
            cardList.add(Container(
              margin: const EdgeInsets.only(bottom: 4),
              child: Material(
                color: Theme.of(context).colorScheme.onInverseSurface,
                borderRadius: BorderRadius.circular(6),
                clipBehavior: Clip.hardEdge,
                child: InkWell(
                  onTap: () async {
                    if (count0 == videoPageController.selectedEpisode.episode &&
                        videoPageController.selectedEpisode.road ==
                            visibleRoad) {
                      return;
                    }
                    KazumiLogger()
                        .i('VideoPageController: video URL is $urlItem');
                    _closeTabBodyAnimated();
                    changeEpisode(count0, currentRoad: visibleRoad);
                  },
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: [
                            if (count0 ==
                                    (videoPageController
                                        .selectedEpisode.episode) &&
                                visibleRoad ==
                                    videoPageController
                                        .selectedEpisode.road) ...<Widget>[
                              Image.asset(
                                'assets/images/playing.gif',
                                color: Theme.of(context).colorScheme.primary,
                                height: 12,
                              ),
                              const SizedBox(width: 6)
                            ],
                            Expanded(
                                child: Text(
                              episodeName,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 13,
                                  color: (count0 ==
                                              videoPageController
                                                  .selectedEpisode.episode &&
                                          visibleRoad ==
                                              videoPageController
                                                  .selectedEpisode.road)
                                      ? Theme.of(context).colorScheme.primary
                                      : Theme.of(context)
                                          .colorScheme
                                          .onSurface),
                            )),
                            _buildDownloadStatusIcon(count0, urlItem),
                            const SizedBox(width: 2),
                          ],
                        ),
                        const SizedBox(height: 3),
                      ],
                    ),
                  ),
                ),
              ),
            ));
            count++;
          }
        }
        return Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 0, right: 8, left: 8),
            child: GridView.builder(
              scrollDirection: Axis.vertical,
              controller: scrollController,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 10,
                mainAxisSpacing: 5,
                mainAxisExtent: 70,
              ),
              itemCount: cardList.length,
              itemBuilder: (context, index) {
                return cardList[index];
              },
            ),
          ),
        );
      },
    );
  }

  Widget _buildMobileDanmakuCapsule(BuildContext context, bool danmakuOn) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(25),
        border: Border.all(
          color: danmakuOn
              ? Theme.of(context).hintColor
              : Theme.of(context).disabledColor,
          width: 0.5,
        ),
      ),
      child: GestureDetector(
        onTap: () {
          if (danmakuOn && !videoPageController.loading) {
            showMobileDanmakuInput();
          } else if (videoPageController.loading) {
            KazumiDialog.showToast(message: '请等待视频加载完成');
          } else {
            KazumiDialog.showToast(message: '请先打开弹幕');
          }
        },
        child: Row(
          children: [
            Text(
              danmakuOn ? '  点我发弹幕  ' : '  已关闭弹幕  ',
              softWrap: false,
              overflow: TextOverflow.clip,
              style: TextStyle(
                color: danmakuOn
                    ? Theme.of(context).hintColor
                    : Theme.of(context).disabledColor,
              ),
            ),
            if (danmakuOn)
              Icon(
                Icons.send_rounded,
                size: 20,
                color: Theme.of(context).hintColor,
              ),
          ],
        ),
      ),
    );
  }

  Widget get tabBody {
    final bool danmakuOn = playerController.danmaku.danmakuOn;
    final int episodeNum = videoPageController.commentsEpisode;
    final bool compactTabs =
        MediaQuery.sizeOf(context).width <= MediaQuery.sizeOf(context).height;

    return Container(
      color: Theme.of(context).canvasColor,
      child: DefaultTabController(
        length: 3,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Flexible(
                  child: TabBar(
                    controller: tabController,
                    dividerHeight: 0,
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    labelPadding: EdgeInsetsDirectional.only(
                      start: compactTabs ? 16 : 30,
                      end: compactTabs ? 16 : 30,
                    ),
                    onTap: (index) {
                      if (index == 0) {
                        menuJumpToCurrentEpisode();
                      }
                    },
                    tabs: [
                      const Tab(text: '选集'),
                      const Tab(text: '评论'),
                      Observer(
                        builder: (context) {
                          final syncplay = playerController.syncplay;
                          final unread = syncplay.unreadChatCount;
                          final mentions = syncplay.unreadMentionCount;
                          return Tab(
                            child: Badge(
                              isLabelVisible: unread > 0,
                              label: Text(
                                mentions > 0
                                    ? '@${mentions > 99 ? '99+' : mentions}'
                                    : (unread > 99 ? '99+' : '$unread'),
                              ),
                              child: const Text('聊天'),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
                if (compactTabs)
                  AnimatedBuilder(
                    animation: tabController,
                    builder: (context, child) {
                      final hideForMobileChat = !isDesktop() &&
                          !isTablet() &&
                          tabController.index == 2;
                      if (hideForMobileChat) {
                        return const SizedBox.shrink();
                      }
                      return _buildMobileDanmakuCapsule(context, danmakuOn);
                    },
                  ),
                if (compactTabs) const Spacer(),
                IconButton(
                  tooltip: '关闭侧栏',
                  onPressed: _hideTabBodyImmediately,
                  icon: const Icon(Icons.close_rounded),
                ),
                const SizedBox(width: 8),
              ],
            ),
            Divider(height: isDesktop() ? 0.5 : 0.2),
            Expanded(
              child: TabBarView(
                controller: tabController,
                children: [
                  Stack(
                    children: [
                      GridViewObserver(
                        controller: observerController,
                        child: Column(
                          children: [
                            menuBar,
                            menuBody,
                          ],
                        ),
                      ),
                      if (!videoPageController.isOfflineMode)
                        Positioned(
                          right: 16,
                          bottom: 16,
                          child: FloatingActionButton(
                            child: const Icon(Icons.download_rounded),
                            onPressed: () {
                              showAdaptiveBottomSheet<void>(
                                context: context,
                                builder: (context) => DownloadEpisodeSheet(
                                  road: visibleRoad,
                                  videoPageController: videoPageController,
                                ),
                              );
                            },
                          ),
                        ),
                    ],
                  ),
                  EpisodeCommentsSheet(
                    episode: episodeNum,
                    selection: videoPageController.selectedEpisode,
                    videoPageController: videoPageController,
                  ),
                  SyncPlayChatPanel(
                    controller: playerController.syncplay,
                    onSend: roomSession.trySendChatMessage,
                    chatDanmakuController: playerController.chatDanmaku,
                    inviteTextBuilder: playerController.syncPlayInviteText,
                    compact: !isDesktop() && !isTablet(),
                    onReconnect: playerController.syncplay.retryConnection,
                    onClearHistory: playerController.syncplay.clearChatHistory,
                    onJoinRoom: _joinSyncPlayRoomFromChat,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
