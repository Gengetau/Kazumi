import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/episode_item.dart';
import 'package:kazumi/pages/syncplay_room/media_picker/syncplay_room_media_picker_controller.dart';
import 'package:kazumi/pages/syncplay_room/media_picker/syncplay_room_media_selection.dart';

BangumiItem _bangumi(int id, String title) {
  return BangumiItem(
    id: id,
    type: 2,
    name: title,
    nameCn: title,
    summary: '',
    airDate: '',
    airWeekday: 0,
    rank: 0,
    images: const <String, String>{},
    tags: [],
    alias: [],
    ratingScore: 0,
    votes: 0,
    votesCount: [],
    info: '',
  );
}

EpisodeInfo _episode(int number) {
  return EpisodeInfo(
    id: number,
    episode: number,
    type: 0,
    name: 'Episode $number',
    nameCn: '第 $number 集',
  );
}

void main() {
  test('builds an id-and-episode selection after episode loading', () async {
    final bangumi = _bangumi(123, '测试番剧');
    final controller = SyncPlayRoomMediaPickerController(
      recommendationsLoader: () async => [bangumi, bangumi],
      episodesLoader: (_) async => [_episode(1), _episode(2)],
    );

    await controller.loadRecommendations();
    expect(controller.recommendations, [bangumi]);

    await controller.selectBangumi(bangumi);
    expect(controller.episodes, [1, 2]);
    expect(controller.setEpisode(3), isFalse);
    expect(controller.setEpisode(2), isTrue);

    final selection = controller.confirmSelection();
    expect(selection, isA<SyncPlayRoomMediaSelection>());
    expect(selection!.bangumi, same(bangumi));
    expect(selection.episode, 2);
    controller.dispose();
  });

  test('confirmation is null until a valid item is selected', () async {
    final controller = SyncPlayRoomMediaPickerController(
      episodesLoader: (_) async => [_episode(1)],
    );
    expect(controller.confirmSelection(), isNull);

    await controller.selectBangumi(_bangumi(456, '另一部番剧'));
    expect(controller.confirmSelection(), isNotNull);
    controller.dispose();
  });

  test('drops episode metadata from an older selection', () async {
    final firstGate = Completer<List<EpisodeInfo>>();
    final secondGate = Completer<List<EpisodeInfo>>();
    final first = _bangumi(1, '第一部');
    final second = _bangumi(2, '第二部');
    var calls = 0;
    final controller = SyncPlayRoomMediaPickerController(
      episodesLoader: (_) {
        calls++;
        return calls == 1 ? firstGate.future : secondGate.future;
      },
    );

    final firstSelection = controller.selectBangumi(first);
    await Future<void>.delayed(Duration.zero);
    final secondSelection = controller.selectBangumi(second);
    firstGate.complete([_episode(9)]);
    secondGate.complete([_episode(3)]);
    await Future.wait<void>([firstSelection, secondSelection]);

    expect(controller.selectedBangumi, same(second));
    expect(controller.episodes, [3]);
    expect(controller.selectedEpisode, 3);
    controller.dispose();
  });
}
