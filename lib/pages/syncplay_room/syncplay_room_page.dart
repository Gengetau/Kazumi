import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:kazumi/bean/dialog/adaptive_bottom_sheet.dart';
import 'package:kazumi/bean/card/network_img_layer.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/pages/player/controller/player_models.dart';
import 'package:kazumi/pages/player/syncplay_chat_panel.dart';
import 'package:kazumi/pages/player/syncplay_sheet.dart';
import 'package:kazumi/pages/syncplay_room/media_picker/syncplay_room_media_selection.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';
import 'package:kazumi/services/player/syncplay_endpoint.dart';
import 'package:kazumi/services/player/syncplay_room_models.dart';
import 'package:kazumi/services/player/syncplay_room_session_controller.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/async_session.dart';

enum _SyncPlayRoomMenuAction { copyInvite, serverInfo, clearHistory, exitRoom }

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

class _SyncPlayRoomPageState extends State<SyncPlayRoomPage> {
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
  void dispose() {
    // A page disappearing is not an explicit room exit. The app-scoped
    // session and socket must remain available to the next room surface.
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
        (_mediaInfoBangumi?.id == media.bangumiId ||
            _mediaInfoBangumi == null);
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

  Future<void> _showCreateForm() async {
    await showAdaptiveBottomSheet<void>(
      context: context,
      maxHeightFactor: 0.8,
      compactLandscapeMaxHeightFactor: 0.95,
      builder: (context) => SyncPlayCreateRoomForm(
        onSubmit: (room, username) => roomSession.createRoom(room, username),
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
    final shouldExit = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('退出聊天室？'),
        content: const Text('退出聊天室后将停止同步并清除当前聊天记录'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('退出聊天室'),
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
    return PopupMenuButton<_SyncPlayRoomMenuAction>(
      tooltip: '房间操作',
      onSelected: _onMenuAction,
      itemBuilder: (context) => [
        PopupMenuItem(
          value: _SyncPlayRoomMenuAction.copyInvite,
          enabled: room.isNotEmpty,
          child: const Text('复制邀请'),
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
                onPressed: _openMediaPicker,
                child: const Text('选择番剧'),
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
                    onPressed: _openMediaPicker,
                    child: const Text('更换番剧'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: null,
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
                ),
                if (connected) ...[
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
        final title = room.isEmpty ? '一起看' : '房间 $room';
        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title),
                Text(label, style: Theme.of(context).textTheme.labelSmall),
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
