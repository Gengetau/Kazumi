import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:kazumi/bean/dialog/adaptive_bottom_sheet.dart';
import 'package:kazumi/bean/card/network_img_layer.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/navigation.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/pages/info/info_controller.dart';
import 'package:kazumi/pages/info/source_sheet.dart';
import 'package:kazumi/pages/player/controller/player_models.dart';
import 'package:kazumi/pages/player/syncplay_chat_panel.dart';
import 'package:kazumi/pages/player/syncplay_room_legacy_ui.dart' as legacy;
import 'package:kazumi/pages/syncplay_room/media_picker/syncplay_room_media_selection.dart';
import 'package:kazumi/pages/syncplay_room/room_playback_host.dart';
import 'package:kazumi/pages/video/video_playback_args.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';
import 'package:kazumi/services/player/syncplay_endpoint.dart';
import 'package:kazumi/services/player/syncplay_clipboard_invite_service.dart';
import 'package:kazumi/services/player/syncplay_invite.dart';
import 'package:kazumi/services/player/syncplay_managed_room_models.dart';
import 'package:kazumi/services/player/syncplay_room_models.dart';
import 'package:kazumi/services/player/syncplay_room_session_controller.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/async_session.dart';

enum _SyncPlayRoomMenuAction {
  copyInvite,
  authenticateOperator,
  copyOperatorPassword,
  serverInfo,
  clearHistory,
  exitRoom,
}

/// Persistent room-first entry point for SyncPlay.
///
/// The page owns only its chat surface registration. The socket, messages,
/// unread state and shared media choice remain in the app-scoped session, so
/// navigating between this page and VideoPage never creates a second room.
class SyncPlayRoomPage extends StatefulWidget {
  const SyncPlayRoomPage({
    super.key,
    required this.roomSession,
    this.bangumiInfoLoader,
  });

  final SyncPlayRoomSessionController roomSession;
  final Future<BangumiItem?> Function(int bangumiId)? bangumiInfoLoader;

  @override
  State<SyncPlayRoomPage> createState() => _SyncPlayRoomPageState();
}

/// Short alias for callers that use the document's `RoomPage` name.
typedef RoomPage = SyncPlayRoomPage;

class _SyncPlayRoomPageState extends State<SyncPlayRoomPage> with RouteAware {
  SyncPlayRoomSessionController get roomSession => widget.roomSession;

  late final Object _chatSurface;
  late final StreamSubscription<SyncPlayRoomMediaEvent> _mediaSubscription;
  final AsyncSessionOwner _mediaInfoSessions = AsyncSessionOwner();
  BangumiItem? _mediaInfoBangumi;
  String? _mediaInfoRoom;
  int? _mediaInfoGeneration;
  bool _mediaInfoLoading = false;
  String? _mediaInfoError;
  OnlineVideoPlaybackArgs? _playbackArgs;
  bool _sourceSheetOpen = false;
  String? _playbackSelectionError;

  @override
  void initState() {
    super.initState();
    _chatSurface = roomSession.registerChatSurface();
    roomSession.setChatSurfaceVisible(_chatSurface, true);
    _mediaSubscription = roomSession.mediaEvents.listen(_onMediaEvent);
    final media = roomSession.currentMedia;
    if (media != null) {
      unawaited(_loadMediaInfo(media));
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<void>) {
      rootRouteObserver.subscribe(this, route);
    }
  }

  @override
  void didPushNext() {
    roomSession.setChatSurfaceVisible(_chatSurface, false);
  }

  @override
  void didPopNext() {
    roomSession.setChatSurfaceVisible(_chatSurface, true);
  }

  @override
  void dispose() {
    // A page disappearing is not an explicit room exit. The app-scoped
    // session and socket must remain available to the next room surface.
    rootRouteObserver.unsubscribe(this);
    roomSession.unregisterChatSurface(_chatSurface);
    unawaited(_mediaSubscription.cancel());
    _mediaInfoSessions.close();
    super.dispose();
  }

  void _onMediaEvent(SyncPlayRoomMediaEvent event) {
    if (event is SyncPlayRoomMediaChanged) {
      final playbackBangumiId = _playbackArgs?.bangumiItem.id;
      if (playbackBangumiId != null &&
          playbackBangumiId != event.media.bangumiId &&
          mounted) {
        setState(() {
          _playbackArgs = null;
          _playbackSelectionError = null;
        });
      }
      unawaited(_loadMediaInfo(event.media));
    }
  }

