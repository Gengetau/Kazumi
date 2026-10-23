import 'package:flutter/material.dart';

/// Compact episode selector used by the room media picker.
class SyncPlayRoomEpisodePicker extends StatelessWidget {
  const SyncPlayRoomEpisodePicker({
    super.key,
    required this.episodes,
    required this.selectedEpisode,
    required this.onChanged,
    this.isLoading = false,
    this.error,
    this.onRetry,
  });

  final List<int> episodes;
  final int selectedEpisode;
  final ValueChanged<int> onChanged;
  final bool isLoading;
  final String? error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final chips = episodes
        .map(
          (episode) => ChoiceChip(
            label: Text('$episode'),
            selected: selectedEpisode == episode,
            onSelected: (_) => onChanged(episode),
          ),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (error != null) ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
              if (onRetry != null)
                TextButton(onPressed: onRetry, child: const Text('重试')),
            ],
          ),
          const SizedBox(height: 4),
        ],
        if (chips.isEmpty)
          Text(
            '暂无可选集数',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          )
        else
          Wrap(spacing: 8, runSpacing: 8, children: chips),
      ],
    );
  }
}

typedef SyncPlayEpisodePicker = SyncPlayRoomEpisodePicker;
