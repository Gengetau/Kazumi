import 'package:flutter/material.dart';

/// Keeps the embedded player in one render-tree slot through fullscreen and
/// rotation. Reparenting a live VideoPage between landscape Row and portrait
/// Column would destroy playback state and restart the selected episode.
class RoomPlaybackLayout extends StatelessWidget {
  const RoomPlaybackLayout({
    super.key,
    required this.stage,
    required this.details,
    required this.chat,
    required this.fullscreen,
  });

  final Widget stage;
  final Widget details;
  final Widget chat;
  final bool fullscreen;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final sideBySide =
            constraints.maxWidth >= 800 &&
            constraints.maxWidth > constraints.maxHeight;
        final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
        final controlsHeightLimit = keyboardOpen ? 116.0 : 156.0;
        final controlsPane = ConstrainedBox(
          constraints: BoxConstraints(maxHeight: controlsHeightLimit),
          child: SingleChildScrollView(child: details),
        );
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;
        final paneWidth = sideBySide ? (width - 1) * 3 / 5 : width;
        final maxPortraitStageHeight =
            (height - controlsHeightLimit - (keyboardOpen ? 166.0 : 146.0))
                .clamp(0.0, double.infinity);
        final normalStageHeight = sideBySide
            ? (height - controlsHeightLimit).clamp(0.0, double.infinity)
            : (height * (keyboardOpen ? 0.32 : 0.50)).clamp(
                0.0,
                maxPortraitStageHeight,
              );
        final chatTop = sideBySide
            ? 0.0
            : normalStageHeight + controlsHeightLimit + 1;
        final chatLeft = sideBySide ? paneWidth + 1 : 0.0;

        return Stack(
          children: [
            // Always first: preserves VideoPage/PlayerItem State during
            // fullscreen, screen rotation and media-details rebuilds.
            Positioned(
              left: 0,
              top: 0,
              width: fullscreen ? width : paneWidth,
              height: fullscreen ? height : normalStageHeight,
              child: SizedBox(
                key: const ValueKey('syncplay-playback-stage'),
                child: stage,
              ),
            ),
            Positioned(
              left: 0,
              top: normalStageHeight,
              width: paneWidth,
              height: controlsHeightLimit,
              child: Visibility(
                visible: !fullscreen,
                maintainState: true,
                child: controlsPane,
              ),
            ),
            Positioned(
              left: chatLeft,
              top: chatTop,
              width: width - chatLeft,
              height: sideBySide
                  ? height
                  : (height - chatTop).clamp(0.0, double.infinity),
              child: Visibility(
                visible: !fullscreen,
                maintainState: true,
                child: chat,
              ),
            ),
            if (sideBySide && !fullscreen)
              Positioned(
                left: paneWidth,
                top: 0,
                bottom: 0,
                child: const VerticalDivider(width: 1),
              ),
            if (!sideBySide && !fullscreen)
              Positioned(
                left: 0,
                right: 0,
                top: chatTop - 1,
                child: const Divider(height: 1),
              ),
          ],
        );
      },
    );
  }
}
