import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/pages/syncplay_room/room_playback_layout.dart';

class _PersistentPlayerProbe extends StatefulWidget {
  const _PersistentPlayerProbe({
    required this.onMount,
    required this.onDispose,
  });

  final VoidCallback onMount;
  final VoidCallback onDispose;

  @override
  State<_PersistentPlayerProbe> createState() => _PersistentPlayerProbeState();
}

class _PersistentPlayerProbeState extends State<_PersistentPlayerProbe> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      const ColoredBox(color: Colors.black, child: SizedBox.expand());
}

void main() {
  testWidgets('fullscreen fills screen without remounting the room player', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var mounts = 0;
    var disposals = 0;
    final player = _PersistentPlayerProbe(
      onMount: () => mounts++,
      onDispose: () => disposals++,
    );

    Widget room({required bool fullscreen}) => MaterialApp(
      home: Scaffold(
        appBar: fullscreen ? null : AppBar(title: const Text('房间')),
        body: RoomPlaybackLayout(
          stage: player,
          details: const SizedBox(height: 130, child: Text('媒体信息')),
          chat: const ColoredBox(
            color: Colors.white,
            child: Center(child: Text('聊天室')),
          ),
          fullscreen: fullscreen,
        ),
      ),
    );

    await tester.pumpWidget(room(fullscreen: false));
    final stage = find.byKey(const ValueKey('syncplay-playback-stage'));
    expect(tester.getSize(stage).width, 390);
    expect(
      tester.getSize(stage).height,
      closeTo((844 - kToolbarHeight) / 2, 2),
    );
    expect(find.text('聊天室'), findsOneWidget);
    expect(mounts, 1);

    await tester.pumpWidget(room(fullscreen: true));
    expect(tester.getSize(stage), const Size(390, 844));
    expect(find.text('聊天室'), findsNothing);
    expect(mounts, 1);
    expect(disposals, 0);

    await tester.binding.setSurfaceSize(const Size(900, 450));
    await tester.pump();
    expect(tester.getSize(stage), const Size(900, 450));
    expect(mounts, 1);

    await tester.pumpWidget(room(fullscreen: false));
    expect(find.text('聊天室'), findsOneWidget);
    expect(find.byType(VerticalDivider), findsOneWidget);
    expect(mounts, 1);
    expect(disposals, 0);
    expect(tester.takeException(), isNull);
  });
}
