import 'package:kazumi/services/player/syncplay_endpoint.dart';

final class SyncPlayInvite {
  const SyncPlayInvite({
    required this.room,
    required this.server,
    this.episode,
    this.bangumi,
    this.legacy = false,
  });

  final String room;
  final String server;
  final int? episode;
  final int? bangumi;
  final bool legacy;

  String get fingerprint =>
      '${room.trim()}|${server.toLowerCase()}|${bangumi ?? ''}|${episode ?? ''}';
}

final class SyncPlayInviteCodec {
  SyncPlayInviteCodec._();

  static const int maxLength = 4096;

  static String encode({
    required String room,
    required String server,
    required int episode,
    required int bangumi,
  }) {
    if (!_validRoom(room) ||
        parseSyncPlayEndPoint(server) == null ||
        episode <= 0 ||
        bangumi <= 0) {
      throw ArgumentError('invalid SyncPlay invitation');
    }
    return Uri(
      scheme: 'kazumi',
      host: 'syncplay',
      path: '/join',
      queryParameters: {
        'v': '1',
        'room': room.trim(),
        'server': server.trim(),
        'episode': '$episode',
        'bangumi': '$bangumi',
      },
    ).toString();
  }

  static SyncPlayInvite? tryParse(String? raw) {
    if (raw == null) return null;
    final text = raw.trim();
    if (text.isEmpty || text.length > maxLength) return null;
    final uriStart = text.indexOf('kazumi://');
    if (uriStart >= 0) {
      final uriText = text.substring(uriStart).split(RegExp(r'\s')).first;
      return _parseUri(uriText);
    }
    return _parseLegacy(text);
  }

  static SyncPlayInvite? _parseUri(String raw) {
    Uri uri;
    try {
      uri = Uri.parse(raw);
    } on FormatException {
      return null;
    }
    if (uri.scheme != 'kazumi' ||
        uri.host != 'syncplay' ||
        uri.path != '/join' ||
        uri.queryParameters['v'] != '1') {
      return null;
    }
    final room = uri.queryParameters['room']?.trim() ?? '';
    final server = uri.queryParameters['server']?.trim() ?? '';
    final episode = int.tryParse(uri.queryParameters['episode'] ?? '');
    final bangumi = int.tryParse(uri.queryParameters['bangumi'] ?? '');
    if (!_validRoom(room) ||
        parseSyncPlayEndPoint(server) == null ||
        episode == null ||
        episode <= 0 ||
        bangumi == null ||
        bangumi <= 0) {
      return null;
    }
    return SyncPlayInvite(
      room: room,
      server: server,
      episode: episode,
      bangumi: bangumi,
    );
  }

  static SyncPlayInvite? _parseLegacy(String text) {
    if (RegExp(r'https?://', caseSensitive: false).hasMatch(text) ||
        !text.contains('房间')) {
      return null;
    }
    String? capture(String pattern) =>
        RegExp(pattern, caseSensitive: false, multiLine: true)
            .firstMatch(text)
            ?.group(1)
            ?.trim();
    final room = capture(r'(?:房间号?|room)\s*[：:]\s*([A-Za-z0-9._-]+)');
    final server = capture(
      r'(?:服务器(?:地址)?|server|endpoint)\s*[：:]\s*([^\s，,]+)',
    );
    if (room == null ||
        server == null ||
        !_validRoom(room) ||
        parseSyncPlayEndPoint(server) == null) {
      return null;
    }
    final episodeText = capture(
      r'(?:剧集|集数|episode)\s*[：:]?\s*(?:第\s*)?(\d+)',
    );
    final bangumiText = capture(
      r'(?:番剧\s*(?:id)?|bangumi(?:id)?)\s*[：:]\s*(\d+)',
    );
    final episode = episodeText == null ? null : int.tryParse(episodeText);
    final bangumi = bangumiText == null ? null : int.tryParse(bangumiText);
    if ((episode != null && episode <= 0) ||
        (bangumi != null && bangumi <= 0)) {
      return null;
    }
    return SyncPlayInvite(
      room: room,
      server: server,
      episode: episode,
      bangumi: bangumi,
      legacy: true,
    );
  }

  static bool _validRoom(String room) =>
      room.trim().isNotEmpty &&
      room.length <= 128 &&
      RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(room);
}
