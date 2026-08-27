import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:kazumi/services/player/syncplay_room_session_controller.dart';

class SyncPlayChatEntry extends StatelessWidget {
  const SyncPlayChatEntry({
    super.key,
    required this.controller,
    required this.onPressed,
  });

  final SyncPlayRoomSessionController controller;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Observer(
      builder: (context) {
        final unread = controller.unreadChatCount;
        final label = unread > 99 ? '99+' : '$unread';
        return Badge(
          isLabelVisible: unread > 0,
          label: Text(label),
          child: IconButton(
            color: Colors.white,
            icon: const Icon(Icons.chat_bubble_outline_rounded),
            tooltip: '聊天室',
            onPressed: onPressed,
          ),
        );
      },
    );
  }
}
