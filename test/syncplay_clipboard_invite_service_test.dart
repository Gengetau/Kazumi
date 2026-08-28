import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/player/syncplay_clipboard_invite_service.dart';

void main() {
  const text =
      'kazumi://syncplay/join?v=1&room=abc&server=syncplay.pl%3A8996&episode=1&bangumi=2';

  test('candidate cannot be consumed before acceptance', () async {
    final service = SyncPlayClipboardInviteService(
      readClipboard: () async => text,
    );
    expect(await service.check(), isNotNull);
    expect(service.takePending(), isNull);
    expect(service.acceptCandidate(), isTrue);
    expect(await service.check(), isNull);
    expect(service.takePending()!.room, 'abc');
  });

  test('suppresses the currently active room and endpoint', () async {
    final service = SyncPlayClipboardInviteService(
      readClipboard: () async => text,
    );
    service.setActiveSessionMatcher((invite) => invite.room == 'abc');
    expect(await service.check(), isNull);
  });

  test('custom server requires a second confirmation', () {
    final service = SyncPlayClipboardInviteService();
    service.observeText(
      'kazumi://syncplay/join?v=1&room=abc&server=example.com%3A8996&episode=1&bangumi=2',
    );
    expect(service.acceptCandidate(), isFalse);
    expect(service.acceptCandidate(confirmUnknownServer: true), isTrue);
  });
}
