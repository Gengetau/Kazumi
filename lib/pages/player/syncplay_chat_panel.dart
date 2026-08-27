import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:kazumi/pages/player/controller/player_chat_danmaku_controller.dart';
import 'package:kazumi/pages/player/controller/player_models.dart';
import 'package:kazumi/services/player/syncplay_room_session_controller.dart';
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
    this.chatDanmakuController,
    this.onReconnect,
    this.onClearHistory,
  });

  final SyncPlayRoomSessionController controller;
  final String? inviteText;
  final String Function()? inviteTextBuilder;
  final VoidCallback? onCopyInvite;
  final bool compact;
  final PlayerChatDanmakuController? chatDanmakuController;
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
        _setChatDanmakuEnabled(!_chatDanmakuEnabled);
    }
  }

  bool get _chatDanmakuEnabled =>
      widget.chatDanmakuController?.enabled ??
      widget.controller.chatDanmakuEnabled;

  void _setChatDanmakuEnabled(bool value) {
    final chatDanmaku = widget.chatDanmakuController;
    if (chatDanmaku != null) {
      chatDanmaku.setEnabled(value);
    } else {
      widget.controller.setChatDanmakuEnabled(value);
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
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '聊天弹幕',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                Switch(
                  value: chatDanmakuEnabled,
                  onChanged: _setChatDanmakuEnabled,
                ),
              ],
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
                  child: Text(chatDanmakuEnabled ? '关闭聊天弹幕' : '开启聊天弹幕'),
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
    Widget observedHeader(BuildContext context) => Observer(
          builder: (context) {
            final controller = widget.controller;
            return _buildHeader(
              context,
              room: controller.syncplayRoom,
              rtt: controller.syncplayClientRtt,
              state: controller.connectionState,
              chatDanmakuEnabled: _chatDanmakuEnabled,
            );
          },
        );

    final chatDanmaku = widget.chatDanmakuController;
    if (chatDanmaku == null) return observedHeader(context);
    return AnimatedBuilder(
      animation: chatDanmaku,
      builder: (context, child) => observedHeader(context),
    );
  }
}

/// A message list with its own MobX observer and scroll/new-message state.
class SyncPlayChatList extends StatefulWidget {
  const SyncPlayChatList({
    super.key,
    required this.controller,
    this.maxBubbleWidth,
    this.onReply,
    this.onJoinRoom,
  });

  final SyncPlayRoomSessionController controller;
  final double? maxBubbleWidth;
  final ValueChanged<String>? onReply;
  final VoidCallback? onJoinRoom;

  @override
  State<SyncPlayChatList> createState() => _SyncPlayChatListState();
}

class _SyncPlayChatListState extends State<SyncPlayChatList> {
  final ScrollController _scrollController = ScrollController();
  int? _lastMessageId;
  bool _hasNewMessages = false;
  bool _newMessageNotificationScheduled = false;