  Future<void> _loadMediaInfo(
    SyncPlayRoomMedia media, {
    bool force = false,
  }) async {
    final room = roomSession.syncplayRoom;
    if (media.bangumiId <= 0 || media.episode <= 0 || room.isEmpty) {
      return;
    }
    final sameMedia =
        _mediaInfoRoom == room &&
        _mediaInfoGeneration == media.generation &&
        (_mediaInfoBangumi?.id == media.bangumiId || _mediaInfoBangumi == null);
    if (!force &&
        sameMedia &&
        (_mediaInfoLoading ||
            _mediaInfoBangumi != null ||
            _mediaInfoError != null)) {
      return;
    }

    final session = _mediaInfoSessions.begin();
    if (mounted) {
      setState(() {
        _mediaInfoRoom = room;
        _mediaInfoGeneration = media.generation;
        _mediaInfoBangumi = null;
        _mediaInfoLoading = true;
        _mediaInfoError = null;
      });
    }
    BangumiItem? bangumi;
    try {
      bangumi =
          await (widget.bangumiInfoLoader ?? BangumiApi.getBangumiInfoByID)(
            media.bangumiId,
          );
    } catch (_) {
      bangumi = null;
    }
    if (!session.isActive || !mounted) {
      return;
    }
    final current = roomSession.currentMedia;
    if (current == null ||
        current.generation != media.generation ||
        current.bangumiId != media.bangumiId ||
        current.episode != media.episode ||
        roomSession.syncplayRoom != room) {
      return;
    }
    setState(() {
      _mediaInfoBangumi = bangumi;
      _mediaInfoLoading = false;
      _mediaInfoError = bangumi == null ? '番剧信息加载失败' : null;
    });
  }

  void _retryMediaInfo() {
    final media = roomSession.currentMedia;
    if (media != null) {
      unawaited(_loadMediaInfo(media, force: true));
    }
  }

  void _cacheSelectedMedia(
    SyncPlayRoomMediaSelection selection,
    SyncPlayRoomMedia media,
  ) {
    _mediaInfoSessions.cancel();
    if (!mounted) return;
    setState(() {
      _mediaInfoRoom = roomSession.syncplayRoom;
      _mediaInfoGeneration = media.generation;
      _mediaInfoBangumi = selection.bangumi;
      _mediaInfoLoading = false;
      _mediaInfoError = null;
    });
  }

