import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/pages/video/video_playback_args.dart';

/// Optional context carried from the persistent room page into source
/// selection and, eventually, the video route.
class InfoPageRouteArgs {
  const InfoPageRouteArgs({
    required this.bangumiItem,
    this.playbackLaunchIntent,
  });

  final BangumiItem bangumiItem;
  final SyncPlayPlaybackLaunchIntent? playbackLaunchIntent;
}