  SyncPlayRoomSessionController get controller => widget.controller;

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
        final messages = controller.chatMessages
            .where((message) => !controller.isChatUserMuted(message.username))
            .toList(growable: false);
        _scheduleScrollIfNeeded(messages);
        if (messages.isEmpty) {
          final noRoom = controller.syncplayRoom.isEmpty;
          final message = Text(
            noRoom ? '加入房间后开始聊天' : '暂无聊天消息',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          );
          final onJoin = widget.onJoinRoom;
          if (!noRoom || onJoin == null) {
            return Center(child: message);
          }
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                message,
                const SizedBox(height: 12),
                FilledButton.tonalIcon(
                  onPressed: onJoin,
                  icon: const Icon(Icons.login_rounded),
                  label: const Text('加入房间'),
                ),
              ],
            ),
          );
        }

        return Stack(
          children: [
            ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: messages.length,
              itemBuilder: (context, index) {
                final message = messages[index];
                final grouped = index > 0 &&
                    messages[index - 1].canGroupWith(message);
                return SyncPlayChatTile(
                  controller: controller,
                  message: message,
                  maxBubbleWidth: widget.maxBubbleWidth,
                  grouped: grouped,
                  showSender: !grouped,
                  showTime: index == messages.length - 1 ||
                      !message.canGroupWith(messages[index + 1]),
                  onReply: widget.onReply,
                );
              },
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
    required this.controller,
    required this.message,
    this.maxBubbleWidth,
    this.grouped = false,
    this.showSender = true,
    this.showTime = true,
    this.onReply,
  });

  final SyncPlayRoomSessionController controller;
  final SyncPlayChatMessage message;
  final double? maxBubbleWidth;
  final bool grouped;
  final bool showSender;
  final bool showTime;
  final ValueChanged<String>? onReply;

  static const _avatarColors = [
    Color(0xff6750a4),
    Color(0xff006a6a),
    Color(0xff9c4146),
    Color(0xff825500),
    Color(0xff315f90),
    Color(0xff675069),
  ];

  String _formatTime(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  Color _avatarColor(String username) {
    return _avatarColors[
        syncPlayUsernameHash(username) % _avatarColors.length];
  }

  Future<void> _showActions(BuildContext context) async {
    if (message.type == SyncPlayChatMessageType.system) {
      return;
    }
    final action = await showModalBottomSheet<_ChatTileAction>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final muted = controller.isChatUserMuted(message.username);
        return SafeArea(
          child: Wrap(
            children: [
              ListTile(
                leading: const Icon(Icons.copy_rounded),
                title: const Text('复制文本'),
                onTap: () => Navigator.of(context).pop(_ChatTileAction.copy),
              ),
              ListTile(
                leading: const Icon(Icons.reply_rounded),
                title: const Text('引用回复'),
                onTap: () => Navigator.of(context).pop(_ChatTileAction.reply),
              ),
              if (message.fromRemote)
                ListTile(
                  leading: Icon(
                    muted ? Icons.visibility_rounded : Icons.visibility_off,
                  ),
                  title: Text(muted ? '取消屏蔽用户' : '屏蔽用户'),
                  onTap: () => Navigator.of(context).pop(
                    muted ? _ChatTileAction.unmute : _ChatTileAction.mute,
                  ),
                ),
            ],
          ),
        );
      },
    );
    if (!context.mounted || action == null) {
      return;
    }
    switch (action) {
      case _ChatTileAction.copy:
        await Clipboard.setData(ClipboardData(text: message.message));
      case _ChatTileAction.reply:
        onReply?.call('↩ ${message.username}：${message.message}\n');
      case _ChatTileAction.mute:
        controller.setChatUserMuted(message.username, true);
      case _ChatTileAction.unmute:
        controller.setChatUserMuted(message.username, false);
    }
  }

  Widget _buildSelectionMenu(
    BuildContext context,
    EditableTextState state,
  ) {
    final items = <ContextMenuButtonItem>[
      ContextMenuButtonItem(
        label: '复制文本',
        onPressed: () {
          Clipboard.setData(ClipboardData(text: message.message));
          state.hideToolbar();
        },
      ),
      ContextMenuButtonItem(
        label: '引用回复',
        onPressed: () {
          state.hideToolbar();
          onReply?.call('↩ ${message.username}：${message.message}\n');
        },
      ),
    ];
    if (message.fromRemote) {
      final muted = controller.isChatUserMuted(message.username);
      items.add(
        ContextMenuButtonItem(
          label: muted ? '取消屏蔽用户' : '屏蔽用户',
          onPressed: () {
            state.hideToolbar();
            controller.setChatUserMuted(message.username, !muted);
          },
        ),
      );
    }
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: state.contextMenuAnchors,
      buttonItems: items,
    );
  }

  Widget _buildMentionText(
    BuildContext context,
    Color textColor,
  ) {
    final username = controller.confirmedUsername;
    final mentionPattern = isSyncPlayUsernameValid(username)
        ? RegExp(
            r'(^|[\s\(\[\{（【「“‘])@' + RegExp.escape(username) +
                r'(?=$|[\s,.!?！？:：;；\)\]\}）】」”’])',
            caseSensitive: false,
          )
        : (message.mentionsSelf ? RegExp(r'@[^\s]+') : null);
    if (mentionPattern == null || !mentionPattern.hasMatch(message.message)) {
      return SelectableText(
        message.message,
        contextMenuBuilder: (context, state) =>
            _buildSelectionMenu(context, state),
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: textColor,
            ),
      );
    }
    final spans = <TextSpan>[];
    var cursor = 0;
    for (final match in mentionPattern.allMatches(message.message)) {
      final prefixLength = match.group(1)?.length ?? 0;
      final mentionStart = match.start + prefixLength;
      if (mentionStart > cursor) {
        spans.add(
          TextSpan(text: message.message.substring(cursor, mentionStart)),
        );
      }
      spans.add(
        TextSpan(
          text: message.message.substring(mentionStart, match.end),
          style: TextStyle(
            color: textColor,
            backgroundColor: Theme.of(context).colorScheme.tertiaryContainer,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
      cursor = match.end;
    }
    if (cursor < message.message.length) {
      spans.add(TextSpan(text: message.message.substring(cursor)));
    }
    return SelectableText.rich(
      TextSpan(
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: textColor,
            ),
        children: spans,
      ),
      contextMenuBuilder: (context, state) =>
          _buildSelectionMenu(context, state),
    );
  }

  Widget _buildAvatar(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return CircleAvatar(
      radius: 15,
      backgroundColor: _avatarColor(message.username),
      foregroundColor: colorScheme.onPrimary,
      child: Text(
        syncPlayUsernameInitial(message.username),
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (message.type == SyncPlayChatMessageType.system) {
      final theme = Theme.of(context);
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Center(
          key: ValueKey<int>(message.id),
          child: Text(
            message.message,
            textAlign: TextAlign.center,
            softWrap: true,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    return Observer(
      builder: (context) {
        final theme = Theme.of(context);
        final colorScheme = theme.colorScheme;
        final muted = controller.isChatUserMuted(message.username);
        if (muted && message.fromRemote) {
          return const SizedBox.shrink();
        }
        final remote = message.fromRemote;
        final bubbleColor = remote
            ? colorScheme.surfaceContainerHighest
            : colorScheme.primaryContainer;
        final textColor = remote
            ? colorScheme.onSurfaceVariant
            : colorScheme.onPrimaryContainer;
        final bubble = ConstrainedBox(
          key: ValueKey<int>(message.id),
          constraints: BoxConstraints(
            maxWidth: maxBubbleWidth ?? MediaQuery.sizeOf(context).width * .76,
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
                  if (showSender || showTime)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (showSender)
                          Flexible(
                            child: Text(
                              message.username,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: textColor.withValues(alpha: .75),
                              ),
                            ),
                          ),
                        if (showSender && showTime) const SizedBox(width: 8),
                        if (showTime)
                          Text(
                            _formatTime(message.time),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: textColor.withValues(alpha: .65),
                            ),
                          ),
                      ],
                    ),
                  if (showSender || showTime) const SizedBox(height: 2),
                  _buildMentionText(context, textColor),
                ],
              ),
            ),
          ),
        );
        final tile = Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: remote
              ? MainAxisAlignment.start
              : MainAxisAlignment.end,
          children: remote
              ? [if (showSender) _buildAvatar(context), bubble]
              : [bubble, if (showSender) _buildAvatar(context)],
        );
        return Listener(
          onPointerDown: (event) {
            if (event.kind == PointerDeviceKind.mouse &&
                (event.buttons & kSecondaryMouseButton) != 0) {
              unawaited(_showActions(context));
            }
          },
          child: GestureDetector(
            onLongPress: () => unawaited(_showActions(context)),
            child: Padding(
              padding: EdgeInsets.fromLTRB(12, grouped ? 1 : 4, 12, 4),
              child: Align(
                alignment:
                    remote ? Alignment.centerLeft : Alignment.centerRight,
                child: tile,
              ),
            ),
          ),
        );
      },
    );
  }
}

