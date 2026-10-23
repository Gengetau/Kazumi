import 'package:kazumi/modules/bangumi/bangumi_item.dart';

/// A local picker result for a room media request.
///
/// Only the Bangumi identity and episode cross the room boundary.  Plugin
/// names, source URLs and other playback details stay local to each client.
final class SyncPlayRoomMediaSelection {
  const SyncPlayRoomMediaSelection({
    required this.bangumi,
    required this.episode,
  });

  final BangumiItem bangumi;
  final int episode;
}
