import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kazumi/pages/player/player_panel_hold.dart';

class SyncPlayQuickChatComposer extends StatefulWidget {
  const SyncPlayQuickChatComposer({
    super.key,
    required this.ensureReady,
    required this.onSend,
    required this.acquirePlayerPanelHold,
    required this.compact,
    this.onOpen,
    this.restoreFocus,
  });

  final Future<bool> Function() ensureReady;
  final Future<bool> Function(String message) onSend;
  final PlayerPanelHold Function() acquirePlayerPanelHold;
  final bool compact;
  final VoidCallback? onOpen;
  final FocusNode? restoreFocus;

  @override
  State<SyncPlayQuickChatComposer> createState() =>
      _SyncPlayQuickChatComposerState();
}

class _SyncPlayQuickChatComposerState
    extends State<SyncPlayQuickChatComposer> {
  final TextEditingController _textController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  PlayerPanelHold? _panelHold;
  bool _expanded = false;
  bool _opening = false;
  bool _sending = false;

  @override
  void dispose() {
    _panelHold?.release();
    _textController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    if (_expanded || _opening) return;
    _opening = true;
    var ready = false;
    try {
      ready = await widget.ensureReady();
    } catch (_) {
      ready = false;
    } finally {
      _opening = false;
    }
    if (!mounted || !ready) return;
    _panelHold ??= widget.acquirePlayerPanelHold();
    widget.onOpen?.call();
    setState(() => _expanded = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  void _close() {
    if (!_expanded) return;
    _focusNode.unfocus();
    _panelHold?.release();
    _panelHold = null;
    setState(() => _expanded = false);
    widget.restoreFocus?.requestFocus();
  }

  Future<void> _send() async {
    if (_sending) return;
    final message = _textController.text.trim();
    if (message.isEmpty) return;
    setState(() => _sending = true);
    var sent = false;
    try {
      sent = await widget.onSend(message);
    } catch (_) {
      sent = false;
    } finally {
      if (mounted) setState(() => _sending = false);
    }
    if (!mounted || !sent) return;
    _textController.clear();
    _close();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<void>(
      canPop: !_expanded,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _expanded) _close();
      },
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.escape): _close,
        },
        child: _expanded
            ? SizedBox(
                width: widget.compact ? 184 : 280,
                height: 40,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _textController,
                        focusNode: _focusNode,
                        enabled: true,
                        maxLength: 500,
                        maxLines: 1,
                        textInputAction: TextInputAction.send,
                        style: const TextStyle(color: Colors.white),
                        decoration: const InputDecoration(
                          counterText: '',
                          hintText: '发送到聊天室',
                          hintStyle: TextStyle(color: Colors.white60),
                          filled: true,
                          fillColor: Colors.black45,
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          border: OutlineInputBorder(
                            borderSide: BorderSide.none,
                            borderRadius: BorderRadius.all(Radius.circular(20)),
                          ),
                        ),
                        onSubmitted: (_) => _send(),
                      ),
                    ),
                    IconButton(
                      tooltip: '发送聊天消息',
                      onPressed: _sending ? null : _send,
                      icon: _sending
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.send_rounded, color: Colors.white),
                    ),
                    if (!widget.compact)
                      IconButton(
                        tooltip: '关闭快捷聊天',
                        onPressed: _close,
                        icon: const Icon(Icons.close_rounded,
                            color: Colors.white),
                      ),
                  ],
                ),
              )
            : IconButton(
                tooltip: '快捷聊天',
                onPressed: _opening ? null : _open,
                icon: const Icon(Icons.chat_bubble_outline_rounded,
                    color: Colors.white),
              ),
      ),
    );
  }
}
