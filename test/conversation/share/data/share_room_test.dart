import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/conversation/models/conversation_turn.dart';
import 'package:mozhi/conversation/share/data/share_room.dart';
import 'package:mozhi/conversation/share/data/share_secrets.dart';
import 'package:mozhi/conversation/share/data/share_translations.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../helpers.dart';

class MockShareTranslations extends Mock implements ShareTranslations;

void main() {
  setUpAll(() {
    registerConversationFallbacks();
    registerFallbackValue(<ConversationTurn>[]);
    registerFallbackValue(<Language>[]);
    registerFallbackValue(turnOf());
  });

  late MockShareTranslations translations;
  late StreamController<void> translationChanges;
  late List<(ShareGuest, String)> replies;
  late FakeTimers timers;
  late DateTime now;
  late ShareRoom room;

  ShareRoom roomWith({String? pin, int maxGuests = 8}) => ShareRoom(
    token: 'token',
    languages: const [english, spanish, french],
    translations: translations,
    onReply: (guest, text) => replies.add((guest, text)),
    pin: pin,
    maxGuests: maxGuests,
    secrets: ShareSecrets(Random(7)),
    clock: () => now,
    timer: timers.call,
  );

  ShareGuest joinAs(ShareRoom room, String language) =>
      (room.join(languageCode: language, pin: room.pin) as ShareJoined).guest;

  setUp(() {
    translations = MockShareTranslations();
    translationChanges = StreamController<void>.broadcast();
    when(() => translations.changes)
        .thenAnswer((_) => translationChanges.stream);
    when(() => translations.ensure(any(), any())).thenReturn(null);
    when(translations.dispose).thenAnswer((_) async {});
    when(() => translations.textOf(any(), any())).thenAnswer((invocation) {
      final turn = invocation.positionalArguments[0] as ConversationTurn;
      final language = invocation.positionalArguments[1] as Language;
      return ShareTranslations.sameLanguage(language, turn.source)
          ? (text: turn.original, status: ShareTextStatus.original)
          : (
              text: '${turn.original} (${language.code})',
              status: ShareTextStatus.translated,
            );
    });
    when(() => translations.languageStates(any())).thenReturn(const []);
    replies = [];
    timers = FakeTimers();
    now = DateTime.utc(2026, 10, 22, 12);
    room = roomWith();
  });

  tearDown(() async {
    await room.end();
    await translationChanges.close();
  });

  group('join', () {
    test('adds guests with numbers, ids and keys', () {
      final first = room.join(languageCode: 'fr') as ShareJoined;
      final second = room.join(languageCode: ' ES ') as ShareJoined;

      expect(first.guest.number, 1);
      expect(first.guest.language, french);
      expect(first.guest.joinedAt, now);
      expect(first.guest.connected, isFalse);
      expect(second.guest.number, 2);
      expect(second.guest.language, spanish);
      expect(first.key, isNot(second.key));
      expect(room.guests, [first.guest, second.guest]);
      expect(room.guestLanguages, [french, spanish]);
      verify(() => translations.ensure(any(), [french, spanish])).called(1);
    });

    test('refuses languages the host does not offer', () {
      expect(
        (room.join(languageCode: 'de') as ShareJoinRefused).error,
        ShareJoinError.unknownLanguage,
      );
    });

    test('checks the PIN and locks after too many wrong ones', () async {
      await room.end();
      room = roomWith(pin: '1234');
      final changes = <void>[];
      room.changes.listen(changes.add);

      expect(
        (room.join(languageCode: 'fr') as ShareJoinRefused).error,
        ShareJoinError.wrongPin,
      );
      expect(room.join(languageCode: 'fr', pin: ' 1234 '), isA<ShareJoined>());
      for (var i = 1; i < ShareRoom.maxWrongPins - 1; i++) {
        expect(
          (room.join(
            languageCode: 'fr',
            pin: '0000',
          ) as ShareJoinRefused).error,
          ShareJoinError.wrongPin,
        );
      }
      expect(
        (room.join(languageCode: 'fr', pin: '0000') as ShareJoinRefused).error,
        ShareJoinError.locked,
      );
      expect(room.locked, isTrue);
      expect(
        (room.join(languageCode: 'fr', pin: '1234') as ShareJoinRefused).error,
        ShareJoinError.locked,
      );

      // A new PIN lifts it.
      room.pin = '9876';
      expect(room.locked, isFalse);
      expect(room.join(languageCode: 'fr', pin: '9876'), isA<ShareJoined>());
      await settle();
      expect(changes, isNotEmpty);
    });

    test('refuses guests beyond the limit', () async {
      await room.end();
      room = roomWith(maxGuests: 2);
      joinAs(room, 'fr');
      joinAs(room, 'fr');

      expect(
        (room.join(languageCode: 'fr') as ShareJoinRefused).error,
        ShareJoinError.full,
      );
    });

    test('refuses everyone once ended', () async {
      await room.end();

      expect(
        (room.join(languageCode: 'fr') as ShareJoinRefused).error,
        ShareJoinError.ended,
      );
      expect(room.ended, isTrue);
    });
  });

  group('authenticate', () {
    test('needs the guest key', () {
      final joined = room.join(languageCode: 'fr') as ShareJoined;

      expect(room.authenticate(joined.guest.id, joined.key), joined.guest);
      expect(room.authenticate(joined.guest.id, 'wrong'), isNull);
      expect(room.authenticate('nobody', joined.key), isNull);
      expect(room.authenticate(null, joined.key), isNull);
      expect(room.authenticate(joined.guest.id, null), isNull);
    });
  });

  group('setLanguage', () {
    test('changes the guest language within limits', () {
      final guest = joinAs(room, 'fr');

      expect(room.setLanguage(guest, 'de'), isFalse);
      expect(room.setLanguage(guest, 'es'), isTrue);
      expect(room.guests.single.language, spanish);
      for (var i = 1; i < 10; i++) {
        room.setLanguage(guest, i.isEven ? 'es' : 'fr');
      }
      expect(room.setLanguage(guest, 'en'), isFalse);
    });
  });

  group('reply', () {
    test('hands replies to the host', () {
      final guest = joinAs(room, 'fr');

      expect(room.reply(guest, '  Bonjour  '), ShareReplyResult.sent);
      expect(replies.single.$1, guest);
      expect(replies.single.$2, 'Bonjour');
    });

    test('refuses blank, long and fast replies', () {
      final guest = joinAs(room, 'fr');

      expect(room.reply(guest, '  '), ShareReplyResult.empty);
      expect(
        room.reply(guest, 'a' * (ShareRoom.maxReplyLength + 1)),
        ShareReplyResult.tooLong,
      );
      expect(
        room.reply(guest, '😀' * ShareRoom.maxReplyLength),
        ShareReplyResult.sent,
      );
      expect(room.reply(guest, 'again'), ShareReplyResult.tooFast);
      now = now.add(ShareRoom.replyInterval);
      expect(room.reply(guest, 'again'), ShareReplyResult.sent);
      for (var i = 2; i < ShareRoom.maxRepliesPerMinute; i++) {
        now = now.add(ShareRoom.replyInterval);
        expect(room.reply(guest, '$i'), ShareReplyResult.sent);
      }
      now = now.add(ShareRoom.replyInterval);
      expect(room.reply(guest, 'more'), ShareReplyResult.tooFast);
    });

    test('refuses replies when turned off, and from gone guests', () async {
      final guest = joinAs(room, 'fr');
      room
        ..repliesAllowed = false
        ..repliesAllowed = false;

      expect(room.reply(guest, 'Bonjour'), ShareReplyResult.disabled);
      room.leave(guest);
      expect(room.reply(guest, 'Bonjour'), ShareReplyResult.ended);
      expect(replies, isEmpty);
    });
  });

  group('presence', () {
    test('removes guests whose page stays away', () {
      final guest = joinAs(room, 'fr');
      expect(timers.pending(ShareRoom.absenceGrace), isTrue);

      room.connected(guest);
      expect(room.guests.single.connected, isTrue);
      expect(timers.pending(ShareRoom.absenceGrace), isFalse);

      room
        ..connected(guest)
        ..disconnected(guest);
      expect(room.guests.single.connected, isTrue);

      room.disconnected(guest);
      expect(room.guests.single.connected, isFalse);
      timers.fire(ShareRoom.absenceGrace);
      expect(room.guests, isEmpty);
    });

    test('keeps a guest who comes back in time', () {
      final guest = joinAs(room, 'fr');
      room
        ..connected(guest)
        ..disconnected(guest)
        ..connected(guest);

      timers.fire(ShareRoom.absenceGrace);
      expect(room.guests, hasLength(1));
    });

    test('removes a guest who never connects', () {
      joinAs(room, 'fr');

      timers.fire(ShareRoom.absenceGrace);
      expect(room.guests, isEmpty);
    });

    test('ignores unknown guests', () {
      final guest = joinAs(room, 'fr');
      room
        ..leave(guest)
        ..leave(guest)
        ..connected(guest)
        ..disconnected(guest);

      expect(room.guests, isEmpty);
      expect(room.setLanguage(guest, 'es'), isFalse);
    });
  });

  group('snapshotFor', () {
    ConversationTurn turn(
      int id, {
      ConversationSide side = ConversationSide.a,
      int? guest,
      Language source = english,
    }) => ConversationTurn(
      id: id,
      side: side,
      original: 'Said $id',
      source: source,
      target: spanish,
      createdAt: now,
      guest: guest,
    );

    test('shows the turns in the guest language', () {
      final guest = joinAs(room, 'fr');
      final other = joinAs(room, 'es');
      room.update([
        turn(0),
        turn(1, side: ConversationSide.b, source: spanish),
        turn(2, side: ConversationSide.b, guest: guest.number, source: french),
        turn(3, side: ConversationSide.b, guest: other.number, source: spanish),
      ]);

      final snapshot = room.snapshotFor(guest);
      expect(snapshot['language'], 'fr');
      expect(snapshot['repliesAllowed'], isTrue);
      expect(snapshot['revision'], room.revision);
      final turns = (snapshot['turns']! as List).cast<Map<String, Object?>>();
      expect(
        [for (final t in turns) t['who']],
        ['host', 'partner', 'you', 'guest'],
      );
      expect(turns[0], {
        'id': 0,
        'who': 'host',
        'language': 'English',
        'text': 'Said 0 (fr)',
        'original': 'Said 0',
        'state': 'translated',
        'time': '2026-10-22T12:00:00.000Z',
      });
      expect(turns[1]['language'], 'Español');
      expect(turns[2]['state'], 'original');
      expect(turns[2]['guest'], guest.number);
      expect(turns[3]['guest'], other.number);
      verify(() => translations.ensure(any(), any())).called(greaterThan(0));
    });

    test('sends the last turns only', () {
      final guest = joinAs(room, 'fr');
      room.update([for (var i = 0; i < ShareRoom.maxTurns + 5; i++) turn(i)]);

      final turns = room.snapshotFor(guest)['turns']! as List;
      expect(turns, hasLength(ShareRoom.maxTurns));
      expect((turns.first as Map)['id'], 5);
    });
  });

  test('compares guests by value', () {
    final guest = ShareGuest(
      id: 'a',
      number: 1,
      language: french,
      joinedAt: now,
    );

    expect(guest.copyWith(), guest);
    expect(guest.copyWith(connected: true), isNot(guest));
    expect(guest.copyWith(language: spanish).language, spanish);
  });

  test(
    'makes its own secrets and names languages without a native name',
    () async {
      final plain = ShareRoom(
        token: 'token',
        languages: const [Language(code: 'it', name: 'Italian')],
        translations: translations,
        onReply: (_, _) {},
      );
      addTearDown(plain.end);
      final guest = (plain.join(languageCode: 'it') as ShareJoined).guest;
      plain.update([
        ConversationTurn(
          id: 0,
          side: ConversationSide.a,
          original: 'Ciao',
          source: const Language(code: 'it', name: 'Italian'),
          target: english,
          createdAt: now,
        ),
      ]);

      expect(guest.id, matches(RegExp(r'^[0-9a-f]{16}$')));
      final turns = plain.snapshotFor(guest)['turns']! as List;
      expect((turns.single as Map)['language'], 'Italian');
    },
  );

  test('lists the languages with their native names', () {
    expect(room.languageList(), [
      {'code': 'en', 'name': 'English'},
      {'code': 'es', 'name': 'Spanish', 'nativeName': 'Español'},
      {'code': 'fr', 'name': 'French', 'nativeName': 'Français'},
    ]);
    expect(room.languageOf('FR'), french);
    expect(room.languageOf('de'), isNull);
  });

  test('passes on translation changes, consent retries and states', () async {
    final changes = <void>[];
    room.changes.listen(changes.add);
    final revision = room.revision;

    translationChanges.add(null);
    await settle();
    room
      ..retryLanguage(french)
      ..languageStates();

    expect(changes, hasLength(1));
    expect(room.revision, revision + 1);
    verify(() => translations.retry(french)).called(1);
    verify(() => translations.languageStates(any())).called(1);
  });

  test('ends once, disposing the translations', () async {
    joinAs(room, 'fr');
    var done = false;
    room.changes.listen((_) {}, onDone: () => done = true);

    await room.end();
    await room.end();
    room.update([]);

    expect(done, isTrue);
    verify(translations.dispose).called(1);
    expect(room.authenticate('x', 'y'), isNull);
  });
}
