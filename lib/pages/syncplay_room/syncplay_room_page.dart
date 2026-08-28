import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:kazumi/bean/dialog/adaptive_bottom_sheet.dart';
import 'package:kazumi/bean/card/network_img_layer.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/navigation.dart';
import 'package:kazumi/pages/info/info_route_args.dart';
import 'package:kazumi/pages/player/controller/player_models.dart';
import 'package:kazumi/pages/player/syncplay_chat_panel.dart';
import 'package:kazumi/pages/player/syncplay_sheet.dart';
import 'package:kazumi/pages/syncplay_room/media_picker/syncplay_room_media_selection.dart';
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
    final sameMedia = _mediaInfoRoom == room &&
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
      bangumi = await (widget.bangumiInfoLoader ??
          BangumiApi.getBangumiInfoByID)(media.bangumiId);
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('房间未确认媒体选择，请重试')),
      );
      return;
    }
    final media = roomSession.currentMedia;
    if (media != null &&
        media.bangumiId == selection.bangumi.id &&
        media.episode == selection.episode) {
      _cacheSelectedMedia(selection, media);
    } else if (media != null) {
      unawaited(_loadMediaInfo(media, force: true));
    }
  }

  Future<void> _enterPlayback() async {
    final media = roomSession.currentMedia;
    final bangumi = _mediaInfoBangumi;
    if (media == null || bangumi == null) {
      return;
    }
    final launchIntent = SyncPlayPlaybackLaunchIntent(
      expectedBangumiId: media.bangumiId,
      expectedEpisode: media.episode,
      expectedMediaGeneration: media.generation,
    );
    if (!roomSession.isPlaybackLaunchIntentCurrent(launchIntent)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('房间媒体刚刚更新，请刷新后再进入播放')),
        );
      }
      return;
    }
    await context.pushNamed(
      '/info/',
      arguments: InfoPageRouteArgs(
        bangumiItem: bangumi,
        playbackLaunchIntent: launchIntent,
      ),
    );
  }

  Future<void> _joinClipboardInvite(SyncPlayInvite invite) async {
    inject<SyncPlayClipboardInviteService>().takePending();
    await GStorage.putSetting<String>(
      SettingsKeys.syncPlayEndPoint,
      invite.server,
    );
    var username = '';
    try {
      username =
          GStorage.getSetting<String>(SettingsKeys.syncPlayUserName).trim();
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
    final operatorCount =
        roomSession.roomUsers.values.where((user) => user.isController).length;
    if (operatorCount == 0) {
      return '房主控制 · 暂无主持人';
    }
    if (roomSession.isRoomOperator) {
      return operatorCount == 1 ? '房主控制 · 你是主持人' : '房主控制 · $operatorCount 位主持人';
    }
    return '房主控制 · $operatorCount 位主持人';
  }

  Widget _buildRoomControlCard(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final users = roomSession.roomUsers.values.toList()
      ..sort((a, b) {
        if (a.isController != b.isController) {
          return a.isController ? -1 : 1;
        }
        return a.username.compareTo(b.username);
      });
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  roomSession.isManagedRoom
                      ? Icons.lock_person_rounded
                      : Icons.groups_rounded,
                  color: roomSession.isManagedRoom
                      ? colorScheme.primary
                      : colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _roomControlLabel(),
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            if (users.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final user in users)
                    Tooltip(
                      message: user.isController ? '主持人' : '成员',
                      child: Chip(
                        avatar: Icon(
                          user.isController
                              ? Icons.workspace_premium_rounded
                              : Icons.person_outline_rounded,
                          size: 18,
                        ),
                        label: Text(
                          user.username == roomSession.confirmedUsername
                              ? '${user.username}（你）'
                              : user.username,
                        ),
                      ),
                    ),
                ],
              ),
            ] else if (roomSession.isManagedRoom) ...[
              const SizedBox(height: 8),
              Text(
                '正在获取房间成员与主持状态',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (roomSession.isManagedRoom && !roomSession.isRoomOperator) ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: _showOperatorAuthentication,
                  icon: const Icon(Icons.key_rounded),
                  label: const Text('输入主持密码'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _showCreateForm() async {
    await showAdaptiveBottomSheet<void>(
      context: context,
      maxHeightFactor: 0.8,
      compactLandscapeMaxHeightFactor: 0.95,
      builder: (context) => SyncPlayCreateRoomForm(
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
      builder: (context) => SyncPlayJoinRoomForm(
        onSubmit: (room, username) => roomSession.createRoom(room, username),
      ),
    );
  }

  Future<void> _showServerForm() async {
    await showAdaptiveBottomSheet<void>(
      context: context,
      maxHeightFactor: 0.8,
      compactLandscapeMaxHeightFactor: 0.95,
      builder: (context) => SyncPlayServerForm(
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
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('邀请信息已复制')));
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
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('主持密码已复制，请仅私下分享给可信成员')),
    );
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
      SnackBar(
        content: Text(success ? '已成为共同主持人' : '主持密码无效或认证超时'),
      ),
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
    final operatorCount =
        roomSession.roomUsers.values.where((user) => user.isController).length;
    final isUniqueOperator = roomSession.isManagedRoom &&
        roomSession.isRoomOperator &&
        operatorCount <= 1;
    final isOneOfMultipleOperators = roomSession.isManagedRoom &&
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
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('本地聊天记录已清空')));
      case _SyncPlayRoomMenuAction.exitRoom:
        unawaited(_confirmExitRoom());
    }
  }

  Widget _buildMenu(String room) {
    final showAuthenticate = roomSession.isManagedRoom &&
        !roomSession.isRoomOperator &&
        roomSession.connectionState == SyncPlayConnectionState.connected;
    final showCopyPassword = roomSession.isRoomOperator &&
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

  Widget _buildMediaCard(BuildContext context, SyncPlayRoomMedia? media) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    if (media == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('当前观看', style: theme.textTheme.titleMedium),
              const SizedBox(height: 18),
              Icon(
                Icons.movie_outlined,
                size: 38,
                color: colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 8),
              Text(
                '暂未选择番剧',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed:
                    roomSession.canSelectRoomMedia ? _openMediaPicker : null,
                child: Text(
                  roomSession.canSelectRoomMedia ? '选择番剧' : '等待主持人选择',
                ),
              ),
            ],
          ),
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
    final leading = imageUrl.isEmpty
        ? CircleAvatar(child: Text('${media.bangumiId}'))
        : SizedBox(
            width: 56,
            height: 76,
            child: NetworkImgLayer(
              src: imageUrl,
              width: 56,
              height: 76,
            ),
          );
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('当前观看', style: theme.textTheme.titleMedium),
            const SizedBox(height: 10),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: leading,
              title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text('第 ${media.episode} 集\n$selectedBy 选择'),
            ),
            if (_mediaInfoLoading)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: LinearProgressIndicator(minHeight: 2),
              ),
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
                  TextButton(
                    onPressed: _retryMediaInfo,
                    child: const Text('重试'),
                  ),
                ],
              ),
            const SizedBox(height: 4),
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
                    onPressed: _mediaInfoBangumi == null || _mediaInfoLoading
                        ? null
                        : _enterPlayback,
                    child: const Text('进入播放'),
                  ),
                ),
              ],
            ),
          ],
        ),
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
    return Column(
      children: [
        Flexible(
          fit: FlexFit.loose,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SyncPlayRoomHome(
                  controller: roomSession,
                  onCreateRoom: () => unawaited(_showCreateForm()),
                  onJoinRoom: () => unawaited(_showJoinForm()),
                  onServerSettings: () => unawaited(_showServerForm()),
                  onRetry: roomSession.retryConnection,
                  inviteTextBuilder: roomSession.syncPlayInviteText,
                  enableClipboardJoin: true,
                  onClipboardInviteAccepted: _joinClipboardInvite,
                ),
                if (connected) ...[
                  const SizedBox(height: 12),
                  _buildRoomControlCard(context),
                  const SizedBox(height: 12),
                  _buildMediaCard(context, media),
                ],
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: SyncPlayChatView(
            controller: roomSession,
            onSend: roomSession.trySendChatMessage,
            inviteTextBuilder: roomSession.syncPlayInviteText,
            compact: true,
            onReconnect: roomSession.retryConnection,
            onClearHistory: roomSession.clearChatHistory,
            onJoinRoom: () => unawaited(_showJoinForm()),
          ),
        ),
      ],
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
        final subtitle =
            room.isEmpty ? label : '$label · ${_roomControlLabel()}';
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
