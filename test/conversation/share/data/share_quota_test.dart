import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/conversation/models/conversation_turn.dart';
import 'package:mozhi/conversation/share/data/share_room.dart';
import 'package:mozhi/conversation/share/data/share_translations.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../helpers.dart';

/// How much the host's engine works for guests (the security review's
/// probe: guests joining and leaving at once kept the host paying for
/// every turn in every language they had picked).
void main() {
  setUpAll(registerConversationFallbacks);

  const paid = TranslationEngine(
    id: 'ai:p1',
    kind: EngineKind.ai,
    name: 'Paid',
    providerId: 'p1',
  );
  final extra = [
    for (var i = 0; i < 30; i++) Language(code: 'x$i', name: 'L$i'),
  ];

  late MockTranslationRepository repository;
  late List<StreamController<TranslationResult>> running;
  late int calls;
  late DateTime now;
  late ShareRoom room;

  ConversationTurn turn(int id) => ConversationTurn(
    id: id,
    side: ConversationSide.a,
    original: 'turn $id',
    source: english,
    target: spanish,
    createdAt: sentAt,
    status: ConversationTurnStatus.complete,
    translation: 'turno $id',
  );

  /// Answers every translation that was started.
  Future<void> answerAll() async {
    while (running.isNotEmpty) {
      final controller = running.removeAt(0);
      if (controller.hasListener) {
        controller.add(resultOf('done', engine: paid));
      }
      await controller.close();
      await settle();
    }
  }

  setUp(() {
    repository = MockTranslationRepository();
    running = [];
    calls = 0;
    now = DateTime.utc(2026, 10, 22, 12);
    when(
      () => repository.needsConsent(
        any(),
        source: any(named: 'source'),
        target: any(named: 'target'),
      ),
    ).thenReturn(false);
    when(() => repository.translate(any(), any())).thenAnswer((_) {
      calls++;
      final controller = StreamController<TranslationResult>();
      running.add(controller);
      return controller.stream;
    });
    room = ShareRoom(
      token: 't',
      languages: [english, spanish, ...extra],
      translations: ShareTranslations(
        repository: repository,
        engine: () => paid,
        engines: () => const [paid],
      ),
      onReply: (_, _) {},
      conversationLanguages: () => const [english, spanish],
      clock: () => now,
    );
  });

  tearDown(() => room.end());

  test('guests who leave at once leave no work behind', () async {
    room.update([for (var i = 0; i < 40; i++) turn(i)]);
    var refused = 0;
    for (final language in extra) {
      switch (room.join(languageCode: language.code)) {
        case ShareJoined(:final guest):
          room.leave(guest);
        case ShareJoinRefused():
          refused++;
      }
    }
    final started = calls;
    await answerAll();
    await pumpEventQueue();

    expect(room.guests, isEmpty);
    // Before: 40 turns x 30 languages = 1,200 translations.
    expect(started, lessThanOrEqualTo(ShareRoom.defaultMaxExtraLanguages * 2));
    expect(calls, started);
    expect(refused, extra.length - ShareRoom.defaultMaxExtraLanguages);
    expect(room.languageStates(), isEmpty);
  });

  test('translates only the turns guests see', () async {
    room
      ..update([for (var i = 0; i < ShareRoom.maxTurns * 3; i++) turn(i)])
      ..join(languageCode: 'x0');
    await answerAll();

    expect(calls, ShareRoom.maxTurns);
  });

  test('switching languages back and forth translates nothing twice', () async {
    room.update([for (var i = 0; i < 10; i++) turn(i)]);
    final guest = (room.join(languageCode: 'x0') as ShareJoined).guest;
    await answerAll();
    expect(calls, 10);

    for (var i = 0; i < 4; i++) {
      room.setLanguage(guest, i.isEven ? 'x1' : 'x0');
      await answerAll();
    }

    expect(calls, 20);
  });

  test('a new language waits for a free place', () async {
    room.update([for (var i = 0; i < 10; i++) turn(i)]);
    for (var i = 0; i < ShareRoom.defaultMaxExtraLanguages; i++) {
      room.leave((room.join(languageCode: 'x$i') as ShareJoined).guest);
    }
    await answerAll();
    expect(room.join(languageCode: 'x9'), isA<ShareJoinRefused>());

    now = now.add(ShareRoom.languageKeep);
    expect(room.join(languageCode: 'x9'), isA<ShareJoined>());
  });
}
