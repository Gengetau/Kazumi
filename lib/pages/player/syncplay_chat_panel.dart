import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:kazumi/pages/player/controller/player_models.dart';
import 'package:kazumi/pages/player/controller/player_syncplay_controller.dart';
import 'package:kazumi/utils/device.dart';

enum SyncPlayChatHeaderAction {
  copyInvite,
  reconnect,
  clearHistory,
  toggleChatDanmaku,
}

/// The small command row above a chat room.
///
/// Header owns the RTT observer. This keeps frequent position updates from
/// rebuilding the message list or the text composer.
class SyncPlayChatHeader extends StatefulWidget {
  const SyncPlayChatHeader({
    super.key,
    required this.controller,
    this.inviteText,
    this.inviteTextBuilder,
    this.onCopyInvite,
    this.compact = false,
    this.globalDanmakuEnabled = true,
    this.onEnableGlobalDanmaku,
    this.onReconnect,
    this.onClearHistory,
  });

  final PlayerSyncPlayController controller;
  final String? inviteText;
  final String Function()? inviteTextBuilder;
  final VoidCallback? onCopyInvite;
  final bool compact;
  final bool globalDanmakuEnabled;
  final VoidCallback? onEnableGlobalDanmaku;
  final VoidCallback? onReconnect;
  final VoidCallback? onClearHistory;

  @override
  State<SyncPlayChatHeader> createState() => _SyncPlayChatHeaderState();
}

class _SyncPlayChatHeaderState extends State<SyncPlayChatHeader> {
  bool _copied = false;
  Timer? _copyResetTimer;

  @override
  void dispose() {
    _copyResetTimer?.cancel();
    super.dispose();
  }

  String _inviteText(String room) {
    final builder = widget.inviteTextBuilder;
    if (builder != null) {
      final text = builder();
      if (text.isNotEmpty) {
        return text;
      }
    }
    final text = widget.inviteText;
    if (text != null && text.isNotEmpty) {
      return text;
    }
    return 'Kazumi 一起看邀请\n房间：$room';
  }

