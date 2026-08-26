import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/pages/player/controller/player_syncplay_controller.dart';
import 'package:kazumi/pages/player/syncplay_chat_panel.dart';
import 'package:kazumi/services/player/syncplay_client.dart';

PlayerSyncPlayController _controller({bool connected = false}) {
  final controller = PlayerSyncPlayController(
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
  if (connected) {
    controller.syncplayController = SyncplayClient(host: 'localhost', port: 1);
    controller.syncplayRoom = '123456';
  }
  return controller;
}

Widget _app(Widget child) {
  return MaterialApp(
    home: Scaffold(body: SizedBox(width: 400, height: 640, child: child)),
  );
}

Future<void> _disposePanel(
  WidgetTester tester,
  PlayerSyncPlayController controller,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await controller.dispose();
}

void main() {
  testWidgets('shows an empty state when no messages are available', (
    tester,
  ) async {
    final controller = _controller();
    await tester.pumpWidget(
      _app(
        SyncPlayChatPanel(controller: controller, onSend: (_) async => true),
      ),
    );

    expect(find.text('加入房间后开始聊天'), findsOneWidget);
    await _disposePanel(tester, controller);
  });

  testWidgets('aligns remote, local and system messages differently', (
    tester,
  ) async {
    final controller = _controller(connected: true);
    controller.appendSystemMessage('friend 加入了房间');
    controller.appendUserMessage(
      username: 'friend',
      message: 'hello',
      fromRemote: true,
    );
    controller.appendUserMessage(username: 'me', message: 'hi');
    await tester.pumpWidget(
      _app(
        SyncPlayChatPanel(controller: controller, onSend: (_) async => true),
      ),
    );
    await tester.pump();

    final panelRect = tester.getRect(find.byType(ListView));
    final remoteRect = tester.getRect(find.byKey(const ValueKey<int>(2)));
    final localRect = tester.getRect(find.byKey(const ValueKey<int>(3)));
    final systemRect = tester.getRect(find.byKey(const ValueKey<int>(1)));
    expect(remoteRect.center.dx, lessThan(panelRect.center.dx));
    expect(localRect.center.dx, greaterThan(panelRect.center.dx));
    expect(systemRect.center.dx, closeTo(panelRect.center.dx, 1));

    await _disposePanel(tester, controller);
  });

  testWidgets('sends trimmed input and clears it after success', (
    tester,
  ) async {
    final controller = _controller(connected: true);
    String? sent;
    await tester.pumpWidget(
      _app(
        SyncPlayChatPanel(
          controller: controller,
          onSend: (message) async {
            sent = message;
            return true;
          },
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), '  hello  ');
    await tester.pump();
    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();

    expect(sent, 'hello');
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    await _disposePanel(tester, controller);
  });

  testWidgets('keeps input and reports an error after failed send', (
    tester,
  ) async {
    final controller = _controller(connected: true);
    await tester.pumpWidget(
      _app(
        SyncPlayChatPanel(controller: controller, onSend: (_) async => false),
      ),
    );

    await tester.enterText(find.byType(TextField), 'keep this');
    await tester.pump();
    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'keep this',
    );
    expect(find.text('发送失败，请检查连接后重试'), findsOneWidget);
    await _disposePanel(tester, controller);
  });

  testWidgets('disables the composer when no room is connected', (
    tester,
  ) async {
    final controller = _controller();
    await tester.pumpWidget(
      _app(
        SyncPlayChatPanel(controller: controller, onSend: (_) async => true),
      ),
    );

    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    expect(find.text('加入房间后即可聊天'), findsOneWidget);
    await _disposePanel(tester, controller);
  });

  testWidgets('accepts a long unbroken message without overflow', (
    tester,
  ) async {
    final controller = _controller(connected: true);
    await tester.pumpWidget(
      _app(
        SyncPlayChatPanel(controller: controller, onSend: (_) async => true),
      ),
    );

    await tester.enterText(find.byType(TextField), 'a' * 500);
    await tester.pump();

    expect(tester.takeException(), isNull);
    await _disposePanel(tester, controller);
  });
}
