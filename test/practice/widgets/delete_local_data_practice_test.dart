import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/practice/data/fsrs.dart';
import 'package:mozhi/practice/data/practice_repository.dart';
import 'package:mozhi/practice/models/practice_settings.dart';
import 'package:mozhi/settings/view/widgets/delete_local_data.dart';

import '../../settings/view/helpers.dart' as settings_helpers;
import '../helpers.dart';

void main() {
  setUpAll(settings_helpers.registerFallbacks);

  test('Delete all local data deletes the practice progress', () async {
    final fixture = PracticeFixture(favorites: [favorite('1')]);
    await fixture.practice.saveSettings(
      const PracticeSettings(newCardsPerDay: 3),
    );
    expect(fixture.store.values, contains(PracticeRepository.storageKey));
    final history = settings_helpers.createHistoryCubit();
    when(history.deleteAll).thenAnswer((_) async {});
    final eraser = LocalDataEraser(
      history: history,
      settings: settings_helpers.createSettingsCubit(),
      practice: fixture.practice,
    );
    await eraser.erase();
    expect(
      fixture.store.values,
      isNot(contains(PracticeRepository.storageKey)),
    );
    expect(
      fixture.keyStore.values,
      isNot(contains(PracticeRepository.keyStorageKey)),
    );
    expect(
      (await fixture.practice.settings()).newCardsPerDay,
      PracticeSettings.defaultNewCardsPerDay,
    );
  });

  test('the confirmation counts the cards with progress', () async {
    final fixture = PracticeFixture(favorites: [favorite('1')]);
    final eraser = LocalDataEraser(
      history: settings_helpers.createHistoryCubit(),
      settings: settings_helpers.createSettingsCubit(),
      practice: fixture.practice,
    );
    expect((await eraser.summarize()).practiceCards, 0);

    final card = (await fixture.practice.deck(appLanguage: 'en'))
        .items
        .first
        .card;
    final now = fixture.clock.now;
    await fixture.practice.saveCard(
      card.reviewed(
        FsrsRating.good,
        FsrsScheduler().review(card.fsrs, FsrsRating.good, now),
        now,
      ),
    );
    expect((await eraser.summarize()).practiceCards, 1);
  });
}
