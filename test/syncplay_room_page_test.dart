import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/navigation.dart';
import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/pages/info/info_route_args.dart';
import 'package:kazumi/pages/syncplay_room/syncplay_room_entry_button.dart';
import 'package:kazumi/pages/syncplay_room/syncplay_room_page.dart';
import 'package:kazumi/pages/video/video_playback_args.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/services/player/syncplay_managed_room_models.dart';
import 'package:kazumi/services/player/syncplay_room_models.dart';
import 'package:kazumi/services/player/syncplay_room_session_controller.dart';

import 'syncplay_test_doubles.dart';

const _managedRoom = '+room-a:ABCDEF123456';
const _managedFeatures = SyncplayServerFeatures(
  managedRooms: true,
  sharedPlaylists: true,
  chat: true,
  readiness: true,
  featureList: true,
);

Future<void> _settle([int turns = 5]) async {
  for (var i = 0; i < turns; i++) {
    // Widget tests run in FakeAsync. A zero-duration Future.delayed still
    // creates a timer and can wait forever unless WidgetTester pumps time.
    // StreamController delivery only needs microtask turns here.
    await Future<void>.value();
  }
}

Future<void> _settleUntil(bool Function() predicate) async {
  for (var i = 0; i < 100; i++) {
    if (predicate()) {
      return;
    }
    await Future<void>.value();
  }
  fail('Condition did not settle');
}

BangumiItem _bangumi(int id, String title) {
  return BangumiItem(
    id: id,
    type: 2,
    name: title,
    nameCn: title,
    summary: '',
    airDate: '',
    airWeekday: 0,
    rank: 0,
    images: const <String, String>{},
    tags: [],
    alias: [],
    ratingScore: 0,
    votes: 0,
    votesCount: [],
    info: '',
  );
}

SyncPlayRoomSessionController _sessionFor(FakeSyncplayClient client) {
  return SyncPlayRoomSessionController(
    endpointProvider: () => 'localhost:8996',
    clientFactory: ({required String host, required int port}) => client,
  );
}

Future<void> _connectManagedRoom(
  SyncPlayRoomSessionController session,
  FakeSyncplayClient client, {
  bool localOperator = false,
  bool includeHost = true,
}) async {
  final join = session.createRoom(_managedRoom, 'alice');
  await _settleUntil(() => client.userListRequests == 1);
  client.emitUserList([
    SyncplayRoomUser(
      username: 'server-alice',
      room: _managedRoom,
      isController: localOperator,
    ),
    if (includeHost)
      const SyncplayRoomUser(
        username: 'host',
        room: _managedRoom,
        isController: true,
      ),
  ]);
  await join;
}

Future<void> _disposeSession(
  SyncPlayRoomSessionController session,
  FakeSyncplayClient client,
) async {
  await session.dispose();
  await client.closeStreams();
}

Future<void> _disposeWidgetSession(
  WidgetTester tester,
  SyncPlayRoomSessionController session,
  FakeSyncplayClient client,
) async {
  await tester.runAsync(() async {
    await _disposeSession(session, client);
  });
}

Future<void> _pumpRoomPage(
  WidgetTester tester,
  SyncPlayRoomSessionController session, {
  Future<BangumiItem?> Function(int bangumiId)? bangumiInfoLoader,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      navigatorObservers: [rootRouteObserver],
      home: SyncPlayRoomPage(
        roomSession: session,
        bangumiInfoLoader: bangumiInfoLoader,
      ),
    ),
  );
  await tester.pump();
}

Future<void> _unmountRoomPage(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await _settle();
}

