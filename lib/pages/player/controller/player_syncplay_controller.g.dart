// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'player_syncplay_controller.dart';

// **************************************************************************
// StoreGenerator
// **************************************************************************

// ignore_for_file: non_constant_identifier_names, unnecessary_brace_in_string_interps, unnecessary_lambdas, prefer_expression_function_bodies, lines_longer_than_80_chars, avoid_as, avoid_annotating_with_dynamic, no_leading_underscores_for_local_identifiers

mixin _$PlayerSyncPlayController on _PlayerSyncPlayController, Store {
  late final _$syncplayControllerAtom = Atom(
      name: '_PlayerSyncPlayController.syncplayController', context: context);

  @override
  SyncplayClient? get syncplayController {
    _$syncplayControllerAtom.reportRead();
    return super.syncplayController;
  }

  @override
  set syncplayController(SyncplayClient? value) {
    _$syncplayControllerAtom.reportWrite(value, super.syncplayController, () {
      super.syncplayController = value;
    });
  }

  late final _$syncplayRoomAtom =
      Atom(name: '_PlayerSyncPlayController.syncplayRoom', context: context);

  @override
  String get syncplayRoom {
    _$syncplayRoomAtom.reportRead();
    return super.syncplayRoom;
  }

  @override
  set syncplayRoom(String value) {
    _$syncplayRoomAtom.reportWrite(value, super.syncplayRoom, () {
      super.syncplayRoom = value;
    });
  }

  late final _$syncplayClientRttAtom = Atom(
      name: '_PlayerSyncPlayController.syncplayClientRtt', context: context);

  @override
  int get syncplayClientRtt {
    _$syncplayClientRttAtom.reportRead();
    return super.syncplayClientRtt;
  }

  @override
  set syncplayClientRtt(int value) {
    _$syncplayClientRttAtom.reportWrite(value, super.syncplayClientRtt, () {
      super.syncplayClientRtt = value;
    });
  }

  late final _$connectionStateAtom = Atom(
      name: '_PlayerSyncPlayController.connectionState', context: context);

  @override
  SyncPlayConnectionState get connectionState {
    _$connectionStateAtom.reportRead();
    return super.connectionState;
  }

  @override
  set connectionState(SyncPlayConnectionState value) {
    _$connectionStateAtom.reportWrite(value, super.connectionState, () {
      super.connectionState = value;
    });
  }

  late final _$unreadChatCountAtom =
      Atom(name: '_PlayerSyncPlayController.unreadChatCount', context: context);

  @override
  int get unreadChatCount {
    _$unreadChatCountAtom.reportRead();
    return super.unreadChatCount;
  }

  @override
  set unreadChatCount(int value) {
    _$unreadChatCountAtom.reportWrite(value, super.unreadChatCount, () {
      super.unreadChatCount = value;
    });
  }

  late final _$chatVisibleAtom =
      Atom(name: '_PlayerSyncPlayController.chatVisible', context: context);

  @override
  bool get chatVisible {
    _$chatVisibleAtom.reportRead();
    return super.chatVisible;
  }

  @override
  set chatVisible(bool value) {
    _$chatVisibleAtom.reportWrite(value, super.chatVisible, () {
      super.chatVisible = value;
    });
  }

  late final _$appForegroundAtom =
      Atom(name: '_PlayerSyncPlayController.appForeground', context: context);

  @override
  bool get appForeground {
    _$appForegroundAtom.reportRead();
    return super.appForeground;
  }

  @override
  set appForeground(bool value) {
    _$appForegroundAtom.reportWrite(value, super.appForeground, () {
      super.appForeground = value;
    });
  }

  late final _$windowFocusedAtom =
      Atom(name: '_PlayerSyncPlayController.windowFocused', context: context);

  @override
  bool get windowFocused {
    _$windowFocusedAtom.reportRead();
    return super.windowFocused;
  }

  @override
  set windowFocused(bool value) {
    _$windowFocusedAtom.reportWrite(value, super.windowFocused, () {
      super.windowFocused = value;
    });
  }

  late final _$chatDanmakuEnabledAtom = Atom(
      name: '_PlayerSyncPlayController.chatDanmakuEnabled', context: context);

  @override
  bool get chatDanmakuEnabled {
    _$chatDanmakuEnabledAtom.reportRead();
    return super.chatDanmakuEnabled;
  }

  @override
  set chatDanmakuEnabled(bool value) {
    _$chatDanmakuEnabledAtom.reportWrite(value, super.chatDanmakuEnabled, () {
      super.chatDanmakuEnabled = value;
    });
  }

  late final _$exitRoomAsyncAction =
      AsyncAction('_PlayerSyncPlayController.exitRoom', context: context);

  @override
  Future<void> exitRoom() {
    return _$exitRoomAsyncAction.run(() => super.exitRoom());
  }

  @override
  String toString() {
    return '''
syncplayController: ${syncplayController},
syncplayRoom: ${syncplayRoom},
syncplayClientRtt: ${syncplayClientRtt},
connectionState: ${connectionState},
unreadChatCount: ${unreadChatCount},
chatVisible: ${chatVisible},
appForeground: ${appForeground},
windowFocused: ${windowFocused},
chatDanmakuEnabled: ${chatDanmakuEnabled}
    ''';
  }
}
