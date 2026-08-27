/// The one place where the legacy SyncPlay file-name media format is parsed.
///
/// SyncPlay peers exchange names such as `12345[9]`; only the Bangumi id and
/// episode are shared by the room session.
final class SyncPlayMediaCodec {
  static final RegExp _pattern = RegExp(r'^(\d+)\[(\d+)\]$');

  const SyncPlayMediaCodec._();

  static String encode({required int bangumiId, required int episode}) {
    if (bangumiId <= 0 || episode <= 0) {
      throw ArgumentError('Bangumi id and episode must be positive');
    }
    return '$bangumiId[$episode]';
  }

  static SyncPlayRoomMediaReference? tryParse(String value) {
    final match = _pattern.firstMatch(value.trim());
    if (match == null) {
      return null;
    }
    final bangumiId = int.tryParse(match.group(1) ?? '');
    final episode = int.tryParse(match.group(2) ?? '');
    if (bangumiId == null || episode == null || bangumiId <= 0 || episode <= 0) {
      return null;
    }
    return SyncPlayRoomMediaReference(
      bangumiId: bangumiId,
      episode: episode,
    );
  }
}

final class SyncPlayRoomMediaReference {
  final int bangumiId;
  final int episode;

  const SyncPlayRoomMediaReference({
    required this.bangumiId,
    required this.episode,
  });
}
