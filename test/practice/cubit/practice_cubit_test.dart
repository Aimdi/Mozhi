import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/phrasebook/data/phrasebook_repository.dart';
import 'package:mozhi/practice/cubit/practice_cubit.dart';
import 'package:mozhi/practice/data/fsrs.dart';
import 'package:mozhi/practice/data/practice_repository.dart';
import 'package:mozhi/practice/models/practice_card.dart';
import 'package:mozhi/practice/models/practice_item.dart';
import 'package:mozhi/practice/models/practice_settings.dart';

import '../helpers.dart';

class _MockPractice extends Mock implements PracticeRepository;

class _MockPhrasebook extends Mock implements PhrasebookRepository;

PracticeCubit _cubit(
  PracticeFixture fixture, {
  String? onlyCollection,
  int sessionLimit = 50,
}) => PracticeCubit(
  repository: fixture.practice,
  appLanguage: 'en',
  onlyCollection: onlyCollection,
  sessionLimit: sessionLimit,
  clock: fixture.clock.call,
  scheduler: (settings) =>
      FsrsScheduler(fuzz: false, desiredRetention: settings.desiredRetention),
);

void main() {
  group(PracticeCubit, () {
    test('loads the deck', () async {
      final fixture = PracticeFixture(favorites: [favorite('1')]);
      final cubit = _cubit(fixture);
      await cubit.load();
      expect(cubit.state.status, PracticeStatus.ready);
      expect(cubit.state.deck!.items, hasLength(2));
      expect(cubit.state.current, isNull);
      await cubit.close();
    });

    test('a session: reveal, rate, the learning card comes back', () async {
      final fixture = PracticeFixture(
        favorites: [favorite('1'), favorite('2')],
      );
      final cubit = _cubit(fixture);
      await cubit.load();
      await cubit.start();
      expect(cubit.state.status, PracticeStatus.reviewing);
      // One new card per phrase, oldest first (both at the same time:
      // favourites newest first).
      expect(cubit.state.queue, hasLength(2));
      final first = cubit.state.current!;
      expect(first.direction, CardDirection.recognize);
      expect(cubit.state.revealed, isFalse);
      expect(cubit.state.intervals, {
        FsrsRating.again: const Duration(minutes: 1),
        FsrsRating.hard: const Duration(seconds: 330),
        FsrsRating.good: const Duration(minutes: 10),
        FsrsRating.easy: const Duration(days: 16),
      });
      cubit
        ..reveal()
        ..reveal();
      expect(cubit.state.revealed, isTrue);

      await cubit.rate(FsrsRating.good);
      expect(cubit.state.canUndo, isTrue);
      expect(cubit.state.revealed, isFalse);
      // The other card, then the first again (due in 10 minutes).
      expect(cubit.state.queue.map((item) => item.id), [
        cubit.state.queue.first.id,
        first.id,
      ]);
      expect(cubit.state.queue.last.card.fsrs.state, FsrsState.learning);
      expect(cubit.state.stats.reviewed, 1);
      expect(cubit.state.stats.newCards, 1);
      final stored = await fixture.practice.cards();
      expect(stored[first.id]!.reps, 1);

      // Easy graduates the second card: it leaves the session.
      await cubit.rate(FsrsRating.easy);
      expect(cubit.state.queue.single.id, first.id);
      // Good on the last step graduates the first.
      await cubit.rate(FsrsRating.good);
      expect(cubit.state.status, PracticeStatus.finished);
      expect(cubit.state.stats.reviewed, 3);
      expect(cubit.state.stats.remembered, 3);
      expect(cubit.state.stats.ratings, {
        FsrsRating.good: 2,
        FsrsRating.easy: 1,
      });
      expect(cubit.state.deck!.nextDue(fixture.clock.now), isNotNull);
      await cubit.close();
    });

    test('undo puts the card back as it was', () async {
      final fixture = PracticeFixture(favorites: [favorite('1')]);
      final cubit = _cubit(fixture);
      await cubit.load();
      await cubit.start();
      final first = cubit.state.current!;
      await cubit.rate(FsrsRating.again);
      expect(cubit.state.current!.card.fsrs.state, FsrsState.learning);
      await cubit.undo();
      expect(cubit.state.current, first);
      expect(cubit.state.canUndo, isFalse);
      expect(cubit.state.stats.reviewed, 0);
      // A first review undone: the card is new again.
      expect(await fixture.practice.cards(), isEmpty);
      await cubit.undo();

      // Undoing a later review stores the earlier state.
      await cubit.rate(FsrsRating.good);
      fixture.clock.advance(const Duration(minutes: 10));
      await cubit.rate(FsrsRating.good);
      expect(cubit.state.status, PracticeStatus.finished);
      await cubit.undo();
      expect(cubit.state.status, PracticeStatus.reviewing);
      final stored = (await fixture.practice.cards())[first.id]!;
      expect(stored.reps, 1);
      expect(stored.fsrs.state, FsrsState.learning);
      expect(stored.updatedAt, fixture.clock.now.toUtc());
      await cubit.close();
    });

    test('orders learning cards, reviews, then new ones', () async {
      final fixture = PracticeFixture();
      await fixture.collection('Trip', ['a', 'b', 'c', 'd']);
      final cubit = _cubit(fixture);
      await cubit.load();
      final items = cubit.state.deck!.items;
      final scheduler = FsrsScheduler(fuzz: false);
      PracticeCard review(PracticeCard card, FsrsRating rating) {
        final now = fixture.clock.now;
        return card.reviewed(
          rating,
          scheduler.review(card.fsrs, rating, now),
          now,
        );
      }

      PracticeItem recognize(String text) => items.firstWhere(
        (i) => i.phrase.text == text && i.direction == CardDirection.recognize,
      );
      // c and a: in review (Easy: 16 days, c a day earlier); b and d:
      // learning (Good: 10 minutes, d a day earlier).
      await fixture.practice.saveCard(
        review(recognize('c').card, FsrsRating.easy),
      );
      await fixture.practice.saveCard(
        review(recognize('d').card, FsrsRating.good),
      );
      fixture.clock.advance(const Duration(days: 1));
      await fixture.practice.saveCard(
        review(recognize('a').card, FsrsRating.easy),
      );
      await fixture.practice.saveCard(
        review(recognize('b').card, FsrsRating.good),
      );
      fixture.clock.advance(const Duration(days: 20));
      await cubit.start();
      expect(
        [
          for (final item in cubit.state.queue)
            '${item.phrase.text}/${item.direction.key}',
        ],
        // The produce cards are new, but their phrases are asked already.
        ['d/r', 'b/r', 'c/r', 'a/r'],
      );
      await cubit.close();
    });

    test('limits a session, learning cards always included', () async {
      final fixture = PracticeFixture();
      await fixture.collection('Trip', ['a', 'b', 'c']);
      final cubit = _cubit(fixture, sessionLimit: 2);
      await cubit.load();
      await cubit.start();
      expect(cubit.state.queue, hasLength(2));
      await cubit.close();
    });

    test('with nothing due the session is over at once', () async {
      final fixture = PracticeFixture(favorites: [favorite('1')]);
      await fixture.practice.saveSettings(
        const PracticeSettings(newCardsPerDay: 0),
      );
      final cubit = _cubit(fixture);
      await cubit.load();
      await cubit.start();
      expect(cubit.state.status, PracticeStatus.finished);
      await cubit.backToOverview();
      expect(cubit.state.status, PracticeStatus.ready);
      await cubit.close();
    });

    test('checks a typed answer and shows the answer', () async {
      final fixture = PracticeFixture(favorites: [favorite('1')]);
      await fixture.practice.saveSettings(
        const PracticeSettings(directions: {CardDirection.produce}),
      );
      final cubit = _cubit(fixture);
      await cubit.load();
      cubit.checkTypedAnswer('ignored');
      expect(cubit.state.typedCheck, isNull);
      await cubit.start();
      cubit.checkTypedAnswer('Tradução 1');
      expect(cubit.state.revealed, isTrue);
      expect(cubit.state.typedCheck!.isExact, isTrue);
      expect(cubit.state.typedCheck!.suggestedRating, FsrsRating.good);
      await cubit.rate(FsrsRating.good);
      expect(cubit.state.typedCheck, isNull);
      await cubit.close();
    });

    test('finish ends a session early', () async {
      final fixture = PracticeFixture(favorites: [favorite('1')]);
      final cubit = _cubit(fixture);
      await cubit.load();
      cubit.finish();
      expect(cubit.state.status, PracticeStatus.ready);
      await cubit.start();
      cubit.finish();
      expect(cubit.state.status, PracticeStatus.finished);
      expect(cubit.state.canUndo, isFalse);
      // Nothing to rate or reveal outside a session.
      cubit.reveal();
      await cubit.rate(FsrsRating.good);
      expect(cubit.state.stats.reviewed, 0);
      // Keep going from the summary.
      await cubit.start();
      expect(cubit.state.status, PracticeStatus.reviewing);
      await cubit.close();
    });

    test('updates the settings and the deck', () async {
      final fixture = PracticeFixture(favorites: [favorite('1')]);
      final cubit = _cubit(fixture);
      await cubit.load();
      await cubit.updateSettings(
        const PracticeSettings(directions: {CardDirection.recognize}),
      );
      expect(cubit.state.deck!.items, hasLength(1));
      expect((await fixture.practice.settings()).directions, {
        CardDirection.recognize,
      });
      await cubit.close();
    });

    test('follows the phrasebook while the overview shows', () async {
      final fixture = PracticeFixture(favorites: [favorite('1')]);
      final cubit = _cubit(fixture);
      await cubit.load();
      fixture.favorites.set([favorite('1'), favorite('2')]);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(cubit.state.deck!.items, hasLength(4));
      await cubit.close();
    });

    test('practises one collection', () async {
      final fixture = PracticeFixture(favorites: [favorite('1')]);
      final trip = await fixture.collection('Trip', ['a']);
      final cubit = _cubit(fixture, onlyCollection: trip.id);
      await cubit.load();
      expect(cubit.state.deck!.items.map((item) => item.phrase.text).toSet(), {
        'a',
      });
      await cubit.close();
    });

    test('an unreadable progress can be started over', () async {
      final fixture = PracticeFixture(favorites: [favorite('1')]);
      await fixture.practice.saveSettings(const PracticeSettings());
      fixture.keyStore.values.remove(PracticeRepository.keyStorageKey);
      fixture.practice = fixture.newPractice();
      final cubit = _cubit(fixture);
      await cubit.load();
      expect(cubit.state.status, PracticeStatus.unreadable);
      await cubit.startOver();
      expect(cubit.state.status, PracticeStatus.ready);
      await cubit.close();
    });

    group('with failing storage', () {
      late _MockPractice practice;
      late _MockPhrasebook phrasebook;

      setUp(() {
        practice = _MockPractice();
        phrasebook = _MockPhrasebook();
        when(() => practice.phrasebook).thenReturn(phrasebook);
        when(() => phrasebook.changes).thenAnswer((_) => const Stream.empty());
      });

      blocTest<PracticeCubit, PracticeState>(
        'reports a failed load',
        build: () => PracticeCubit(repository: practice, appLanguage: 'en'),
        setUp: () =>
            when(() => practice.settings()).thenThrow(StateError('broken')),
        act: (cubit) => cubit.load(),
        expect: () => [
          const PracticeState(),
          const PracticeState(status: PracticeStatus.failure),
        ],
        errors: () => [isA<StateError>()],
      );

      test('a failed save is said once and the session goes on', () async {
        final fixture = PracticeFixture(favorites: [favorite('1')]);
        final deck = await fixture.practice.deck(appLanguage: 'en');
        when(() => practice.settings())
            .thenAnswer((_) async => const PracticeSettings());
        when(
          () => practice.deck(
            appLanguage: any(named: 'appLanguage'),
            settings: any(named: 'settings'),
            onlyCollection: any(named: 'onlyCollection'),
          ),
        ).thenAnswer((_) async => deck);
        when(() => practice.saveCard(any())).thenThrow(StateError('full'));
        when(() => practice.saveSettings(any())).thenThrow(StateError('full'));
        when(() => practice.discardUnreadable()).thenThrow(StateError('no'));
        final errors = <Object>[];
        final cubit = PracticeCubit(repository: practice, appLanguage: 'en');
        cubit.stream.listen((_) {}, onError: errors.add);
        await cubit.load();
        await cubit.updateSettings(const PracticeSettings(newCardsPerDay: 1));
        await cubit.startOver();
        await cubit.start();
        await cubit.rate(FsrsRating.good);
        expect(cubit.state.saveFailed, isTrue);
        expect(cubit.state.stats.reviewed, 1);
        await cubit.close();
      });
    });
  });

  group(PracticeStats, () {
    test('counts reviews', () {
      final stats = const PracticeStats()
          .add(FsrsRating.again, wasNew: true)
          .add(FsrsRating.good, wasNew: false);
      expect(stats.reviewed, 2);
      expect(stats.remembered, 1);
      expect(stats.newCards, 1);
    });
  });

  setUpAll(() {
    registerFallbackValue(
      PracticeCard.fresh('p', CardDirection.recognize, DateTime(2026)),
    );
    registerFallbackValue(const PracticeSettings());
  });
}
