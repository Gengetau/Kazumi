import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/pages/syncplay_room/syncplay_room_page.dart';
import 'package:kazumi/services/player/syncplay_room_session_controller.dart';

final syncPlayRoomModule = createModule(
  path: '/syncplay-room',
  register: (c) {
    c.route(
      '/',
      child: (context, state) => SyncPlayRoomPage(
        roomSession: inject<SyncPlayRoomSessionController>(),
      ),
    );
  },
);
