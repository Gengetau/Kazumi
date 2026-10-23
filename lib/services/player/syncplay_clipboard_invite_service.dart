import 'dart:async';

import 'package:flutter/services.dart';
import 'package:kazumi/services/player/syncplay_endpoint.dart';
import 'package:kazumi/services/player/syncplay_invite.dart';

enum SyncPlayClipboardCheckTrigger { startup, resume, userRequested }

final class SyncPlayClipboardInviteCandidate {
  const SyncPlayClipboardInviteCandidate({
    required this.invite,
    required this.rawText,
  });

  final SyncPlayInvite invite;
  final String rawText;
}

final class SyncPlayClipboardInviteService {
  SyncPlayClipboardInviteService({Future<String?> Function()? readClipboard})
      : _readClipboard = readClipboard ?? _platformRead;

  final Future<String?> Function() _readClipboard;
  SyncPlayClipboardInviteCandidate? _candidate;
  SyncPlayInvite? _pending;
  bool Function(SyncPlayInvite invite)? _activeMatcher;
  String? _lastFingerprint;

  final StreamController<SyncPlayInvite> _pendingController =
      StreamController.broadcast();

  SyncPlayClipboardInviteCandidate? get candidate => _candidate;
  SyncPlayInvite? get pending => _pending;
  Stream<SyncPlayInvite> get pendingStream => _pendingController.stream;

  void setActiveSessionMatcher(bool Function(SyncPlayInvite invite) matcher) {
    _activeMatcher = matcher;
  }

  Future<SyncPlayClipboardInviteCandidate?> check({
    SyncPlayClipboardCheckTrigger trigger =
        SyncPlayClipboardCheckTrigger.userRequested,
  }) async {
    final text = await _readClipboard();
    return observeText(text);
  }

  SyncPlayClipboardInviteCandidate? observeText(String? text) {
    final invite = SyncPlayInviteCodec.tryParse(text);
    if (invite == null || (_activeMatcher?.call(invite) ?? false)) return null;
    if (_pending?.fingerprint == invite.fingerprint) return null;
    if (_lastFingerprint == invite.fingerprint &&
        _candidate?.invite.fingerprint == invite.fingerprint) {
      return _candidate;
    }
    _lastFingerprint = invite.fingerprint;
    _candidate = SyncPlayClipboardInviteCandidate(
      invite: invite,
      rawText: text!,
    );
    return _candidate;
  }

  bool get candidateNeedsServerConfirmation {
    final invite = _candidate?.invite;
    if (invite == null) return false;
    final endpoint = parseSyncPlayEndPoint(invite.server);
    return endpoint == null || !isOfficialSyncPlayEndPoint(endpoint);
  }

  bool acceptCandidate({bool confirmUnknownServer = false}) {
    final candidate = _candidate;
    if (candidate == null ||
        (candidateNeedsServerConfirmation && !confirmUnknownServer)) {
      return false;
    }
    _pending = candidate.invite;
    _candidate = null;
    _pendingController.add(_pending!);
    return true;
  }

  void rejectCandidate() {
    _candidate = null;
  }

  SyncPlayInvite? takePending() {
    final value = _pending;
    _pending = null;
    return value;
  }

  static Future<String?> _platformRead() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    return data?.text;
  }
}