  void _copyInvite(String room) {
    widget.onCopyInvite?.call();
    if (widget.onCopyInvite == null) {
      Clipboard.setData(ClipboardData(text: _inviteText(room)));
    }
    _copyResetTimer?.cancel();
    if (!mounted) {
      return;
    }
    setState(() => _copied = true);
    _copyResetTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() => _copied = false);
      }
    });
  }

  void _selectAction(SyncPlayChatHeaderAction action, String room) {
    switch (action) {
      case SyncPlayChatHeaderAction.copyInvite:
        _copyInvite(room);
      case SyncPlayChatHeaderAction.reconnect:
        widget.onReconnect?.call();
      case SyncPlayChatHeaderAction.clearHistory:
        widget.onClearHistory?.call();
      case SyncPlayChatHeaderAction.toggleChatDanmaku:
        if (!widget.globalDanmakuEnabled) {
          widget.onEnableGlobalDanmaku?.call();
        } else {
          widget.controller.setChatDanmakuEnabled(
            !widget.controller.chatDanmakuEnabled,
          );
        }
    }
  }

  Widget _buildHeader(
    BuildContext context, {
    required String room,
    required int rtt,
    required SyncPlayConnectionState state,
    required bool chatDanmakuEnabled,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final status = switch (state) {
      SyncPlayConnectionState.connected => room.isEmpty ? '未加入房间' : '已连接',
      SyncPlayConnectionState.connecting => '正在连接',
      SyncPlayConnectionState.reconnecting => '正在重新连接',
      SyncPlayConnectionState.failed => '连接失败',
      SyncPlayConnectionState.disconnected => '未连接',
    };
    final roomLabel = room.isEmpty ? status : '房间 $room';

    return Padding(
      padding: EdgeInsets.fromLTRB(16, widget.compact ? 8 : 12, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '聊天室',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    roomLabel,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (room.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Text(
                    '$rtt ms',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (!widget.compact) ...[
            Semantics(
              enabled: widget.globalDanmakuEnabled,
              label: widget.globalDanmakuEnabled ? '聊天弹幕' : '需先开启总弹幕',
              child: GestureDetector(
                onTap: widget.globalDanmakuEnabled
                    ? null
                    : widget.onEnableGlobalDanmaku,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '聊天弹幕',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    Switch(
                      value:
                          widget.globalDanmakuEnabled && chatDanmakuEnabled,
                      onChanged: widget.globalDanmakuEnabled
                          ? (_) {
                              widget.controller.setChatDanmakuEnabled(
                                !chatDanmakuEnabled,
                              );
                            }
                          : null,
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (widget.compact)
            PopupMenuButton<SyncPlayChatHeaderAction>(
              onSelected: (action) => _selectAction(action, room),
              tooltip: '聊天室操作',
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: SyncPlayChatHeaderAction.copyInvite,
                  enabled: room.isNotEmpty,
                  child: const Text('复制邀请'),
                ),
                PopupMenuItem(
                  value: SyncPlayChatHeaderAction.reconnect,
                  enabled: widget.onReconnect != null,
                  child: const Text('重新连接'),
                ),
                PopupMenuItem(
                  value: SyncPlayChatHeaderAction.clearHistory,
                  enabled: widget.onClearHistory != null,
                  child: const Text('清本地记录'),
                ),
                PopupMenuItem(
                  value: SyncPlayChatHeaderAction.toggleChatDanmaku,
                  child: Text(
                    widget.globalDanmakuEnabled
                        ? (widget.controller.chatDanmakuEnabled
                            ? '关闭聊天弹幕'
                            : '开启聊天弹幕')
                        : '需先开启总弹幕',
                  ),
                ),
              ],
              icon: const Icon(Icons.more_vert_rounded),
            )
          else
            IconButton(
              onPressed: room.isEmpty ? null : () => _copyInvite(room),
              tooltip: '复制邀请',
              icon: Icon(
                _copied ? Icons.check_rounded : Icons.copy_rounded,
                size: 18,
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Observer(
      builder: (context) {
        final controller = widget.controller;
        final room = controller.syncplayRoom;
        final rtt = controller.syncplayClientRtt;
        final state = controller.connectionState;
        final chatDanmakuEnabled = controller.chatDanmakuEnabled;
        return _buildHeader(
          context,
          room: room,
          rtt: rtt,
          state: state,
          chatDanmakuEnabled: chatDanmakuEnabled,
        );
      },
    );
  }
}

/// A message list with its own MobX observer and scroll/new-message state.
class SyncPlayChatList extends StatefulWidget {
  const SyncPlayChatList({
    super.key,
    required this.controller,
    this.maxBubbleWidth,
  });

  final PlayerSyncPlayController controller;
  final double? maxBubbleWidth;

  @override
  State<SyncPlayChatList> createState() => _SyncPlayChatListState();
}

class _SyncPlayChatListState extends State<SyncPlayChatList> {
  final ScrollController _scrollController = ScrollController();
  int? _lastMessageId;
  bool _hasNewMessages = false;
  bool _newMessageNotificationScheduled = false;

  PlayerSyncPlayController get controller => widget.controller;

  bool get _isNearBottom {
    if (!_scrollController.hasClients) {
      return true;
    }
    final position = _scrollController.position;
    return position.maxScrollExtent - position.pixels <= 72;
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_handleScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _handleScroll() {
    if (_hasNewMessages && _isNearBottom && mounted) {
      setState(() => _hasNewMessages = false);
    }
  }

  void _scheduleScrollIfNeeded(List<SyncPlayChatMessage> messages) {
    if (messages.isEmpty) {
      _lastMessageId = null;
      _hasNewMessages = false;
      return;
    }

    final newestMessageId = messages.last.id;
    if (newestMessageId == _lastMessageId) {
      return;
    }

    final shouldFollow = _isNearBottom;
    _lastMessageId = newestMessageId;
    if (shouldFollow) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) {
          return;
        }
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      });
    } else if (!_hasNewMessages && !_newMessageNotificationScheduled) {
      _newMessageNotificationScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _newMessageNotificationScheduled = false;
        if (mounted && !_isNearBottom && !_hasNewMessages) {
          setState(() => _hasNewMessages = true);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Observer(
      builder: (context) {
        final messages = controller.chatMessages.toList(growable: false);
        _scheduleScrollIfNeeded(messages);
        if (messages.isEmpty) {
          return Center(
            child: Text(
              controller.syncplayRoom.isEmpty ? '加入房间后开始聊天' : '暂无聊天消息',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          );
        }

        return Stack(
          children: [
            ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: messages.length,
              itemBuilder: (context, index) => SyncPlayChatTile(
                message: messages[index],
                maxBubbleWidth: widget.maxBubbleWidth,
              ),
            ),
            if (_hasNewMessages)
              Positioned(
                left: 0,
                right: 0,
                bottom: 12,
                child: Center(
                  child: FilledButton.tonalIcon(
                    onPressed: () {
                      if (_scrollController.hasClients) {
                        _scrollController.animateTo(
                          _scrollController.position.maxScrollExtent,
                          duration: const Duration(milliseconds: 180),
                          curve: Curves.easeOut,
                        );
                      }
                      setState(() => _hasNewMessages = false);
                    },
                    icon: const Icon(Icons.arrow_downward_rounded),
                    label: const Text('有新消息'),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// One chat bubble. It is intentionally a separate widget so later message
/// actions only rebuild the affected tile.
class SyncPlayChatTile extends StatelessWidget {
  const SyncPlayChatTile({
    super.key,
    required this.message,
    this.maxBubbleWidth,
  });

  final SyncPlayChatMessage message;
  final double? maxBubbleWidth;

  String _formatTime(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    return Observer(
      builder: (context) {
        final theme = Theme.of(context);
        final colorScheme = theme.colorScheme;
        if (message.type == SyncPlayChatMessageType.system) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Center(
              key: ValueKey<int>(message.id),
              child: Text(
                message.message,
                textAlign: TextAlign.center,
                softWrap: true,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          );
        }

        final remote = message.fromRemote;
        final bubbleColor = remote
            ? colorScheme.surfaceContainerHighest
            : colorScheme.primaryContainer;
        final textColor = remote
            ? colorScheme.onSurfaceVariant
            : colorScheme.onPrimaryContainer;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Align(
            alignment: remote ? Alignment.centerLeft : Alignment.centerRight,
            child: ConstrainedBox(
              key: ValueKey<int>(message.id),
              constraints: BoxConstraints(
                maxWidth: maxBubbleWidth ??
                    MediaQuery.sizeOf(context).width * .76,
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: bubbleColor,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 9),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              message.username,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: textColor.withValues(alpha: .75),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _formatTime(message.time),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: textColor.withValues(alpha: .65),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        message.message,
                        softWrap: true,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: textColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SendChatIntent extends Intent {
  const _SendChatIntent();
}

/// Editable chat input. Sending only disables its button; the field remains
/// editable so an in-flight send cannot discard or lock the user's draft.
class SyncPlayChatComposer extends StatefulWidget {
  const SyncPlayChatComposer({
    super.key,
    required this.controller,
    required this.onSend,
  });

  final PlayerSyncPlayController controller;
  final Future<bool> Function(String message) onSend;

  @override
  State<SyncPlayChatComposer> createState() => _SyncPlayChatComposerState();
}

class _SyncPlayChatComposerState extends State<SyncPlayChatComposer> {
  final TextEditingController _textController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  bool _sending = false;
  String? _sendError;

  PlayerSyncPlayController get controller => widget.controller;

  bool get _isConnected => controller.isChatConnected;

  @override
  void dispose() {
    _textController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_sending || !_isConnected) {
      return;
    }
    final message = _textController.text.trim();
    if (message.isEmpty) {
      return;
    }

    setState(() {
      _sending = true;
      _sendError = null;
    });

    bool sent = false;
    try {
      sent = await widget.onSend(message);
    } catch (_) {
      sent = false;
    }
    if (!mounted) {
      return;
    }

    setState(() {
      _sending = false;
      _sendError = sent ? null : '发送失败，请检查连接后重试';
    });
    if (sent) {
      _textController.clear();
      _focusNode.requestFocus();
    }
  }

  Widget _buildField(BuildContext context, bool editable) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final field = TextField(
      controller: _textController,
      focusNode: _focusNode,
      enabled: editable,
      minLines: 1,
      maxLines: 3,
      maxLength: controller.chatMessageLengthLimit,
      textInputAction:
          isDesktop() ? TextInputAction.newline : TextInputAction.send,
      onSubmitted: (_) {
        if (!isDesktop()) {
          unawaited(_send());
        }
      },
      onChanged: (_) {
        if (_sendError != null) {
          setState(() => _sendError = null);
        }
      },
      decoration: InputDecoration(
        hintText: _isConnected ? '输入消息……' : '加入房间后即可聊天',
        counterText: '',
        filled: true,
        fillColor: colorScheme.surfaceContainerHighest,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 10,
        ),
      ),
    );
    if (!isDesktop()) {
      return field;
    }
    // Enter submits on desktop; Shift+Enter is not matched and remains the
    // normal TextField newline action.
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.enter):
            const _SendChatIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _SendChatIntent: CallbackAction<_SendChatIntent>(
            onInvoke: (_) {
              unawaited(_send());
              return null;
            },
          ),
        },
        child: field,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Observer(
      builder: (context) {
        final editable = _isConnected;
        final sendEnabled = editable && !_sending;
        final bottomPadding = MediaQuery.viewPaddingOf(context).bottom;
        final theme = Theme.of(context);
        final colorScheme = theme.colorScheme;
        return Padding(
          padding: EdgeInsets.fromLTRB(12, 8, 12, bottomPadding + 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(child: _buildField(context, editable)),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: sendEnabled ? _send : null,
                    child: const Text('发送'),
                  ),
                ],
              ),
              if (_sendError != null) ...[
                const SizedBox(height: 4),
                Text(
                  _sendError!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// The chat surface for the currently active SyncPlay room.
class SyncPlayChatPanel extends StatelessWidget {
  const SyncPlayChatPanel({
    super.key,
    required this.controller,
    required this.onSend,
    this.inviteText,
    this.inviteTextBuilder,
    this.onCopyInvite,
    this.compact = false,
    this.globalDanmakuEnabled = true,
    this.onEnableGlobalDanmaku,
    this.onReconnect,
    this.onClearHistory,
  });

  final PlayerSyncPlayController controller;
  final Future<bool> Function(String message) onSend;
  final String? inviteText;
  final String Function()? inviteTextBuilder;
  final VoidCallback? onCopyInvite;
  final bool compact;
  final bool globalDanmakuEnabled;
  final VoidCallback? onEnableGlobalDanmaku;
  final VoidCallback? onReconnect;
  final VoidCallback? onClearHistory;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SyncPlayChatHeader(
              controller: controller,
              inviteText: inviteText,
              inviteTextBuilder: inviteTextBuilder,
              onCopyInvite: onCopyInvite,
              compact: compact,
              globalDanmakuEnabled: globalDanmakuEnabled,
              onEnableGlobalDanmaku: onEnableGlobalDanmaku,
              onReconnect: onReconnect,
              onClearHistory: onClearHistory,
            ),
            const Divider(height: 1),
            Expanded(
              child: SyncPlayChatList(
                controller: controller,
                maxBubbleWidth: availableWidth * .76,
              ),
            ),
            SyncPlayChatComposer(controller: controller, onSend: onSend),
          ],
        );
      },
    );
  }
}