void main() {
  testWidgets('disconnected room page offers create and join', (
    WidgetTester tester,
  ) async {
    final client = FakeSyncplayClient();
    final session = _sessionFor(client);
    await _pumpRoomPage(tester, session);

    expect(find.text('创建房间'), findsOneWidget);
    expect(find.text('加入房间'), findsWidgets);

    await _unmountRoomPage(tester);
    await _disposeWidgetSession(tester, session, client);
  });

  testWidgets('connected room without media shows the empty state', (
    WidgetTester tester,
  ) async {
    final client = FakeSyncplayClient();
    final session = _sessionFor(client);
    await session.createRoom('room-a', 'alice');
    await _pumpRoomPage(tester, session);

    expect(find.text('当前观看'), findsOneWidget);
    expect(find.text('暂未选择番剧'), findsOneWidget);
    expect(find.text('选择番剧'), findsOneWidget);
    expect(session.currentMedia, isNull);

    await _unmountRoomPage(tester);
    await _disposeWidgetSession(tester, session, client);
  });

  testWidgets('create form exposes free and host-controlled room modes', (
    WidgetTester tester,
  ) async {
    final client = FakeSyncplayClient();
    final session = _sessionFor(client);
    await _pumpRoomPage(tester, session);

    await tester.tap(find.text('创建房间'));
    await tester.pumpAndSettle();

    expect(find.text('控制模式'), findsOneWidget);
    expect(find.text('自由控制'), findsOneWidget);
    expect(find.text('房主控制'), findsOneWidget);
    expect(find.text('所有成员均可控制播放、进度与选集'), findsOneWidget);
    expect(find.text('只有主持人可以修改共享播放状态'), findsOneWidget);

    await _unmountRoomPage(tester);
    await _disposeWidgetSession(tester, session, client);
  });

  testWidgets('managed room shows operators and locks media selection', (
    WidgetTester tester,
  ) async {
    final client = FakeSyncplayClient(
      acceptedRoom: _managedRoom,
      serverFeatures: _managedFeatures,
    );
    final session = _sessionFor(client);
    await _connectManagedRoom(session, client);
    await _pumpRoomPage(tester, session);

    expect(find.text('房间 room-a'), findsWidgets);
    expect(find.textContaining('房主控制'), findsWidgets);
    expect(find.text('同步服务器'), findsNothing);
    expect(find.text('分享房间号，好友即可加入'), findsNothing);
    expect(find.text('当前观看'), findsOneWidget);
    expect(find.text('等待主持人选择'), findsOneWidget);
    expect(session.canSelectRoomMedia, isFalse);

    await tester.tap(find.byTooltip('房间操作'));
    await tester.pumpAndSettle();
    expect(find.text('成为共同主持人'), findsOneWidget);
    expect(find.text('复制主持密码'), findsNothing);

    await _unmountRoomPage(tester);
    await _disposeWidgetSession(tester, session, client);
  });

  testWidgets('unique operator exit warns that the room will have no host', (
    WidgetTester tester,
  ) async {
    final client = FakeSyncplayClient(
      acceptedRoom: _managedRoom,
      serverFeatures: _managedFeatures,
    );
    final session = _sessionFor(client);
    await _connectManagedRoom(
      session,
      client,
      localOperator: true,
      includeHost: false,
    );
    await _pumpRoomPage(tester, session);

    await tester.tap(find.byTooltip('房间操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('退出聊天室'));
    await tester.pumpAndSettle();

    expect(find.text('你是当前唯一主持人'), findsOneWidget);
    expect(find.textContaining('其他成员将无法控制共享播放'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '仍然退出'), findsOneWidget);

    Navigator.of(tester.element(find.text('你是当前唯一主持人'))).pop(false);
    await tester.pumpAndSettle();
    await _unmountRoomPage(tester);
    await _disposeWidgetSession(tester, session, client);
  });

  testWidgets('room media card renders the resolved title and episode', (
    WidgetTester tester,
  ) async {
    final client = FakeSyncplayClient();
    final session = _sessionFor(client);
    await session.createRoom('room-a', 'alice');
    client.emitFileChanged(name: '12345[9]', setBy: 'peer');
    await _settle();
    await _pumpRoomPage(
      tester,
      session,
      bangumiInfoLoader: (id) async => _bangumi(id, '测试番剧'),
    );
    await _settle();
    await tester.pump();

    expect(find.text('测试番剧'), findsOneWidget);
    expect(find.textContaining('第 9 集'), findsOneWidget);
    expect(find.textContaining('peer 选择'), findsOneWidget);
    expect(find.text('等待选择播放源'), findsOneWidget);

    await _unmountRoomPage(tester);
    await _disposeWidgetSession(tester, session, client);
  });

  testWidgets('connected landscape room uses side-by-side media and chat', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final client = FakeSyncplayClient();
    final session = _sessionFor(client);
    await session.createRoom('room-a', 'alice');
    await _pumpRoomPage(tester, session);

    expect(find.byType(VerticalDivider), findsOneWidget);
    expect(find.text('当前观看'), findsOneWidget);

    await _unmountRoomPage(tester);
    await _disposeWidgetSession(tester, session, client);
  });

  testWidgets('room page keeps chat usable without a player', (
    WidgetTester tester,
  ) async {
    final client = FakeSyncplayClient();
    final session = _sessionFor(client);
    await session.createRoom('room-a', 'alice');
    await _pumpRoomPage(tester, session);

    expect(session.hasPlaybackBinding, isFalse);
    client.emitChat(username: 'peer', message: '先聊一会儿');
    await _settle();
    await tester.pump();

    expect(find.text('先聊一会儿'), findsOneWidget);
    expect(client.connected, isTrue);

    await _unmountRoomPage(tester);
    await _disposeWidgetSession(tester, session, client);
  });

  testWidgets('leaving the room page preserves the app-scoped connection', (
    WidgetTester tester,
  ) async {
    final client = FakeSyncplayClient();
    final session = _sessionFor(client);
    await session.createRoom('room-a', 'alice');
    client.emitFileChanged(name: '12345[9]');
    await _settle();
    final media = session.currentMedia;

    await _pumpRoomPage(
      tester,
      session,
      bangumiInfoLoader: (id) async => _bangumi(id, '测试番剧'),
    );
    await _unmountRoomPage(tester);

    expect(client.disconnectCalls, 0);
    expect(client.connected, isTrue);
    expect(session.syncplayRoom, 'room-a');
    expect(session.currentMedia, same(media));

    await _disposeWidgetSession(tester, session, client);
  });

  testWidgets('explicit room exit disconnects and clears session state', (
    WidgetTester tester,
  ) async {
    final client = FakeSyncplayClient();
    final session = _sessionFor(client);
    await session.createRoom('room-a', 'alice');
    session.appendUserMessage(
      username: 'peer',
      message: '留下记录',
      fromRemote: true,
    );
    client.emitFileChanged(name: '12345[9]');
    await _settle();
    await _pumpRoomPage(
      tester,
      session,
      bangumiInfoLoader: (id) async => _bangumi(id, '测试番剧'),
    );

    await tester.tap(find.byTooltip('房间操作'));
    await tester.pumpAndSettle();
    expect(find.text('退出聊天室'), findsOneWidget);
    await tester.tap(find.text('退出聊天室'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, '退出聊天室'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '退出聊天室'));
    await tester.pumpAndSettle();

    expect(client.disconnectCalls, 1);
    expect(client.connected, isFalse);
    expect(session.syncplayRoom, isEmpty);
    expect(session.currentMedia, isNull);
    expect(session.chatMessages, isEmpty);

    await _unmountRoomPage(tester);
    await _disposeWidgetSession(tester, session, client);
  });

  testWidgets('home room entry shows unread badge without a player', (
    WidgetTester tester,
  ) async {
    final client = FakeSyncplayClient();
    final session = _sessionFor(client);
    await session.createRoom('room-a', 'alice');
    session.appendUserMessage(
      username: 'peer',
      message: '未读消息',
      fromRemote: true,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SyncPlayRoomEntryButton(controller: session)),
      ),
    );
    await tester.pump();

    expect(find.byTooltip('一起看：已连接，1 条未读'), findsOneWidget);
    expect(find.byType(Badge), findsOneWidget);

    await _unmountRoomPage(tester);
    await _disposeWidgetSession(tester, session, client);
  });

  testWidgets('covered room page records incoming chat as unread', (
    WidgetTester tester,
  ) async {
    final client = FakeSyncplayClient();
    final session = _sessionFor(client);
    await session.createRoom('room-a', 'alice');
    await _pumpRoomPage(tester, session);

    final roomContext = tester.element(find.byType(SyncPlayRoomPage));
    Navigator.of(roomContext).push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('covering route')),
      ),
    );
    await tester.pumpAndSettle();

    client.emitChat(username: 'peer', message: '被覆盖时收到');
    await _settle();
    await tester.pump();
    expect(session.unreadChatCount, 1);

    Navigator.of(tester.element(find.text('covering route'))).pop();
    await tester.pumpAndSettle();
    expect(session.unreadChatCount, 0);

    await _unmountRoomPage(tester);
    await _disposeWidgetSession(tester, session, client);
  });

  test('room-first route carries its launch intent through source args', () {
    final bangumi = _bangumi(12345, '测试番剧');
    const intent = SyncPlayPlaybackLaunchIntent(
      expectedBangumiId: 12345,
      expectedEpisode: 9,
      expectedMediaGeneration: 3,
    );
    final infoArgs = InfoPageRouteArgs(
      bangumiItem: bangumi,
      playbackLaunchIntent: intent,
    );
    final videoArgs = OnlineVideoPlaybackArgs(
      bangumiItem: infoArgs.bangumiItem,
      plugin: Plugin.fromTemplate(),
      title: bangumi.name,
      src: 'https://example.com/episode',
      roads: [
        Road(
          name: 'source',
          data: ['episode-1', 'episode-2', 'episode-3'],
          identifier: ['1', '2', '3'],
        ),
      ],
      launchIntent: infoArgs.playbackLaunchIntent,
    );

    expect(videoArgs.bangumiItem, same(bangumi));
    expect(videoArgs.launchIntent, same(intent));
    expect(videoArgs.playbackLaunchIntent, same(intent));
  });

  test('stale room media generation invalidates a launch intent', () async {
    final client = FakeSyncplayClient();
    final session = _sessionFor(client);
    await session.createRoom('room-a', 'alice');
    const intent = SyncPlayPlaybackLaunchIntent(
      expectedBangumiId: 12345,
      expectedEpisode: 9,
      expectedMediaGeneration: 0,
    );

    expect(session.isPlaybackLaunchIntentCurrent(intent), isTrue);
    client.emitFileChanged(name: '67890[3]', setBy: 'peer');
    await _settle();

    expect(session.isPlaybackLaunchIntentCurrent(intent), isFalse);
    await _disposeSession(session, client);
  });

  test(
    'room media mismatch never blindly switches to another Bangumi',
    () async {
      final client = FakeSyncplayClient();
      final session = _sessionFor(client);
      await session.createRoom('room-a', 'alice');
      client.emitFileChanged(name: '67890[3]', setBy: 'peer');
      await _settle();
      final binding = FakePlaybackBinding(bangumiId: 12345, currentEpisode: 3);

      final events = <SyncPlayRoomMediaEvent>[];
      final subscription = session.mediaEvents.listen(events.add);
      session.attachPlayback(binding);
      await _settle();

      expect(binding.episodeChanges, isEmpty);
      expect(events.whereType<SyncPlayRoomMediaMismatch>(), hasLength(1));
      await subscription.cancel();
      await _disposeSession(session, client);
    },
  );

  test(
    'same-Bangumi room media follows its selected episode on attach',
    () async {
      final client = FakeSyncplayClient();
      final session = _sessionFor(client);
      await session.createRoom('room-a', 'alice');
      client.emitFileChanged(name: '12345[9]', setBy: 'peer');
      await _settle();
      final binding = FakePlaybackBinding(bangumiId: 12345, currentEpisode: 8);

      session.attachPlayback(binding);
      await _settle();

      expect(binding.episodeChanges, [9]);
      expect(binding.currentEpisode, 9);
      await _disposeSession(session, client);
    },
  );
}
