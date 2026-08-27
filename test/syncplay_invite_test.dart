import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/player/syncplay_invite.dart';

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
}
