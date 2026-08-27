/// The application-scoped owner of a SyncPlay room session.
///
/// The implementation currently lives in the historical controller file so
/// existing generated MobX code and feature imports remain source-compatible
/// while the ownership migration is completed in small commits.  This alias
/// is the single public type used by the application container; it does not
/// create a second room manager.
library;

export 'package:kazumi/pages/player/controller/player_syncplay_controller.dart'
    show PlayerSyncPlayController;

typedef SyncPlayRoomSessionController = PlayerSyncPlayController;