enum _ChatTileAction { copy, reply, mute, unmute }

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

  final SyncPlayRoomSessionController controller;
  final Future<bool> Function(String message) onSend;

  @override
  SyncPlayChatComposerState createState() => SyncPlayChatComposerState();
}

class SyncPlayChatComposerState extends State<SyncPlayChatComposer> {
  final TextEditingController _textController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  bool _sending = false;
  String? _sendError;

  SyncPlayRoomSessionController get controller => widget.controller;

  bool get _isConnected => controller.isChatConnected;

  void setDraft(String draft) {
    if (!mounted) {
      return;
    }
    _textController.value = TextEditingValue(
      text: draft,
      selection: TextSelection.collapsed(offset: draft.length),
    );
    _focusNode.requestFocus();
  }

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
class SyncPlayChatPanel extends StatefulWidget {
  const SyncPlayChatPanel({
    super.key,
    required this.controller,
    required this.onSend,
    this.inviteText,
    this.inviteTextBuilder,
    this.onCopyInvite,
    this.compact = false,
    this.chatDanmakuController,
    this.onReconnect,
    this.onClearHistory,
    this.onJoinRoom,
  });

  final SyncPlayRoomSessionController controller;
  final Future<bool> Function(String message) onSend;
  final String? inviteText;
  final String Function()? inviteTextBuilder;
  final VoidCallback? onCopyInvite;
  final bool compact;
  final PlayerChatDanmakuController? chatDanmakuController;
  final VoidCallback? onReconnect;
  final VoidCallback? onClearHistory;
  final VoidCallback? onJoinRoom;

  @override
  State<SyncPlayChatPanel> createState() => _SyncPlayChatPanelState();
}

class _SyncPlayChatPanelState extends State<SyncPlayChatPanel> {
  final GlobalKey<SyncPlayChatComposerState> _composerKey =
      GlobalKey<SyncPlayChatComposerState>();

  void _reply(String quote) {
    _composerKey.currentState?.setDraft(quote);
  }

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
              controller: widget.controller,
              inviteText: widget.inviteText,
              inviteTextBuilder: widget.inviteTextBuilder,
              onCopyInvite: widget.onCopyInvite,
              compact: widget.compact,
              chatDanmakuController: widget.chatDanmakuController,
              onReconnect: widget.onReconnect,
              onClearHistory: widget.onClearHistory,
            ),
            const Divider(height: 1),
            Expanded(
              child: SyncPlayChatList(
                controller: widget.controller,
                maxBubbleWidth: availableWidth * .76,
                onReply: _reply,
                onJoinRoom: widget.onJoinRoom,
              ),
            ),
            SyncPlayChatComposer(
              key: _composerKey,
              controller: widget.controller,
              onSend: widget.onSend,
            ),
          ],
        );
      },
    );
  }
}
