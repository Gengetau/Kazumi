import 'dart:async';

import 'package:flutter/material.dart';
import 'package:kazumi/bean/card/bangumi_card.dart';
import 'package:kazumi/bean/card/network_img_layer.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/pages/syncplay_room/media_picker/syncplay_room_media_picker_controller.dart';
import 'package:kazumi/pages/syncplay_room/media_picker/syncplay_room_episode_picker.dart';
import 'package:kazumi/utils/constants.dart';

/// Picks a Bangumi identity and episode before a room session sends the
/// corresponding id-only request to the server.
class SyncPlayRoomMediaPickerPage extends StatefulWidget {
  const SyncPlayRoomMediaPickerPage({super.key, this.controller});

  final SyncPlayRoomMediaPickerController? controller;

  @override
  State<SyncPlayRoomMediaPickerPage> createState() =>
      _SyncPlayRoomMediaPickerPageState();
}

class _SyncPlayRoomMediaPickerPageState
    extends State<SyncPlayRoomMediaPickerPage> {
  late final SyncPlayRoomMediaPickerController controller;
  late final bool _ownsController;
  late final TextEditingController _searchController;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    controller = widget.controller ?? SyncPlayRoomMediaPickerController();
    _searchController = TextEditingController();
    controller.addListener(_onControllerChanged);
    unawaited(controller.loadRecommendations());
  }

  @override
  void dispose() {
    controller.removeListener(_onControllerChanged);
    _searchController.dispose();
    if (_ownsController) {
      controller.dispose();
    }
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _submitSearch(String value) {
    _searchController.text = value;
    _searchController.selection = TextSelection.collapsed(offset: value.length);
    unawaited(controller.searchBangumi(value));
  }

  void _selectBangumi(BangumiItem bangumi) {
    FocusManager.instance.primaryFocus?.unfocus();
    unawaited(controller.selectBangumi(bangumi));
  }

  void _cancel() {
    Navigator.of(context).pop();
  }

  void _confirm() {
    final result = controller.confirmSelection();
    if (result == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请选择番剧和集数')));
      return;
    }
    Navigator.of(context).pop<SyncPlayRoomMediaSelection>(result);
  }

  int _crossCount(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (width >= LayoutBreakpoint.medium['width']!) return 6;
    if (width >= LayoutBreakpoint.compact['width']!) return 5;
    return width < 380 ? 2 : 3;
  }

  Widget _buildSearchField(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: TextField(
        controller: _searchController,
        textInputAction: TextInputAction.search,
        onChanged: controller.scheduleSearch,
        onSubmitted: _submitSearch,
        decoration: InputDecoration(
          hintText: '搜索番剧',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: controller.hasSearchQuery
              ? IconButton(
                  tooltip: '清除搜索',
                  onPressed: () {
                    _searchController.clear();
                    controller.clearSearch();
                  },
                  icon: const Icon(Icons.clear),
                )
              : null,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  Widget _buildError(
    BuildContext context,
    String message,
    VoidCallback onRetry,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }

  Widget _buildGrid(BuildContext context, List<BangumiItem> items) {
    final crossCount = _crossCount(context);
    final width = MediaQuery.sizeOf(context).width;
    final cardWidth =
        (width - 16 - (crossCount - 1) * StyleString.cardSpace) / crossCount;
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossCount,
        mainAxisSpacing: StyleString.cardSpace - 2,
        crossAxisSpacing: StyleString.cardSpace,
        mainAxisExtent:
            cardWidth / 0.65 + MediaQuery.textScalerOf(context).scale(32.0),
      ),
      itemCount: items.length,
      itemBuilder: (context, index) => BangumiCardV(
        bangumiItem: items[index],
        canTap: true,
        enableHero: false,
        onTap: _selectBangumi,
      ),
    );
  }

  Widget _buildBrowseResults(BuildContext context) {
    if (controller.hasSearchQuery) {
      if (controller.isLoadingSearch && controller.searchResults.isEmpty) {
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 40),
          child: Center(child: CircularProgressIndicator()),
        );
      }
      if (controller.searchError != null) {
        return _buildError(
          context,
          controller.searchError!,
          () => unawaited(controller.searchBangumi(controller.query)),
        );
      }
      if (controller.searchResults.isEmpty) {
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 40),
          child: Center(child: Text('没有找到匹配的番剧')),
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text('搜索结果'),
          ),
          _buildGrid(context, controller.searchResults),
        ],
      );
    }

    if (controller.isLoadingRecommendations &&
        controller.recommendations.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (controller.recommendationError != null) {
      return _buildError(
        context,
        controller.recommendationError!,
        () => unawaited(controller.loadRecommendations()),
      );
    }
    if (controller.recommendations.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: Text('暂无推荐番剧')),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text('推荐番剧'),
        ),
        _buildGrid(context, controller.recommendations),
      ],
    );
  }

  String _displayTitle(BangumiItem bangumi) {
    final title = bangumi.nameCn.trim();
    return title.isEmpty ? bangumi.name : title;
  }

  Widget _buildSelectedBangumi(BuildContext context) {
    final bangumi = controller.selectedBangumi;
    if (bangumi == null) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final title = _displayTitle(bangumi);
    final summary = bangumi.summary.trim();
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('已选择番剧', style: theme.textTheme.titleMedium),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                NetworkImgLayer(
                  src: bangumi.images['large'] ?? '',
                  width: 64,
                  height: 94,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title.isEmpty ? 'Bangumi #${bangumi.id}' : title,
                        style: theme.textTheme.titleMedium,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text('Bangumi #${bangumi.id}'),
                      if (summary.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          summary,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text('选择集数', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            SyncPlayRoomEpisodePicker(
              episodes: controller.episodes,
              selectedEpisode: controller.selectedEpisode,
              isLoading: controller.isLoadingEpisodes,
              error: controller.episodeError,
              onRetry: () => unawaited(controller.retryEpisodes()),
              onChanged: (episode) {
                controller.setEpisode(episode);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('选择房间番剧'),
        leading: IconButton(
          tooltip: '取消',
          onPressed: _cancel,
          icon: const Icon(Icons.close),
        ),
      ),
      body: Column(
        children: [
          _buildSearchField(context),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildBrowseResults(context),
                  _buildSelectedBangumi(context),
                ],
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _cancel,
                child: const Text('取消'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: controller.canConfirm ? _confirm : null,
                child: const Text('确认选择'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

typedef SyncPlayRoomMediaPicker = SyncPlayRoomMediaPickerPage;
