import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/pages/player/controller/player_models.dart';
import 'package:kazumi/services/player/syncplay_room_session_controller.dart';

/// Compact entry point for the persistent SyncPlay room page.
///
/// The session is app-scoped, so this action can reflect connection and chat
/// state without giving PopularPage another room owner or controller.
class SyncPlayRoomEntryButton extends StatelessWidget {
  const SyncPlayRoomEntryButton({super.key, this.controller});

  /// Optional injection seam for isolated widget tests. Production callers
  /// leave this null and resolve the app-scoped session from Modular.
  final SyncPlayRoomSessionController? controller;

  SyncPlayRoomSessionController _resolveController() =>
      controller ?? inject<SyncPlayRoomSessionController>();

  @override
  Widget build(BuildContext context) {
    return Observer(
      builder: (context) {
        final roomSession = _resolveController();
        final state = roomSession.connectionState;
        // Read both counters unconditionally so this observer remains
        // subscribed when a mention count is the only changing value.
        final unreadCount = roomSession.unreadChatCount;
        final mentionCount = roomSession.unreadMentionCount;
        final statusLabel = _statusLabel(
          state,
          unreadCount: unreadCount,
          mentionCount: mentionCount,
        );
        return IconButton(
          onPressed: () => context.pushNamed('/syncplay-room/'),
          tooltip: statusLabel,
          icon: _buildIcon(
            context,
            state,
            unreadCount: unreadCount,
            mentionCount: mentionCount,
          ),
        );
      },
    );
  }

  String _statusLabel(
    SyncPlayConnectionState state, {
    required int unreadCount,
    required int mentionCount,
  }) {
    final status = switch (state) {
      SyncPlayConnectionState.disconnected => '未连接',
      SyncPlayConnectionState.connecting => '正在连接',
      SyncPlayConnectionState.connected => '已连接',
      SyncPlayConnectionState.reconnecting => '正在重新连接',
      SyncPlayConnectionState.failed => '连接失败',
    };
    if (state != SyncPlayConnectionState.connected) {
      return '一起看：$status';
    }
    if (mentionCount > 0) {
      return '一起看：$status，${_formatCount(mentionCount)} 条提及未读';
    }
    if (unreadCount > 0) {
      return '一起看：$status，${_formatCount(unreadCount)} 条未读';
    }
    return '一起看：$status';
  }

  Widget _buildIcon(
    BuildContext context,
    SyncPlayConnectionState state, {
    required int unreadCount,
    required int mentionCount,
  }) {
    return switch (state) {
      SyncPlayConnectionState.disconnected => const Icon(Icons.forum_outlined),
      SyncPlayConnectionState.connecting => const SizedBox.square(
        dimension: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      SyncPlayConnectionState.connected => Badge(
        isLabelVisible: unreadCount > 0 || mentionCount > 0,
        label: Text(
          mentionCount > 0
              ? '@${_formatCount(mentionCount)}'
              : _formatCount(unreadCount),
        ),
        backgroundColor: mentionCount > 0
            ? Theme.of(context).colorScheme.error
            : null,
        textColor: mentionCount > 0
            ? Theme.of(context).colorScheme.onError
            : null,
        child: const Icon(Icons.forum_rounded),
      ),
      SyncPlayConnectionState.reconnecting => _statusDotIcon(
        color: Colors.orange,
        child: const Icon(Icons.forum_rounded),
      ),
      SyncPlayConnectionState.failed => _statusDotIcon(
        color: Theme.of(context).colorScheme.error,
        child: const Icon(Icons.forum_outlined),
      ),
    };
  }

  Widget _statusDotIcon({required Color color, required Widget child}) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        Positioned(
          top: -1,
          right: -1,
          child: Semantics(
            excludeSemantics: true,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 1.5),
              ),
              child: const SizedBox.square(dimension: 8),
            ),
          ),
        ),
      ],
    );
  }

  String _formatCount(int count) => count > 99 ? '99+' : '$count';
}
