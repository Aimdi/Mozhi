import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/history/data/history_cipher.dart';
import 'package:mozhi/phrasebook/data/phrasebook_repository.dart';
import 'package:mozhi/practice/data/fsrs.dart';
import 'package:mozhi/practice/data/practice_repository.dart';
import 'package:mozhi/practice/models/practice_card.dart';
import 'package:mozhi/practice/models/practice_settings.dart';

import '../helpers.dart';

/// [card] reviewed Good at [now] (learning, due in 10 minutes).
PracticeCard _reviewed(PracticeCard card, DateTime now) {
  final next = FsrsScheduler(fuzz: false)
      .review(card.fsrs, FsrsRating.good, now);
  return card.reviewed(FsrsRating.good, next, now);
}

/// A key store whose writes are lost.
class _ForgetfulStore implements KeyValueStore {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}
}

void main() {
  group(PracticeRepository, () {
    test('makes a card per phrase and direction of every collection', () async {
      final fixture = PracticeFixture(favorites: [favorite('1')]);
      final trip = await fixture.collection('Trip', ['Hello', 'Thanks']);
      final deck = await fixture.practice.deck(appLanguage: 'en');
      expect(deck.collections.map((c) => c.id), [
        PhraseCollection.favoritesId,
        trip.id,
      ]);
      expect(deck.collectionSizes, {
        PhraseCollection.favoritesId: 1,
        trip.id: 2,
      });
      expect(deck.items, hasLength(6));
      expect(deck.items.every((item) => item.card.isNew), isTrue);
      expect(deck.userLanguage, 'en');
      final hello = deck.items.firstWhere(
        (item) =>
            item.phrase.text == 'Hello' &&
            item.direction == CardDirection.recognize,
      );
      expect(hello.foreignIsSource, isFalse);
      expect(hello.frontText, 'Hello (pt)');
      expect(hello.frontCode, 'pt');
      expect(hello.backText, 'Hello');
      expect(deck.due(fixture.clock.now), isEmpty);
      // One new card per phrase, oldest first, recognise first.
      expect(
        [
          for (final item in deck.newCards())
            '${item.phrase.text}/${item.direction.name}',
        ],
        ['text 1/recognize', 'Hello/recognize', 'Thanks/recognize'],
      );
      expect(deck.newAllowance, PracticeSettings.defaultNewCardsPerDay);
      expect(deck.nextDue(fixture.clock.now), isNull);
    });

    test('practises the chosen collections and directions', () async {
      final fixture = PracticeFixture(favorites: [favorite('1')]);
      final trip = await fixture.collection('Trip', ['Hello']);
      await fixture.practice.saveSettings(
        PracticeSettings(
          collectionIds: {trip.id},
          directions: const {CardDirection.produce},
        ),
      );
      final deck = await fixture.practice.deck(appLanguage: 'en');
      expect(deck.items.map((item) => item.id), [
        '${deck.items.single.phrase.id}#p',
      ]);
      // Every collection is listed for the picker.
      expect(deck.collections, hasLength(2));
      final only = await fixture.practice.deck(
        appLanguage: 'en',
        onlyCollection: PhraseCollection.favoritesId,
      );
      expect(only.items.single.phrase.id, 'h:1');
    });

    test('stores reviewed cards encrypted and reads them back', () async {
      final fixture = PracticeFixture(favorites: [favorite('1')]);
      final deck = await fixture.practice.deck(appLanguage: 'en');
      final now = fixture.clock.now;
      final card = _reviewed(deck.items.first.card, now);
      await fixture.practice.saveCard(card);

      final stored = fixture.store.values[PracticeRepository.storageKey]!;
      expect(stored, startsWith(HistoryCipher.prefix));
      expect(stored, isNot(contains('h:1')));
      expect(
        fixture.keyStore.values[PracticeRepository.keyStorageKey],
        isNotNull,
      );
      // Not readable as another kind of value with the same key.
      final key = base64Decode(
        fixture.keyStore.values[PracticeRepository.keyStorageKey]!,
      );
      await expectLater(
        const HistoryCipher().decrypt(stored, key),
        throwsA(isA<HistoryCipherException>()),
      );

      final restarted = fixture.newPractice();
      expect(await restarted.cards(), {card.id: card});
      expect(await restarted.reviewedCount(), 1);
      final again = await restarted.deck(appLanguage: 'en');
      expect(again.items.first.card, card);
      expect(again.introducedToday, 1);
      expect(again.newAllowance, PracticeSettings.defaultNewCardsPerDay - 1);
    });

    test('counts the learned cards due', () async {
      final fixture = PracticeFixture(
        favorites: [favorite('1'), favorite('2')],
      );
      final deck = await fixture.practice.deck(appLanguage: 'en');
      final now = fixture.clock.now;
      await fixture.practice.saveCard(_reviewed(deck.items[0].card, now));
      await fixture.practice.saveCard(_reviewed(deck.items[2].card, now));
      expect(await fixture.practice.refreshDueCount(), 0);
      expect(
        (await fixture.practice.deck(appLanguage: 'en')).nextDue(now),
        now.add(const Duration(minutes: 10)).toUtc(),
      );
      fixture.clock.advance(const Duration(minutes: 10));
      expect(await fixture.practice.refreshDueCount(), 2);
      expect(fixture.practice.dueCount.value, 2);
      final later = await fixture.practice.deck(appLanguage: 'en');
      expect(later.due(fixture.clock.now), hasLength(2));
      // Only the practised directions count.
      await fixture.practice.saveSettings(
        const PracticeSettings(directions: {CardDirection.produce}),
      );
      expect(await fixture.practice.refreshDueCount(), 0);
    });

    test('a new card saved again forgets the progress', () async {
      final fixture = PracticeFixture(favorites: [favorite('1')]);
      final card = (await fixture.practice.deck(appLanguage: 'en'))
          .items
          .first
          .card;
      await fixture.practice.saveCard(_reviewed(card, fixture.clock.now));
      await fixture.practice.saveCard(card);
      expect(await fixture.practice.cards(), isEmpty);
    });

    test('recounts when the phrasebook changes', () async {
      final fixture = PracticeFixture(favorites: [favorite('1')]);
      final card = (await fixture.practice.deck(appLanguage: 'en'))
          .items
          .first
          .card;
      await fixture.practice.saveCard(_reviewed(card, fixture.clock.now));
      fixture.clock.advance(const Duration(hours: 1));
      expect(fixture.practice.dueCount.value, 0);
      fixture.favorites.set([favorite('1'), favorite('2')]);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(fixture.practice.dueCount.value, 1);
    });

    test('removes the cards of deleted phrases, with a tombstone', () async {
      final fixture = PracticeFixture();
      final trip = await fixture.collection('Trip', ['Hello', 'Thanks']);
      final deck = await fixture.practice.deck(appLanguage: 'en');
      final now = fixture.clock.now;
      for (final item in deck.items) {
        await fixture.practice.saveCard(_reviewed(item.card, now));
      }
      final hello = deck.items.first.phrase;
      await fixture.phrasebook.removePhrase(hello.id, trip.id);
      final next = await fixture.practice.deck(appLanguage: 'en');
      expect(next.items.map((item) => item.phrase.text).toSet(), {'Thanks'});
      final cards = await fixture.practice.cards();
      expect(cards.keys.toSet(), {for (final item in next.items) item.card.id});
      final backup = await fixture.practice.exportBackup();
      expect((backup['tombstones']! as Map).keys.toSet(), {
        '${hello.id}#r',
        '${hello.id}#p',
      });
    });

    test('keeps favourite cards while no favourite is listed', () async {
      final fixture = PracticeFixture(
        favorites: [favorite('1'), favorite('2')],
      );
      final deck = await fixture.practice.deck(appLanguage: 'en');
      for (final item in deck.items) {
        await fixture.practice.saveCard(
          _reviewed(item.card, fixture.clock.now),
        );
      }
      // The history is locked (or loading): nothing listed.
      fixture.favorites.set([]);
      await fixture.practice.deck(appLanguage: 'en');
      expect(await fixture.practice.cards(), hasLength(4));
      // Un-starred while others are listed: gone.
      fixture.favorites.set([favorite('2')]);
      await fixture.practice.deck(appLanguage: 'en');
      expect((await fixture.practice.cards()).keys.toSet(), {'h:2#r', 'h:2#p'});
    });

    test(
      'keeps starter cards unless their installed pack lacks them',
      () async {
        final epoch = DateTime(2026);
        Phrase starter(String id) => Phrase(
          id: id,
          text: 'Hello',
          translation: 'Olá',
          sourceCode: 'en',
          targetCode: 'pt',
          createdAt: epoch,
          updatedAt: epoch,
          origin: PhraseOrigin.starter,
        );
        final phrasebook = _ListedPhrasebook(
          listed: [
            PhraseCollection(
              id: PhraseCollection.starterId('pt'),
              name: 'Portuguese',
              phraseIds: const ['s:pt:1'],
              createdAt: epoch,
              updatedAt: epoch,
              starter: true,
            ),
            PhraseCollection(
              id: PhraseCollection.starterId('es'),
              name: 'Spanish',
              phraseIds: const [],
              createdAt: epoch,
              updatedAt: epoch,
              starter: true,
            ),
          ],
          everything: [starter('s:pt:1')],
        );
        final fixture = PracticeFixture();
        final practice = PracticeRepository(
          phrasebook: phrasebook,
          store: fixture.store,
          keyStore: fixture.keyStore,
          clock: fixture.clock.call,
        );
        final now = fixture.clock.now;
        for (final id in ['s:pt:1', 's:pt:2', 's:de:1', 's:es:1']) {
          await practice.saveCard(
            _reviewed(
              PracticeCard.fresh(id, CardDirection.recognize, now),
              now,
            ),
          );
        }
        final deck = await practice.deck(appLanguage: 'en');
        expect(deck.items.single.phrase.id, 's:pt:1');
        expect((await practice.cards()).keys.toSet(), {
          's:pt:1#r',
          's:de:1#r',
          's:es:1#r',
        });
      },
    );

    test('takes the user language from the phrases', () async {
      final fixture = PracticeFixture();
      // A German speaker with the app in English, learning Portuguese.
      await fixture.collection('Lisbon', ['Hallo', 'Danke'], source: 'de');
      await fixture.phrasebook.addPhrase(
        const PhraseDraft(
          text: 'Saída',
          translation: 'Ausgang',
          sourceCode: 'pt',
          targetCode: 'de',
        ),
        (await fixture.phrasebook.collections())[1].id,
      );
      final deck = await fixture.practice.deck(appLanguage: 'en');
      expect(deck.userLanguage, 'de');
      final exit = deck.items.firstWhere((item) => item.phrase.text == 'Saída');
      expect(exit.foreignIsSource, isTrue);
      expect(exit.foreignText, 'Saída');
      expect(exit.nativeText, 'Ausgang');
    });

    test('stores the settings, stamped', () async {
      final fixture = PracticeFixture();
      await fixture.practice.saveSettings(
        const PracticeSettings(newCardsPerDay: 5, typeAnswers: true),
      );
      final settings = await fixture.newPractice().settings();
      expect(settings.newCardsPerDay, 5);
      expect(settings.typeAnswers, isTrue);
      expect(settings.updatedAt, fixture.clock.now.toUtc());
    });

    group('unreadable', () {
      test('without its key, refuses to read or write', () async {
        final fixture = PracticeFixture(favorites: [favorite('1')]);
        final card = (await fixture.practice.deck(appLanguage: 'en'))
            .items
            .first
            .card;
        await fixture.practice.saveCard(_reviewed(card, fixture.clock.now));
        fixture.keyStore.values.clear();
        final restarted = fixture.newPractice();
        await expectLater(
          restarted.settings(),
          throwsA(
            isA<PracticeUnreadableException>().having(
              (e) => e.keyMissing,
              'keyMissing',
              isTrue,
            ),
          ),
        );
        await expectLater(
          restarted.saveCard(card),
          throwsA(isA<PracticeUnreadableException>()),
        );
        expect(await restarted.refreshDueCount(), 0);
        expect(
          const PracticeUnreadableException(keyMissing: true).toString(),
          contains('key missing'),
        );
        expect(
          const PracticeUnreadableException(keyMissing: false).toString(),
          contains('bad key'),
        );

        await restarted.discardUnreadable();
        expect(await restarted.cards(), isEmpty);
        expect(
          fixture.store.values[PracticeRepository.unreadableStorageKey],
          isNotNull,
        );
        // A readable one is left alone.
        await restarted.discardUnreadable();
      });

      test('with a wrong key, says so', () async {
        final fixture = PracticeFixture(favorites: [favorite('1')]);
        await fixture.practice.saveSettings(const PracticeSettings());
        fixture.keyStore.values[PracticeRepository.keyStorageKey] =
            base64Encode(List.filled(32, 7));
        await expectLater(
          fixture.newPractice().settings(),
          throwsA(
            isA<PracticeUnreadableException>().having(
              (e) => e.keyMissing,
              'keyMissing',
              isFalse,
            ),
          ),
        );
      });

      test('an invalid stored key counts as missing', () async {
        final fixture = PracticeFixture();
        await fixture.practice.saveSettings(const PracticeSettings());
        fixture.keyStore.values[PracticeRepository.keyStorageKey] = 'nope!';
        await expectLater(
          fixture.newPractice().settings(),
          throwsA(isA<PracticeUnreadableException>()),
        );
      });
    });

    test('refuses to write when the key does not persist', () async {
      final fixture = PracticeFixture();
      final practice = PracticeRepository(
        phrasebook: fixture.phrasebook,
        store: fixture.store,
        keyStore: _ForgetfulStore(),
      );
      await expectLater(
        practice.saveSettings(const PracticeSettings()),
        throwsA(isA<PracticeKeyUnavailableException>()),
      );
      expect(
        const PracticeKeyUnavailableException().toString(),
        'PracticeKeyUnavailableException',
      );
    });

    test('deleteAll removes the progress, the copy and the key', () async {
      final fixture = PracticeFixture(favorites: [favorite('1')]);
      final card = (await fixture.practice.deck(appLanguage: 'en'))
          .items
          .first
          .card;
      await fixture.practice.saveCard(_reviewed(card, fixture.clock.now));
      fixture.store.values[PracticeRepository.unreadableStorageKey] = 'x';
      final changes = expectLater(fixture.practice.changes, emits(null));
      await fixture.practice.deleteAll();
      await changes;
      expect(
        fixture.store.values.keys,
        isNot(contains(startsWith('practice'))),
      );
      expect(fixture.keyStore.values, isNot(contains('practice.key')));
      expect(await fixture.practice.cards(), isEmpty);
      expect(fixture.practice.dueCount.value, 0);
    });

    test('a damaged document reads as empty', () async {
      final fixture = PracticeFixture();
      await fixture.practice.saveSettings(const PracticeSettings());
      final key = base64Decode(
        fixture.keyStore.values[PracticeRepository.keyStorageKey]!,
      );
      fixture.store.values[PracticeRepository.storageKey] =
          await const HistoryCipher().encrypt(
            'not json',
            key,
            aad: PracticeRepository.associatedData,
          );
      expect(await fixture.newPractice().cards(), isEmpty);
      fixture.store.values[PracticeRepository.storageKey] =
          await const HistoryCipher().encrypt(
            '[1]',
            key,
            aad: PracticeRepository.associatedData,
          );
      expect(await fixture.newPractice().cards(), isEmpty);
    });

    group('backup', () {
      Future<(PracticeFixture, PracticeCard)> withCard() async {
        final fixture = PracticeFixture(favorites: [favorite('1')]);
        final card = (await fixture.practice.deck(appLanguage: 'en'))
            .items
            .first
            .card;
        final reviewed = _reviewed(card, fixture.clock.now);
        await fixture.practice.saveCard(reviewed);
        return (fixture, reviewed);
      }

      test('exports and replaces', () async {
        final (fixture, card) = await withCard();
        final data = await fixture.practice.exportBackup();
        expect(data['version'], 1);
        expect(PracticeRepository.countBackupCards(data, version: 1), 1);
        expect(PracticeRepository.countBackupCards(data, version: 2), isNull);
        expect(PracticeRepository.countBackupCards('x', version: 1), isNull);

        final other = PracticeFixture();
        await other.practice.restoreBackup(
          jsonDecode(jsonEncode(data)),
          version: 1,
          merge: false,
        );
        expect(await other.practice.cards(), {card.id: card});
        await other.practice.restoreBackup(
          {'cards': <Object?>[]},
          version: 1,
          merge: false,
        );
        expect(await other.practice.cards(), isEmpty);
      });

      test(
        'merges: the newer card wins, tombstones delete older ones',
        () async {
          final (fixture, card) = await withCard();
          fixture.clock.advance(const Duration(minutes: 10));
          final newer = _reviewed(card, fixture.clock.now);
          final incoming = {
            'version': 1,
            'cards': [newer.toJson()],
            'settings': const PracticeSettings(newCardsPerDay: 3)
                .copyWith(updatedAt: fixture.clock.now.toUtc())
                .toJson(),
          };
          await fixture.practice.restoreBackup(
            incoming,
            version: 1,
            merge: true,
          );
          expect((await fixture.practice.cards())[card.id], newer);
          expect((await fixture.practice.settings()).newCardsPerDay, 3);

          // An older copy does not win.
          await fixture.practice.restoreBackup(
            {
              'cards': [card.toJson()],
            },
            version: 1,
            merge: true,
          );
          expect((await fixture.practice.cards())[card.id], newer);
          // Settings without a time do not win.
          expect((await fixture.practice.settings()).newCardsPerDay, 3);

          // A newer tombstone deletes it.
          final later = fixture.clock.now.add(const Duration(minutes: 1));
          await fixture.practice.restoreBackup(
            {
              'tombstones': {card.id: later.toUtc().toIso8601String(), 'x': 7},
            },
            version: 1,
            merge: true,
          );
          expect(await fixture.practice.cards(), isEmpty);

          // A card reviewed after the tombstone comes back.
          final revived = _reviewed(
            card,
            later.add(const Duration(minutes: 1)),
          );
          await fixture.practice.restoreBackup(
            {
              'cards': [
                revived.toJson(),
                'junk',
                {'phrase': ''},
              ],
            },
            version: 1,
            merge: true,
          );
          expect((await fixture.practice.cards())[card.id], revived);
          // A tombstone older than the local copy loses.
          await fixture.practice.restoreBackup(
            {
              'tombstones': {card.id: later.toUtc().toIso8601String()},
            },
            version: 1,
            merge: true,
          );
          expect((await fixture.practice.cards())[card.id], revived);
        },
      );

      test('refuses newer versions and other data', () async {
        final fixture = PracticeFixture();
        await expectLater(
          fixture.practice.restoreBackup({}, version: 2, merge: false),
          throwsFormatException,
        );
        await expectLater(
          fixture.practice.restoreBackup([], version: 1, merge: false),
          throwsFormatException,
        );
      });

      test('prunes old tombstones and keeps the newest', () async {
        final fixture = PracticeFixture();
        final practice = PracticeRepository(
          phrasebook: fixture.phrasebook,
          store: fixture.store,
          keyStore: fixture.keyStore,
          clock: fixture.clock.call,
          maxTombstones: 2,
          tombstoneMaxAge: const Duration(days: 10),
        );
        final now = fixture.clock.now.toUtc();
        String ago(int days) =>
            now.subtract(Duration(days: days)).toIso8601String();
        await practice.restoreBackup(
          {
            'tombstones': {'a': ago(1), 'b': ago(2), 'c': ago(3), 'd': ago(20)},
          },
          version: 1,
          merge: false,
        );
        final data = await practice.exportBackup();
        expect((data['tombstones']! as Map).keys.toSet(), {'a', 'b'});
      });
    });

    test('dispose stops listening', () async {
      final fixture = PracticeFixture();
      await fixture.practice.dispose();
      fixture.favorites.set([favorite('1')]);
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
  });
}

/// A phrasebook listing [listed] collections and [everything] (every
/// phrase).
class _ListedPhrasebook implements PhrasebookRepository {
  new({required this.listed, required this.everything});

  final List<PhraseCollection> listed;
  final List<Phrase> everything;

  @override
  Stream<void> get changes => const Stream.empty();

  @override
  Future<List<PhraseCollection>> collections() async => listed;

  @override
  Future<List<Phrase>> phrases({String? collectionId}) async => [
    for (final phrase in everything)
      if (collectionId == null ||
          listed
              .firstWhere((c) => c.id == collectionId)
              .phraseIds
              .contains(phrase.id))
        phrase,
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
