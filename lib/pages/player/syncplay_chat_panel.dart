import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:kazumi/pages/player/controller/player_models.dart';
import 'package:kazumi/pages/player/controller/player_syncplay_controller.dart';

/// The chat surface for the currently active SyncPlay room.
///
/// The panel deliberately receives the controller and send callback instead
/// of looking them up through Modular, which keeps it usable in the video page
/// and in isolated widget tests.
class SyncPlayChatPanel extends StatefulWidget {
  const SyncPlayChatPanel({
    super.key,
    required this.controller,
    required this.onSend,
    this.inviteText,
    this.onCopyInvite,
  });

  final PlayerSyncPlayController controller;
  final Future<bool> Function(String message) onSend;
  final String? inviteText;
  final VoidCallback? onCopyInvite;

  @override
  State<SyncPlayChatPanel> createState() => _SyncPlayChatPanelState();
}

class _SyncPlayChatPanelState extends State<SyncPlayChatPanel> {
  final TextEditingController _textController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();

  int? _lastMessageId;
  bool _hasNewMessages = false;
  bool _sending = false;
  bool _copied = false;
  bool _newMessageNotificationScheduled = false;
  String? _sendError;
  Timer? _copyResetTimer;

  PlayerSyncPlayController get controller => widget.controller;

  bool get _isConnected =>
      controller.hasSession && controller.syncplayRoom.isNotEmpty;

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
    _copyResetTimer?.cancel();
    _textController.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _handleScroll() {
    if (_hasNewMessages && _isNearBottom && mounted) {
      setState(() => _hasNewMessages = false);
    }
  }

  /// Build can run more than once for a single incoming message. Keep the
  /// bookkeeping synchronous, but defer any stateful notification to the next
  /// frame so build never calls setState synchronously.
  void _scheduleScrollIfNeeded(List<SyncPlayChatMessage> messages) {
    if (messages.isEmpty) {
      _lastMessageId = null;
      _hasNewMessages = false;
      return;
    }

    final int newestMessageId = messages.last.id;
    if (newestMessageId == _lastMessageId) {
      return;
    }

    final bool shouldFollow = _isNearBottom;
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

  String _inviteText(String room) {
    if (widget.inviteText != null && widget.inviteText!.isNotEmpty) {
      return widget.inviteText!;
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

  String _formatTime(DateTime time) {
    final String hour = time.hour.toString().padLeft(2, '0');
    final String minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  Widget _buildHeader(BuildContext context, String room) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final rtt = controller.syncplayClientRtt;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        runSpacing: 8,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '聊天室',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 140),
                child: Text(
                  room.isEmpty ? '未加入房间' : '房间 $room',
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
                value: controller.chatDanmakuEnabled,
                onChanged: controller.setChatDanmakuEnabled,
              ),
              TextButton.icon(
                onPressed: () => _copyInvite(room),
                icon: Icon(
                  _copied ? Icons.check_rounded : Icons.copy_rounded,
                  size: 18,
                ),
                label: Text(_copied ? '已复制' : '复制邀请'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMessage(BuildContext context, SyncPlayChatMessage message) {
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

    final bool remote = message.fromRemote;
    final bubbleColor = remote
        ? colorScheme.surfaceContainerHighest
        : colorScheme.primaryContainer;
    final textColor =
        remote ? colorScheme.onSurfaceVariant : colorScheme.onPrimaryContainer;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Align(
        alignment: remote ? Alignment.centerLeft : Alignment.centerRight,
        child: ConstrainedBox(
          key: ValueKey<int>(message.id),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.8,
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
                            color: textColor.withValues(alpha: 0.75),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _formatTime(message.time),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: textColor.withValues(alpha: 0.65),
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
  }

  Widget _buildComposer(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final bool enabled = _isConnected && !_sending;
    final bottomPadding = MediaQuery.viewPaddingOf(context).bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(12, 8, 12, bottomPadding + 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _textController,
                  focusNode: _focusNode,
                  enabled: enabled,
                  minLines: 1,
                  maxLines: 3,
                  maxLength: controller.chatMessageLengthLimit,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
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
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: enabled ? _send : null,
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
  }

  @override
  Widget build(BuildContext context) {
    return Observer(
      builder: (context) {
        final messages = controller.chatMessages.toList(growable: false);
        final room = controller.syncplayRoom.isNotEmpty
            ? controller.syncplayRoom
            : controller.activeChatRoom;
        _scheduleScrollIfNeeded(messages);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(context, room),
            const Divider(height: 1),
            Expanded(
              child: messages.isEmpty
                  ? Center(
                      child: Text(
                        controller.syncplayRoom.isEmpty
                            ? '加入房间后开始聊天'
                            : '暂无聊天消息',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      ),
                    )
                  : Stack(
                      children: [
                        ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          itemCount: messages.length,
                          itemBuilder: (context, index) =>
                              _buildMessage(context, messages[index]),
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
                                      _scrollController
                                          .position.maxScrollExtent,
                                      duration: const Duration(
                                        milliseconds: 180,
                                      ),
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
                    ),
            ),
            _buildComposer(context),
          ],
        );
      },
    );
  }
}
