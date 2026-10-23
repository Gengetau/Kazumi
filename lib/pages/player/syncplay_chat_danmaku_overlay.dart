import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/material.dart';
import 'package:kazumi/pages/player/controller/player_chat_danmaku_controller.dart';

class SyncPlayChatDanmakuOverlay extends StatefulWidget {
  const SyncPlayChatDanmakuOverlay({
    super.key,
    required this.controller,
    required this.isPip,
  });

  final PlayerChatDanmakuController controller;
  final bool isPip;

  @override
  State<SyncPlayChatDanmakuOverlay> createState() =>
      _SyncPlayChatDanmakuOverlayState();
}

class _SyncPlayChatDanmakuOverlayState
    extends State<SyncPlayChatDanmakuOverlay> {
  DanmakuController? _attached;

  void _attach(DanmakuController controller) {
    if (identical(_attached, controller)) return;
    _detach();
    _attached = controller;
    widget.controller.attachCanvasController(controller);
  }

  void _detach() {
    widget.controller.detachCanvasController(_attached);
    _attached = null;
  }

  @override
  void didUpdateWidget(covariant SyncPlayChatDanmakuOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.detachCanvasController(_attached);
      _attached = null;
    }
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, child) {
        if (widget.isPip || !widget.controller.enabled) {
          _detach();
          return const SizedBox.shrink();
        }
        return IgnorePointer(
          child: RepaintBoundary(
            child: DanmakuScreen(
              createdController: _attach,
              option: DanmakuOption(
                hideTop: true,
                hideScroll: false,
                hideBottom: false,
                area: 0.35,
                opacity: 0.92,
                fontSize: 18,
                duration:
                    widget.controller.displayDuration.inMilliseconds / 1000,
                lineHeight: 1.4,
                strokeWidth: 1.0,
                fontWeight: FontWeight.w600.value,
                massiveMode: false,
              ),
            ),
          ),
        );
      },
    );
  }
}
