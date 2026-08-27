import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/pages/player/controller/player_syncplay_controller.dart';
import 'package:kazumi/services/player/syncplay_invite.dart';

import 'syncplay_test_doubles.dart';

Future<void> _settle([int turns = 5]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('round trips a versioned invite', () {
    final text = SyncPlayInviteCodec.encode(
      room: 'room-1',
      server: 'syncplay.pl:8996',
      episode: 3,
      bangumi: 42,
    );
    final invite = SyncPlayInviteCodec.tryParse(text)!;
    expect(invite.room, 'room-1');
    expect(invite.episode, 3);
    expect(invite.bangumi, 42);
  });

  test('rejects unsupported and unrelated input', () {
    expect(
      SyncPlayInviteCodec.tryParse(
        'kazumi://syncplay/join?v=2&room=a&server=syncplay.pl%3A8996&episode=1&bangumi=1',
      ),
      isNull,
    );
    expect(SyncPlayInviteCodec.tryParse('https://example.com/room/1'), isNull);
    expect(
      SyncPlayInviteCodec.tryParse(List.filled(4097, 'x').join()),
      isNull,
    );
  });

  test('parses legacy Chinese text conservatively', () {
    final invite = SyncPlayInviteCodec.tryParse('''Kazumi 一起看邀请
房间：abc-1
服务器：syncplay.pl:8996
剧集：第 2 集
番剧 ID：99''')!;
    expect(invite.legacy, isTrue);
    expect(invite.episode, 2);
    expect(invite.bangumi, 99);
  });

  test('builds a parseable legacy invite before media is selected', () async {
    final client = FakeSyncplayClient();
    final controller = PlayerSyncPlayController(
      endpointProvider: () => 'syncplay.pl:8996',
      clientFactory: ({required String host, required int port}) => client,
    );
    await controller.createRoom('room-1', 'alice');

    final text = controller.syncPlayInviteText();
    final invite = SyncPlayInviteCodec.tryParse(text);

    expect(text, contains('当前观看：尚未选择'));
    expect(text, contains('打开 Kazumi → 聊天室 → 加入房间'));
    expect(invite, isNotNull);
    expect(invite!.room, 'room-1');
    expect(invite.server, 'syncplay.pl:8996');
    expect(invite.episode, isNull);
    expect(invite.bangumi, isNull);

    await controller.dispose();
    await client.closeStreams();
  });

  test('builds a parseable invite from authoritative room media', () async {
    final client = FakeSyncplayClient();
    final controller = PlayerSyncPlayController(
      endpointProvider: () => 'syncplay.pl:8996',
      clientFactory: ({required String host, required int port}) => client,
    );
    await controller.createRoom('room-1', 'alice');
    client.emitFileChanged(name: '12345[9]', setBy: 'alice');
    await _settle();

    final text = controller.syncPlayInviteText(
      localTitle: '本地标题',
      localBangumiId: 12345,
    );
    final invite = SyncPlayInviteCodec.tryParse(text);

    expect(text, contains('本地标题 · Bangumi #12345 · 第 9 集'));
    expect(invite, isNotNull);
    expect(invite!.bangumi, 12345);
    expect(invite.episode, 9);

    final mismatched = controller.syncPlayInviteText(
      localTitle: '不应出现',
      localBangumiId: 67890,
    );
    expect(mismatched, isNot(contains('不应出现')));
    expect(mismatched, contains('Bangumi #12345'));

    await controller.dispose();
    await client.closeStreams();
  });
}
