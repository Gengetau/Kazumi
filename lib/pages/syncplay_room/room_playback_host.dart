import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/pages/history/history_controller.dart';
import 'package:kazumi/pages/player/player_controller.dart';
import 'package:kazumi/pages/video/video_controller.dart';
import 'package:kazumi/pages/video/video_page.dart';
import 'package:kazumi/pages/video/video_playback_args.dart';
import 'package:kazumi/repositories/download_repository.dart';
import 'package:kazumi/services/download/download_manager.dart';
import 'package:kazumi/services/player/audio_controller.dart';
import 'package:kazumi/services/player/syncplay_room_session_controller.dart';
import 'package:kazumi/services/shaders/shader_asset_service.dart';

/// Route-free playback host for the persistent SyncPlay room surface.
///
/// The controllers belong to this widget rather than to `/video`, so replacing
/// the selected source tears down only playback while the app-scoped room
/// socket, chat history and operator state remain alive.
class RoomPlaybackHost extends StatefulWidget {
  const RoomPlaybackHost({
    super.key,
    required this.args,
    required this.roomSession,
  });

  final OnlineVideoPlaybackArgs args;
  final SyncPlayRoomSessionController roomSession;

  @override
  State<RoomPlaybackHost> createState() => _RoomPlaybackHostState();
}

class _RoomPlaybackHostState extends State<RoomPlaybackHost> {
  late final HistoryController _historyController;
  late final DownloadController _downloadController;
  late final VideoPageController _videoPageController;
  late final PlayerController _playerController;

  @override
  void initState() {
    super.initState();
    _historyController = inject<HistoryController>();
    _downloadController = inject<DownloadController>();
    _videoPageController = VideoPageController(
      _historyController,
      inject<IDownloadRepository>(),
      inject<IDownloadManager>(),
    );
    _playerController = PlayerController(
      inject<ShaderAssetService>(),
      _downloadController,
      inject<AudioController>(),
      widget.roomSession,
    );
  }

  @override
  void dispose() {
    _playerController.dispose();
    _videoPageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: VideoPage(
        args: widget.args,
        playerController: _playerController,
        videoPageController: _videoPageController,
        historyController: _historyController,
        downloadController: _downloadController,
        roomSession: widget.roomSession,
        embedded: true,
      ),
    );
  }
}
