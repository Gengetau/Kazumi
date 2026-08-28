import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/pages/player/controller/player_chat_danmaku_controller.dart';

void main() {
  test('bounds chat danmaku and expires on its own clock', () {
    var now = DateTime(2026);
    final controller = PlayerChatDanmakuController(
      now: () => now,
      displayDuration: const Duration(seconds: 5),
    );
    for (var i = 0; i < 25; i++) {
      controller.addMessage('message $i', username: 'friend');
    }
    expect(controller.pendingCount, 20);
    expect(controller.pendingDanmakus.first.message, 'friend：message 5');
    now = now.add(const Duration(seconds: 5));
    controller.tick();
    expect(controller.pendingDanmakus, isEmpty);
    controller.dispose();
  });

  test('disabled chat danmaku rejects messages independently', () {
    final controller = PlayerChatDanmakuController();
    controller.setEnabled(false);
    expect(controller.addMessage('hidden'), isFalse);
    expect(controller.pendingDanmakus, isEmpty);
    controller.dispose();
  });
}