  Future<void> _openMediaPicker() async {
    if (roomSession.connectionState != SyncPlayConnectionState.connected ||
        roomSession.syncplayRoom.isEmpty ||
        !roomSession.canSelectRoomMedia) {
      return;
    }
    final result = await context.pushNamed('/syncplay-room/media-picker');
    if (!mounted || result is! SyncPlayRoomMediaSelection) {
      return;
    }
    final selection = result;
    final success = await roomSession.selectRoomMedia(
      bangumiId: selection.bangumi.id,
      episode: selection.episode,
    );
    if (!mounted) return;
    if (!success) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('房间未确认媒体选择，请重试')));
      return;
    }
    final media = roomSession.currentMedia;
    if (media != null &&
        media.bangumiId == selection.bangumi.id &&
        media.episode == selection.episode) {
      _cacheSelectedMedia(selection, media);
      if (_playbackArgs?.bangumiItem.id != selection.bangumi.id) {
        await _choosePlaybackSource();
      }
    } else if (media != null) {
      unawaited(_loadMediaInfo(media, force: true));
    }
  }

  Future<void> _choosePlaybackSource() async {
    final media = roomSession.currentMedia;
    final bangumi = _mediaInfoBangumi;
    if (media == null || bangumi == null || _sourceSheetOpen) {
      return;
    }
    final launchIntent = SyncPlayPlaybackLaunchIntent(
      expectedBangumiId: media.bangumiId,
      expectedEpisode: media.episode,
      expectedMediaGeneration: media.generation,
    );
    if (!roomSession.isPlaybackLaunchIntentCurrent(launchIntent)) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('房间媒体刚刚更新，请刷新后再进入播放')));
      }
      return;
    }
    final infoController = InfoController(inject<CollectController>())
      ..bangumiItem = bangumi;
    OnlineVideoPlaybackArgs? selectedArgs;
    setState(() {
      _sourceSheetOpen = true;
      _playbackSelectionError = null;
    });
    try {
      await showAdaptiveBottomSheet<void>(
        context: context,
        maxHeightFactor: 0.85,
        compactLandscapeMaxHeightFactor: 0.95,
        builder: (sheetContext) => SourceSheet(
          infoController: infoController,
          playbackLaunchIntent: launchIntent,
          onPlaybackSelected: (args) {
            selectedArgs = args;
            Navigator.of(sheetContext).pop();
          },
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _sourceSheetOpen = false);
      }
    }
    if (!mounted || selectedArgs == null) return;
    if (!roomSession.isPlaybackLaunchIntentCurrent(launchIntent)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('房间媒体已经更新，请重新选择播放源')));
      setState(() => _playbackSelectionError = '房间媒体已更新，请重新选择播放源');
      return;
    }
    setState(() {
      _playbackArgs = selectedArgs;
      _playbackSelectionError = null;
    });
  }

  Future<void> _joinClipboardInvite(SyncPlayInvite invite) async {
    inject<SyncPlayClipboardInviteService>().takePending();
    await GStorage.putSetting<String>(
      SettingsKeys.syncPlayEndPoint,
      invite.server,
    );
    var username = '';
    try {
      username = GStorage.getSetting<String>(
        SettingsKeys.syncPlayUserName,
      ).trim();
    } catch (_) {}
    if (username.isEmpty) {
      username = 'Kazumi${DateTime.now().millisecondsSinceEpoch % 10000}';
      await GStorage.putSetting<String>(
        SettingsKeys.syncPlayUserName,
        username,
      );
    }
    await roomSession.createRoom(invite.room, username);
  }

  String _endpoint() {
    try {
      final endpoint = GStorage.getSetting<String>(
        SettingsKeys.syncPlayEndPoint,
      );
      return endpoint.isEmpty ? defaultSyncPlayEndPoint : endpoint;
    } catch (_) {
      return defaultSyncPlayEndPoint;
    }
  }

  String _connectionLabel(SyncPlayConnectionState state) {
    return switch (state) {
      SyncPlayConnectionState.disconnected => '未连接',
      SyncPlayConnectionState.connecting => '正在连接',
      SyncPlayConnectionState.connected => '已连接',
      SyncPlayConnectionState.reconnecting => '正在重新连接',
      SyncPlayConnectionState.failed => '连接失败',
    };
  }

  String _roomControlLabel() {
    if (!roomSession.isManagedRoom) {
      return '自由控制';
    }
    if (roomSession.operatorAuthState ==
        SyncPlayOperatorAuthState.authenticating) {
      return '房主控制 · 正在恢复主持身份';
    }
    final operatorCount = roomSession.roomUsers.values
        .where((user) => user.isController)
        .length;
    if (operatorCount == 0) {
      return '房主控制 · 暂无主持人';
    }
    if (roomSession.isRoomOperator) {
      return operatorCount == 1 ? '房主控制 · 你是主持人' : '房主控制 · $operatorCount 位主持人';
    }
    return '房主控制 · $operatorCount 位主持人';
  }

  Future<void> _showCreateForm() async {
    await showAdaptiveBottomSheet<void>(
      context: context,
      maxHeightFactor: 0.8,
      compactLandscapeMaxHeightFactor: 0.95,
      builder: (context) => legacy.SyncPlayCreateRoomForm(
        onSubmit: (room, username, mode) async {
          if (mode == SyncPlayRoomControlMode.managed) {
            await roomSession.createManagedRoom(room, username);
            return;
          }
          await roomSession.createRoom(room, username);
        },
      ),
    );
  }

  Future<void> _showJoinForm() async {
    await showAdaptiveBottomSheet<void>(
      context: context,
      maxHeightFactor: 0.8,
      compactLandscapeMaxHeightFactor: 0.95,
      builder: (context) => legacy.SyncPlayJoinRoomForm(
        onSubmit: (room, username) => roomSession.createRoom(room, username),
      ),
    );
  }

  Future<void> _showServerForm() async {
    await showAdaptiveBottomSheet<void>(
      context: context,
      maxHeightFactor: 0.8,
      compactLandscapeMaxHeightFactor: 0.95,
      builder: (context) => legacy.SyncPlayServerForm(
        onSaved: roomSession.connectionState == SyncPlayConnectionState.failed
            ? roomSession.retryConnection
            : null,
      ),
    );
  }

  Future<void> _copyInvite() async {
    if (roomSession.syncplayRoom.isEmpty) {
      return;
    }
    await Clipboard.setData(
      ClipboardData(text: roomSession.syncPlayInviteText()),
    );
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('邀请信息已复制')));
  }

  Future<void> _copyOperatorPassword() async {
    final password = roomSession.operatorPassword;
    if (password == null || password.isEmpty || !roomSession.isRoomOperator) {
      return;
    }
    await Clipboard.setData(ClipboardData(text: password));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('主持密码已复制，请仅私下分享给可信成员')));
  }

  Future<void> _showOperatorAuthentication() async {
    final controller = TextEditingController();
    String? passwordError;
    final password = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('成为共同主持人'),
          content: TextField(
            controller: controller,
            autofocus: true,
            obscureText: true,
            textCapitalization: TextCapitalization.characters,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9-]')),
              LengthLimitingTextInputFormatter(10),
            ],
            decoration: InputDecoration(
              labelText: '主持密码',
              hintText: 'AB-123-456',
              helperText: '密码由当前主持人私下提供',
              errorText: passwordError,
            ),
            onChanged: (_) {
              if (passwordError != null) {
                setDialogState(() => passwordError = null);
              }
            },
            onSubmitted: (value) {
              final normalized = normalizeSyncPlayOperatorPassword(value);
              if (isSyncPlayOperatorPasswordValid(normalized)) {
                Navigator.of(context).pop(normalized);
              } else {
                setDialogState(() => passwordError = '请输入 AB-123-456 格式的主持密码');
              }
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final normalized = normalizeSyncPlayOperatorPassword(
                  controller.text,
                );
                if (!isSyncPlayOperatorPasswordValid(normalized)) {
                  setDialogState(
                    () => passwordError = '请输入 AB-123-456 格式的主持密码',
                  );
                  return;
                }
                Navigator.of(context).pop(normalized);
              },
              child: const Text('认证'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (password == null || !mounted) {
      return;
    }
    final success = await roomSession.authenticateAsOperator(password);
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(success ? '已成为共同主持人' : '主持密码无效或认证超时')),
    );
  }

  Future<void> _showServerInfo() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('同步服务器'),
        content: SelectableText(_endpoint()),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmExitRoom() async {
    final operatorCount = roomSession.roomUsers.values
        .where((user) => user.isController)
        .length;
    final isUniqueOperator =
        roomSession.isManagedRoom &&
        roomSession.isRoomOperator &&
        operatorCount <= 1;
    final isOneOfMultipleOperators =
        roomSession.isManagedRoom &&
        roomSession.isRoomOperator &&
        operatorCount > 1;
    final shouldExit = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isUniqueOperator ? '你是当前唯一主持人' : '退出聊天室？'),
        content: Text(
          isUniqueOperator
              ? '退出后聊天室不会解散，但其他成员将无法控制共享播放，直到有人使用主持密码重新认证。'
              : isOneOfMultipleOperators
              ? '退出后其他主持人仍可继续控制房间。'
              : '退出聊天室后将停止同步并清除当前聊天记录。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(isUniqueOperator ? '仍然退出' : '退出聊天室'),
          ),
        ],
      ),
    );
    if (shouldExit != true) {
      return;
    }
    await roomSession.exitRoom();
  }

  void _onMenuAction(_SyncPlayRoomMenuAction action) {
    switch (action) {
      case _SyncPlayRoomMenuAction.copyInvite:
        unawaited(_copyInvite());
      case _SyncPlayRoomMenuAction.authenticateOperator:
        unawaited(_showOperatorAuthentication());
      case _SyncPlayRoomMenuAction.copyOperatorPassword:
        unawaited(_copyOperatorPassword());
      case _SyncPlayRoomMenuAction.serverInfo:
        unawaited(_showServerInfo());
      case _SyncPlayRoomMenuAction.clearHistory:
        roomSession.clearChatHistory();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('本地聊天记录已清空')));
      case _SyncPlayRoomMenuAction.exitRoom:
        unawaited(_confirmExitRoom());
    }
  }

  Widget _buildMenu(String room) {
    final showAuthenticate =
        roomSession.isManagedRoom &&
        !roomSession.isRoomOperator &&
        roomSession.connectionState == SyncPlayConnectionState.connected;
    final showCopyPassword =
        roomSession.isRoomOperator &&
        (roomSession.operatorPassword?.isNotEmpty ?? false);
    return PopupMenuButton<_SyncPlayRoomMenuAction>(
      tooltip: '房间操作',
      onSelected: _onMenuAction,
      itemBuilder: (context) => [
        PopupMenuItem(
          value: _SyncPlayRoomMenuAction.copyInvite,
          enabled: room.isNotEmpty,
          child: const Text('复制邀请'),
        ),
        if (showAuthenticate)
          const PopupMenuItem(
            value: _SyncPlayRoomMenuAction.authenticateOperator,
            child: Text('成为共同主持人'),
          ),
        if (showCopyPassword)
          const PopupMenuItem(
            value: _SyncPlayRoomMenuAction.copyOperatorPassword,
            child: Text('复制主持密码'),
          ),
        const PopupMenuItem(
          value: _SyncPlayRoomMenuAction.serverInfo,
          child: Text('服务器信息'),
        ),
        const PopupMenuItem(
          value: _SyncPlayRoomMenuAction.clearHistory,
          child: Text('清空本地聊天记录'),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: _SyncPlayRoomMenuAction.exitRoom,
          child: Text('退出聊天室'),
        ),
      ],
    );
  }

  /// The upper half of a connected room is reserved for video, not a Card.
  /// Keep this host mounted independently of the scrollable media controls.
  Widget _buildPlaybackStage(BuildContext context, SyncPlayRoomMedia? media) {
    final args = _playbackArgs;
    if (media != null &&
        args != null &&
        args.bangumiItem.id == media.bangumiId) {
      return RoomPlaybackHost(
        key: ValueKey('${args.plugin.name}:${args.src}:${args.bangumiItem.id}'),
        args: args,
        roomSession: roomSession,
        fillStage: true,
        onClose: () {
          if (!mounted) return;
          setState(() => _playbackArgs = null);
        },
      );
    }

    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.smart_display_outlined,
              size: 52,
              color: Colors.white70,
            ),
            const SizedBox(height: 12),
            Text(
              media == null ? '暂未选择番剧' : '视频将在这里播放',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(color: Colors.white),
            ),
            const SizedBox(height: 6),
            Text(
              media == null ? '选择一部番剧开始一起看' : '请在下方选择播放源',
              style: const TextStyle(color: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }

  /// Compact controls below the video; never shrink the playback stage.
  Widget _buildMediaDetails(BuildContext context, SyncPlayRoomMedia? media) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    if (media == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Row(
          children: [
            Text('当前观看', style: theme.textTheme.titleSmall),
            const Spacer(),
            OutlinedButton(
              onPressed: roomSession.canSelectRoomMedia
                  ? _openMediaPicker
                  : null,
              child: Text(roomSession.canSelectRoomMedia ? '选择番剧' : '等待主持人选择'),
            ),
          ],
        ),
      );
    }

    final selectedBy = media.selectedBy.isEmpty ? '房间成员' : media.selectedBy;
    final bangumi = _mediaInfoBangumi;
    final title = bangumi == null
        ? 'Bangumi #${media.bangumiId}'
        : (bangumi.nameCn.trim().isNotEmpty
              ? bangumi.nameCn.trim()
              : (bangumi.name.trim().isNotEmpty
                    ? bangumi.name.trim()
                    : 'Bangumi #${media.bangumiId}'));
    final imageUrl = bangumi?.images['large'] ?? '';
    final playbackArgs = _playbackArgs;
    final hasEmbeddedPlayback =
        playbackArgs != null && playbackArgs.bangumiItem.id == media.bangumiId;
    final playbackStateLabel = switch ((
      _mediaInfoLoading,
      _mediaInfoError,
      _sourceSheetOpen,
      hasEmbeddedPlayback,
      _playbackSelectionError,
    )) {
      (true, _, _, _, _) => '正在解析房间媒体',
      (_, String(), _, _, _) => '房间媒体解析失败',
      (_, _, true, _, _) => '正在选择播放源',
      (_, _, _, true, _) => '播放就绪',
      (_, _, _, _, String()) => '播放源需要重新选择',
      _ => '等待选择播放源',
    };

    final cover = imageUrl.isEmpty
        ? CircleAvatar(child: Text('${media.bangumiId}'))
        : NetworkImgLayer(src: imageUrl, width: 42, height: 50);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text('当前观看', style: theme.textTheme.labelMedium),
              const Spacer(),
              Icon(
                hasEmbeddedPlayback
                    ? Icons.play_circle_fill_rounded
                    : Icons.pending_outlined,
                size: 16,
                color: hasEmbeddedPlayback
                    ? colorScheme.primary
                    : colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Text(
                playbackStateLabel,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: hasEmbeddedPlayback
                      ? colorScheme.primary
                      : colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Row(
            children: [
              SizedBox(width: 42, height: 50, child: cover),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '第 ${media.episode} 集 · $selectedBy 选择',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (_mediaInfoLoading) const LinearProgressIndicator(minHeight: 2),
          if (_mediaInfoError != null)
            Row(
              children: [
                Expanded(
                  child: Text(
                    '标题/封面加载失败，仍可使用 Bangumi #${media.bangumiId}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.error,
                    ),
                  ),
                ),
                TextButton(onPressed: _retryMediaInfo, child: const Text('重试')),
              ],
            ),
          if (_playbackSelectionError != null)
            Text(
              _playbackSelectionError!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.error,
              ),
            ),
          const SizedBox(height: 7),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: roomSession.canSelectRoomMedia
                      ? _openMediaPicker
                      : null,
                  child: const Text('更换番剧'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed:
                      _mediaInfoBangumi == null ||
                          _mediaInfoLoading ||
                          _sourceSheetOpen
                      ? null
                      : _choosePlaybackSource,
                  child: Text(
                    _sourceSheetOpen
                        ? '选择中…'
                        : hasEmbeddedPlayback
                        ? '更换播放源'
                        : '选择播放源',
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBody(
    BuildContext context, {
    required String room,
    required SyncPlayConnectionState state,
    required SyncPlayRoomMedia? media,
  }) {
    final connected =
        state == SyncPlayConnectionState.connected && room.isNotEmpty;
    final chat = SyncPlayChatView(
      controller: roomSession,
      onSend: roomSession.trySendChatMessage,
      inviteTextBuilder: roomSession.syncPlayInviteText,
      compact: true,
      onReconnect: roomSession.retryConnection,
      onClearHistory: roomSession.clearChatHistory,
      onJoinRoom: () => unawaited(_showJoinForm()),
    );
    if (!connected) {
      return Column(
        children: [
          Flexible(
            fit: FlexFit.loose,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: legacy.SyncPlayRoomHome(
                controller: roomSession,
                onCreateRoom: () => unawaited(_showCreateForm()),
                onJoinRoom: () => unawaited(_showJoinForm()),
                onServerSettings: () => unawaited(_showServerForm()),
                onRetry: roomSession.retryConnection,
                inviteTextBuilder: roomSession.syncPlayInviteText,
                enableClipboardJoin: true,
                onClipboardInviteAccepted: _joinClipboardInvite,
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(child: chat),
        ],
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final sideBySide =
            constraints.maxWidth >= 800 &&
            constraints.maxWidth > constraints.maxHeight;
        final controls = _buildMediaDetails(context, media);
        final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
        final controlsHeightLimit = keyboardOpen ? 116.0 : 156.0;
        final controlsPane = ConstrainedBox(
          constraints: BoxConstraints(maxHeight: controlsHeightLimit),
          child: SingleChildScrollView(child: controls),
        );
        final stage = _buildPlaybackStage(context, media);
        if (sideBySide) {
          return Row(
            children: [
              Expanded(
                flex: 3,
                child: Column(
                  children: [
                    Expanded(child: stage),
                    controlsPane,
                  ],
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(flex: 2, child: chat),
            ],
          );
        }
        // Reserve the top half of the room for video on ordinary portrait
        // screens. Smaller windows and the software keyboard sacrifice some
        // player height so chat + composer stay usable without flex overflow.
        final maxStageHeight =
            (constraints.maxHeight -
                    controlsHeightLimit -
                    (keyboardOpen ? 166.0 : 146.0))
                .clamp(0.0, double.infinity);
        final stageHeight =
            (constraints.maxHeight * (keyboardOpen ? 0.32 : 0.50)).clamp(
              0.0,
              maxStageHeight,
            );
        return Column(
          children: [
            SizedBox(
              key: const ValueKey('syncplay-playback-stage'),
              width: double.infinity,
              height: stageHeight,
              child: stage,
            ),
            controlsPane,
            const Divider(height: 1),
            Expanded(child: chat),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Observer(
      builder: (context) {
        final state = roomSession.connectionState;
        final room = roomSession.syncplayRoom;
        final media = roomSession.currentMedia;
        final label = _connectionLabel(state);
        final displayRoom = roomSession.isManagedRoom
            ? roomSession.managedRoomBaseName ?? room
            : room;
        final title = room.isEmpty ? '一起看' : '房间 $displayRoom';
        final subtitle = room.isEmpty
            ? label
            : '$label · ${_roomControlLabel()}';
        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title),
                Text(subtitle, style: Theme.of(context).textTheme.labelSmall),
              ],
            ),
            actions: [_buildMenu(room)],
          ),
          body: _buildBody(context, room: room, state: state, media: media),
        );
      },
    );
  }
}
