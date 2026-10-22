import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('home toolbar exposes persistent SyncPlay room entry', () {
    final home = File('lib/pages/popular/popular_page.dart').readAsStringSync();
    final actions = home
        .split('List<Widget> buildActions() {')
        .last
        .split('Future<void> _selectTag')
        .first;

    // This is an explicit source-to-navigation wiring regression guard. The
    // room page and its widget tests can pass even when a merge quietly drops
    // the only launcher visible on mobile's main screen.
    expect(actions, contains('const SyncPlayRoomEntryButton()'));

    final routes = File('lib/pages/index_module.dart').readAsStringSync();
    expect(routes, contains('..module(syncPlayRoomModule)'));
  });
}
