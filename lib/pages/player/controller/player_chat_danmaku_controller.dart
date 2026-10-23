import 'dart:async';
import 'dart:collection';

import 'package:canvas_danmaku/canvas_danmaku.dart' as canvas;
import 'package:canvas_danmaku/models/danmaku_content_item.dart';
import 'package:flutter/material.dart';

class PlayerChatDanmakuEntry {
  const PlayerChatDanmakuEntry({
    required this.id,
    required this.message,
    required this.createdAt,
  });

  final int id;
  final String message;
  final DateTime createdAt;
}

class PlayerChatDanmakuController extends ChangeNotifier {
  PlayerChatDanmakuController({
    bool initialEnabled = true,
    this.displayDuration = const Duration(seconds: 8),
    DateTime Function()? now,
    this.onEnabledChanged,
  })  : _enabled = initialEnabled,
        _now = now ?? DateTime.now;

  static const int maxPendingDanmakus = 20;
  final Duration displayDuration;
  final ValueChanged<bool>? onEnabledChanged;
  final DateTime Function() _now;
  final List<PlayerChatDanmakuEntry> _pending = [];
  canvas.DanmakuController? _canvasController;
  Timer? _clock;
  bool _enabled;
  bool _disposed = false;
  int _nextId = 1;

  bool get enabled => _enabled;
  List<PlayerChatDanmakuEntry> get pendingDanmakus =>
      UnmodifiableListView(_pending);
  int get pendingCount => _pending.length;

  void attachCanvasController(canvas.DanmakuController controller) {
    if (_disposed || identical(_canvasController, controller)) return;
    _canvasController = controller;
    for (final entry in _pending) {
      _render(entry);
    }
  }

  void detachCanvasController([canvas.DanmakuController? controller]) {
    if (controller == null || identical(controller, _canvasController)) {
      _canvasController = null;
    }
  }

  void setEnabled(bool value) {
    if (_disposed || value == _enabled) return;
    _enabled = value;
    if (!value) {
      clear();
    } else {
      notifyListeners();
    }
    onEnabledChanged?.call(value);
  }

  bool addMessage(String rawMessage, {String? username}) {
    if (_disposed || !_enabled || rawMessage.trim().isEmpty) return false;
    final user = username?.trim() ?? '';
    final entry = PlayerChatDanmakuEntry(
      id: _nextId++,
      message: user.isEmpty ? rawMessage.trim() : '$user：${rawMessage.trim()}',
      createdAt: _now(),
    );
    _pending.add(entry);
    while (_pending.length > maxPendingDanmakus) {
      _pending.removeAt(0);
    }
    _render(entry);
    _clock ??= Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => tick(),
    );
    notifyListeners();
    return true;
  }

  void _render(PlayerChatDanmakuEntry entry) {
    _canvasController?.addDanmaku(
      DanmakuContentItem(
        entry.message,
        color: Colors.orange,
        isColorful: true,
        type: canvas.DanmakuItemType.bottom,
        extra: entry.id,
      ),
    );
  }

  void tick() {
    if (_disposed) return;
    final now = _now();
    _pending.removeWhere(
      (entry) => !entry.createdAt.add(displayDuration).isAfter(now),
    );
    if (_pending.isEmpty) {
      _clock?.cancel();
      _clock = null;
    }
    notifyListeners();
  }

  void clear() {
    if (_disposed) return;
    _pending.clear();
    _clock?.cancel();
    _clock = null;
    _canvasController?.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _clock?.cancel();
    _canvasController?.clear();
    _canvasController = null;
    _pending.clear();
    super.dispose();
  }
}
