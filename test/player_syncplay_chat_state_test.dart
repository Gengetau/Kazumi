import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/pages/player/controller/player_models.dart';
import 'package:kazumi/pages/player/controller/player_syncplay_controller.dart';

PlayerSyncPlayController _controller() {
  return PlayerSyncPlayController(
    bangumiId: () => 1,
    currentEpisode: () => 1,
    currentRoad: () => 0,
    playing: () => false,
    currentPosition: () => Duration.zero,
    playerPosition: () => Duration.zero,
    duration: () => const Duration(minutes: 20),
    pause: ({bool enableSync = true}) async {},
    play: ({bool enableSync = true}) async {},
    seek: (duration, {bool enableSync = true}) async {},
  );
}

void main() {
  test('normalizes empty and unsafe server usernames to system identity', () {
    expect(normalizeSyncPlayUsername(null), '系统');
    expect(normalizeSyncPlayUsername(''), '系统');
    expect(normalizeSyncPlayUsername('bad\nname'), '系统');
    expect(normalizeSyncPlayUsername('alice'), 'alice');
  });

  test('invalid usernames and empty messages become system entries', () async {
    final controller = _controller();
    controller.appendUserMessage(username: '', message: 'hello');
    controller.appendUserMessage(username: 'friend', message: '   ');

    expect(controller.chatMessages, hasLength(2));
    expect(
      controller.chatMessages.every(
        (message) => message.type == SyncPlayChatMessageType.system,
      ),
      isTrue,
    );
    await controller.dispose();
  });

  test('starts disconnected and explicit exit returns to disconnected', () async {
    final controller = _controller();
    expect(
      controller.connectionState,
      SyncPlayConnectionState.disconnected,
    );
    await controller.exitRoom();
    expect(
      controller.connectionState,
      SyncPlayConnectionState.disconnected,
    );
    await controller.dispose();
  });

  test('stores local and remote messages with stable local ids', () async {
    final controller = _controller();
    controller.appendUserMessage(username: 'me', message: 'hello');
    controller.appendUserMessage(
      username: 'friend',
      message: 'hi',
      fromRemote: true,
    );

    expect(controller.chatMessages, hasLength(2));
    expect(controller.chatMessages.first.id, 1);
    expect(controller.chatMessages.last.id, 2);
    expect(controller.chatMessages.last.fromRemote, isTrue);
    await controller.dispose();
  });

  test(
    'remote user messages are streamed and increment hidden unread',
    () async {
      final controller = _controller();
      final events = <SyncPlayChatMessage>[];
      final subscription = controller.chatStream.listen(events.add);

      controller.appendUserMessage(username: 'friend', message: 'hello');
      controller.appendUserMessage(
        username: 'friend',
        message: 'remote',
        fromRemote: true,
      );
      controller.appendSystemMessage('joined');
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(2));
      expect(
        events.every((event) => event.type == SyncPlayChatMessageType.user),
        isTrue,
      );
      expect(controller.unreadChatCount, 1);
      await subscription.cancel();
      await controller.dispose();
    },
  );

  test('visible chat does not count remote messages and marks read', () async {
    final controller = _controller();
    controller.appendUserMessage(
      username: 'friend',
      message: 'hidden',
      fromRemote: true,
    );
    expect(controller.unreadChatCount, 1);

    controller.setChatVisible(true);
    expect(controller.unreadChatCount, 0);
    controller.appendUserMessage(
      username: 'friend',
      message: 'visible',
      fromRemote: true,
    );
    expect(controller.unreadChatCount, 0);
    await controller.dispose();
  });

  test('chat visibility follows app foreground and window focus', () async {
    final controller = _controller();
    controller.setChatVisible(true);
    expect(controller.chatVisible, isTrue);

    controller.setAppForeground(false);
    expect(controller.chatVisible, isFalse);
    controller.setAppForeground(true);
    expect(controller.chatVisible, isTrue);

    controller.setWindowFocused(false);
    expect(controller.chatVisible, isFalse);
    controller.setWindowFocused(true);
    expect(controller.chatVisible, isTrue);
    await controller.dispose();
  });

  test('clears local history without leaving the room', () async {
    final controller = _controller();
    controller.beginChatSession('room');
    controller.appendUserMessage(
      username: 'friend',
      message: 'hello',
      fromRemote: true,
    );
    controller.clearChatHistory();

    expect(controller.chatMessages, isEmpty);
    expect(controller.activeChatRoom, 'room');
    expect(controller.unreadChatCount, 0);
    await controller.dispose();
  });

  test('tracks mention unread separately from ordinary unread', () async {
    final controller = _controller();
    controller.appendUserMessage(
      username: 'friend',
      message: '@me hello',
      fromRemote: true,
      mentionsSelf: true,
    );
    controller.appendUserMessage(
      username: 'friend',
      message: 'ordinary',
      fromRemote: true,
    );

    expect(controller.unreadChatCount, 2);
    expect(controller.unreadMentionCount, 1);
    expect(controller.unreadChatLabel, '@1');
    controller.markChatRead();
    expect(controller.unreadMentionCount, 0);
    await controller.dispose();
  });

  test(
    'session mute removes existing messages and suppresses future ones',
    () async {
      final controller = _controller();
      controller.appendUserMessage(
        username: 'friend',
        message: 'before',
        fromRemote: true,
      );
      controller.setChatUserMuted('friend', true);
      controller.appendUserMessage(
        username: 'friend',
        message: 'after',
        fromRemote: true,
      );

      expect(controller.chatMessages, isEmpty);
      expect(controller.isChatUserMuted('friend'), isTrue);
      controller.setChatUserMuted('friend', false);
      controller.appendUserMessage(
        username: 'friend',
        message: 'visible again',
        fromRemote: true,
      );
      expect(controller.chatMessages.single.message, 'visible again');
      await controller.dispose();
    },
  );

  test('message grouping requires same user and a one-minute window', () {
    final first = SyncPlayChatMessage(
      id: 1,
      username: 'friend',
      message: 'one',
      fromRemote: true,
      time: DateTime(2026, 1, 1, 12),
    );
    final second = SyncPlayChatMessage(
      id: 2,
      username: 'friend',
      message: 'two',
      fromRemote: true,
      time: DateTime(2026, 1, 1, 12, 0, 59),
    );
    final late = SyncPlayChatMessage(
      id: 3,
      username: 'friend',
      message: 'three',
      fromRemote: true,
      time: DateTime(2026, 1, 1, 12, 2),
    );

    expect(second.canGroupWith(first), isTrue);
    expect(late.canGroupWith(second), isFalse);
    expect(syncPlayUsernameHash('friend'), syncPlayUsernameHash('friend'));
    expect(syncPlayUsernameInitial('friend'), 'f');
  });

  test('mentions require a username boundary', () {
    expect(syncPlayMessageMentionsUsername('@me hello', 'me'), isTrue);
    expect(syncPlayMessageMentionsUsername('hello @me!', 'me'), isTrue);
    expect(syncPlayMessageMentionsUsername('hello@me', 'me'), isFalse);
    expect(syncPlayMessageMentionsUsername('@merry', 'me'), isFalse);
    expect(syncPlayMessageMentionsUsername('@me_extra', 'me'), isFalse);
  });

  test('chat history is capped at 300 messages', () async {
    final controller = _controller();
    for (var i = 0; i < 301; i++) {
      controller.appendUserMessage(
        username: 'friend',
        message: '$i',
        fromRemote: true,
      );
    }

    expect(controller.chatMessages, hasLength(300));
    expect(controller.chatMessages.first.message, '1');
    expect(controller.chatMessages.last.message, '300');
    expect(controller.unreadChatCount, 301);
    await controller.dispose();
  });

  test(
    'preserves history for reconnect and clears when changing rooms',
    () async {
      final controller = _controller();
      controller.beginChatSession('room-a');
      controller.appendUserMessage(username: 'friend', message: 'old');
      controller.beginChatSession('room-a', preserveHistory: true);
      expect(controller.chatMessages, hasLength(1));

      controller.beginChatSession('room-b', preserveHistory: true);
      expect(controller.chatMessages, isEmpty);
      expect(controller.activeChatRoom, 'room-b');
      await controller.dispose();
    },
  );

  test('clears history on explicit exit', () async {
    final controller = _controller();
    controller.beginChatSession('room');
    controller.appendUserMessage(
      username: 'friend',
      message: 'hello',
      fromRemote: true,
    );
    await controller.exitRoom();

    expect(controller.chatMessages, isEmpty);
    expect(controller.unreadChatCount, 0);
    expect(controller.activeChatRoom, isEmpty);
    await controller.dispose();
  });

  test('rejects blank and overlong messages before sending', () async {
    final controller = _controller();
    expect(await controller.trySendChatMessage('   '), isFalse);
    expect(await controller.trySendChatMessage('a' * 501), isFalse);
    await controller.dispose();
  });

  test('does not write to a closed chat stream after dispose', () async {
    final controller = _controller();
    await controller.dispose();
    controller.emitChatMessage(
      username: 'friend',
      message: 'late',
      fromRemote: true,
    );
    expect(controller.chatMessages, isEmpty);
  });
}
