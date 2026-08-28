import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/pages/player/player_panel_hold.dart';
import 'package:kazumi/pages/player/syncplay_quick_chat_composer.dart';

void main() {
  testWidgets('keeps the draft when sending fails', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SyncPlayQuickChatComposer(
          compact: true,
          ensureReady: () async => true,
          onSend: (_) async => false,
          acquirePlayerPanelHold: () =>
              PlayerPanelHold(onRelease: () {}),
        ),
      ),
    ));
    await tester.tap(find.byTooltip('快捷聊天'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'draft');
    await tester.tap(find.byTooltip('发送聊天消息'));
    await tester.pump();
    expect(find.text('draft'), findsOneWidget);
  });
}
