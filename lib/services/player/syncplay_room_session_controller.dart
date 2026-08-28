import 'package:flutter/foundation.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/pages/player/controller/player_syncplay_controller.dart';

export 'package:kazumi/pages/player/controller/player_syncplay_controller.dart'
    show PlayerSyncPlayController, SyncplayClientFactory;

/// The application-scoped owner of a SyncPlay room session.
///
/// The implementation remains in the historical controller file so the
/// generated MobX store and legacy imports stay source-compatible. This
/// concrete type is the app-scope registration point and does not add a
/// second room manager or any additional state.
class SyncPlayRoomSessionController
    extends PlayerSyncPlayController
    implements Disposable {
  SyncPlayRoomSessionController({
    super.clientFactory,
    @visibleForTesting super.endpointProvider,
    @visibleForTesting super.mediaSelectionTimeout,
  });
}
