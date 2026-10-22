import 'dart:async';
import 'dart:math';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/conversation/cubit/conversation_cubit.dart';
import 'package:mozhi/conversation/models/conversation_turn.dart';
import 'package:mozhi/conversation/share/cubit/conversation_share_cubit.dart';
import 'package:mozhi/conversation/share/data/share_room.dart';
import 'package:mozhi/conversation/share/data/share_secrets.dart';
import 'package:mozhi/conversation/share/data/share_server.dart';
import 'package:mozhi/transcribe/data/screen_awake.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../helpers.dart';

class MockConversationCubit extends MockCubit<ConversationState>
    implements ConversationCubit;

class MockScreenAwake extends Mock implements ScreenAwake;

class FakeShareServer implements ShareServer {
  new(this.room);

  final ShareRoom room;
  bool closed = false;

  @override
  Uri get url => Uri.parse('http://192.168.1.23:4242/s/${room.token}');

  @override
  Future<void> close() async => closed = true;
}

void main() {
  setUpAll(registerConversationFallbacks);

  late MockConversationCubit conversation;
  late StreamController<ConversationState> conversationStates;
  late MockTranslationRepository repository;
  late MockScreenAwake screenAwake;
  late FakeTimers timers;
  late DateTime now;
  late List<String> addresses;
  late List<FakeShareServer> servers;
  late List<String> boundTo;
  late Error? serverError;
  late Completer<void>? serverGate;
  late TranslationEngine? engine;

  ConversationState conversationState({
    List<ConversationTurn> turns = const [],
  }) => ConversationState(languageA: english, languageB: spanish, turns: turns);

  ConversationShareCubit build() => ConversationShareCubit(
    conversation: conversation,
    repository: repository,
    engine: () => engine,
    engines: () => const [deepl],
    languages: () => const [
      german,
      Language.auto,
      Language.custom('Pirate'),
      french,
      Language(code: 'EN', name: 'English (US)'),
    ],
    addresses: () async => addresses,
    server: ({required address, required room, required strings}) async {
      boundTo.add(address);
      if (serverGate case final gate?) await gate.future;
      if (serverError case final error?) throw error;
      final server = FakeShareServer(room);
      servers.add(server);
      return server;
    },
    secrets: ShareSecrets(Random(5)),
    screenAwake: screenAwake,
    timer: timers.call,
    clock: () => now,
  );

  setUp(() {
    conversation = MockConversationCubit();
    conversationStates = StreamController<ConversationState>.broadcast();
    when(() => conversation.state).thenReturn(conversationState());
    when(() => conversation.stream)
        .thenAnswer((_) => conversationStates.stream);
    when(
      () => conversation.submitGuest(
        any(),
        language: any(named: 'language'),
        guest: any(named: 'guest'),
      ),
    ).thenAnswer((_) async {});
    repository = MockTranslationRepository();
    when(
      () => repository.needsConsent(
        any(),
        source: any(named: 'source'),
        target: any(named: 'target'),
      ),
    ).thenReturn(true);
    when(() => repository.privacyMode).thenReturn(PrivacyMode.offlineFirst);
    when(() => repository.consentedProviders).thenReturn(const {});
    when(() => repository.destinationOf(any()))
        .thenReturn(const PublicInstanceDestination('mozhi.example.org'));
    screenAwake = MockScreenAwake();
    when(() => screenAwake.setEnabled(enabled: any(named: 'enabled')))
        .thenAnswer((_) async {});
    timers = FakeTimers();
    now = DateTime(2026, 10, 22, 12);
    addresses = ['192.168.1.23', '10.0.0.4'];
    servers = [];
    boundTo = [];
    serverError = null;
    serverGate = null;
    engine = deepl;
  });

  tearDown(() => conversationStates.close());

  group('start', () {
    blocTest<ConversationShareCubit, ConversationShareState>(
      'needs a local network',
      setUp: () => addresses = [],
      build: build,
      act: (cubit) => cubit.start(),
      expect: () => const [
        ConversationShareState(status: ConversationShareStatus.starting),
        ConversationShareState(status: ConversationShareStatus.noNetwork),
      ],
      verify: (_) => expect(boundTo, isEmpty),
    );

    blocTest<ConversationShareCubit, ConversationShareState>(
      'reports a server that does not start',
      setUp: () => serverError = StateError('in use'),
      build: build,
      act: (cubit) => cubit.start(),
      expect: () => const [
        ConversationShareState(status: ConversationShareStatus.starting),
        ConversationShareState(status: ConversationShareStatus.failed),
      ],
    );

    test('serves the conversation on the best address', () async {
      final cubit = build();
      addTearDown(cubit.close);

      await cubit.start();

      expect(boundTo, ['192.168.1.23']);
      final state = cubit.state;
      expect(state.status, ConversationShareStatus.live);
      expect(state.isLive, isTrue);
      expect(state.isActive, isTrue);
      expect(state.url, servers.single.url);
      expect(state.pin, matches(RegExp(r'^\d{4}$')));
      expect(state.guests, isEmpty);
      expect(state.repliesAllowed, isTrue);
      expect(state.locked, isFalse);
      expect(state.engineName, 'DeepL');
      verify(() => screenAwake.setEnabled(enabled: true)).called(1);

      // Guests pick the conversation's languages first, then the engine's.
      final room = servers.single.room;
      expect(room.languages, [english, spanish, french, german]);
      expect(room.token, matches(RegExp(r'^[A-Za-z0-9_-]{22}$')));
    });

    test('can go without a PIN, and starts once', () async {
      final cubit = build();
      addTearDown(cubit.close);

      await Future.wait([cubit.start(pin: false), cubit.start()]);

      expect(cubit.state.pin, isNull);
      expect(servers, hasLength(1));
    });

    test('shares what is said from now on', () async {
      when(() => conversation.state)
          .thenReturn(conversationState(turns: [turnOf(original: 'Before')]));
      final cubit = build();
      addTearDown(cubit.close);
      await cubit.start(pin: false);
      final room = servers.single.room;
      final guest = (room.join(languageCode: 'es') as ShareJoined).guest;

      expect(room.snapshotFor(guest)['turns'], isEmpty);

      conversationStates.add(
        conversationState(
          turns: [
            turnOf(original: 'Before'),
            turnOf(id: 1, original: 'Now'),
          ],
        ),
      );
      await settle();
      final turns = room.snapshotFor(guest)['turns']! as List;
      expect(turns, hasLength(1));
      expect((turns.single as Map)['original'], 'Now');
    });

    test('is dropped when stopped while starting', () async {
      final gate = serverGate = Completer<void>();
      final cubit = build();
      addTearDown(cubit.close);

      final started = cubit.start();
      await settle();
      await cubit.stop();
      gate.complete();
      await started;

      expect(cubit.state.status, ConversationShareStatus.idle);
      expect(servers.single.closed, isTrue);
      expect(servers.single.room.ended, isTrue);
    });

    test('is dropped when the network answer comes too late', () async {
      final cubit = build();
      final addressesGate = Completer<List<String>>();
      final late = ConversationShareCubit(
        conversation: conversation,
        repository: repository,
        engine: () => engine,
        engines: () => const [],
        languages: () => const [],
        addresses: () => addressesGate.future,
        screenAwake: screenAwake,
        timer: timers.call,
      );
      addTearDown(cubit.close);

      final started = late.start();
      await late.close();
      addressesGate.complete(['192.168.1.23']);
      await started;

      expect(late.state.isLive, isFalse);
      expect(boundTo, isEmpty);
    });

    test('ends the room when a failed start is stale', () async {
      final gate = serverGate = Completer<void>();
      serverError = StateError('boom');
      final cubit = build();
      addTearDown(cubit.close);

      final started = cubit.start();
      await settle();
      await cubit.stop();
      gate.complete();
      await started;

      expect(cubit.state.status, ConversationShareStatus.idle);
    });
  });

  group('while live', () {
    late ConversationShareCubit cubit;
    late ShareRoom room;

    setUp(() async {
      cubit = build();
      await cubit.start();
      room = servers.single.room;
    });

    tearDown(() => cubit.close());

    test('shows the guests and their extra languages', () async {
      when(() => repository.translate(any(), any()))
          .thenAnswer((_) => const Stream.empty());
      final joined =
          room.join(languageCode: 'fr', pin: cubit.state.pin) as ShareJoined;
      room.update([turnOf()]);
      await settle();

      expect(cubit.state.guests, [joined.guest]);
      expect(cubit.state.languages.single.language, french);
      expect(cubit.state.maxExtraLanguages, ShareRoom.defaultMaxExtraLanguages);
      final consent = cubit.state.languages.single.consent!;

      cubit.retryLanguage(french, consent: consent);
      verify(() => repository.translate(deepl, any())).called(1);
      // Nothing it would still let through is left.
      verify(() => repository.revokeOnce(consent)).called(1);
    });

    test("lets guests always read the conversation's languages", () {
      expect(room.readableLanguages, [english, spanish]);
    });

    test('adds guest replies to the conversation', () async {
      final joined =
          room.join(languageCode: 'fr', pin: cubit.state.pin) as ShareJoined;

      room.reply(joined.guest, 'Bonjour');

      verify(
        () => conversation.submitGuest('Bonjour', language: french, guest: 1),
      ).called(1);
    });

    test('changes the PIN and replies', () {
      final pin = cubit.state.pin;
      cubit.setPinRequired(required: false);
      expect(cubit.state.pin, isNull);
      expect(room.pin, isNull);

      cubit.setPinRequired(required: true);
      expect(cubit.state.pin, matches(RegExp(r'^\d{4}$')));
      expect(cubit.state.pin, isNot(pin));

      cubit.setRepliesAllowed(allowed: false);
      expect(cubit.state.repliesAllowed, isFalse);
      expect(room.repliesAllowed, isFalse);
    });

    test('stops for everyone', () async {
      await cubit.stop();

      expect(cubit.state, const ConversationShareState());
      expect(room.ended, isTrue);
      expect(servers.single.closed, isTrue);
      verify(() => screenAwake.setEnabled(enabled: false)).called(1);

      cubit
        ..setPinRequired(required: true)
        ..setRepliesAllowed(allowed: false)
        ..retryLanguage(french);
      expect(cubit.state, const ConversationShareState());
    });

    test('stops when no screen of the conversation is shown', () async {
      final page = Object();
      final conversationScreen = Object();
      // Nothing registered yet: the grace started with the sharing.
      expect(timers.pending(cubit.leaveGrace), isTrue);

      cubit
        ..setVisible(page, visible: true)
        ..setVisible(conversationScreen, visible: true);
      expect(timers.pending(cubit.leaveGrace), isFalse);

      cubit.setVisible(page, visible: false);
      expect(timers.pending(cubit.leaveGrace), isFalse);

      cubit.setVisible(conversationScreen, visible: false);
      expect(timers.pending(cubit.leaveGrace), isTrue);
      cubit.setVisible(page, visible: true);
      timers.fire(cubit.leaveGrace);
      expect(cubit.state.isLive, isTrue);

      cubit.setVisible(page, visible: false);
      timers.fire(cubit.leaveGrace);
      await settle();
      expect(cubit.state.status, ConversationShareStatus.idle);
    });

    test('stops when the app stays in the background', () async {
      final screen = Object();
      cubit
        ..setVisible(screen, visible: true)
        ..appHidden()
        ..appHidden();
      expect(timers.pending(cubit.hiddenLimit), isTrue);

      cubit.appShown();
      expect(timers.pending(cubit.hiddenLimit), isFalse);
      expect(cubit.state.isLive, isTrue);

      cubit.appHidden();
      timers.fire(cubit.hiddenLimit);
      await settle();
      expect(cubit.state.status, ConversationShareStatus.idle);
    });

    test('stops on return after a long background', () async {
      final screen = Object();
      cubit
        ..setVisible(screen, visible: true)
        ..appHidden();
      now = now.add(cubit.hiddenLimit);

      cubit.appShown();
      await settle();
      expect(cubit.state.status, ConversationShareStatus.idle);
    });

    test('ignores the background when not shared', () async {
      await cubit.stop();
      cubit
        ..appHidden()
        ..appShown();

      expect(timers.pending(cubit.hiddenLimit), isFalse);
    });
  });

  test(
    'takes the engine, languages and options of the translate screen',
    () async {
      final translate = MockTranslateCubit();
      when(() => translate.state).thenReturn(translateState());
      when(
        () => repository.needsConsent(
          any(),
          source: any(named: 'source'),
          target: any(named: 'target'),
        ),
      ).thenReturn(false);
      when(() => repository.translate(any(), any()))
          .thenAnswer((_) => const Stream.empty());
      final cubit = ConversationShareCubit.withTranslate(
        conversation: conversation,
        translate: translate,
        repository: repository,
        addresses: () async => addresses,
        server: ({required address, required room, required strings}) async {
          final server = FakeShareServer(room);
          servers.add(server);
          return server;
        },
      );
      addTearDown(cubit.close);

      await cubit.start(pin: false);
      final room = servers.single.room;
      expect(room.languages, [english, spanish, french, german]);
      room
        ..join(languageCode: 'fr')
        ..update([turnOf()]);

      expect(cubit.state.engineName, 'DeepL');
      verify(() => repository.translate(deepl, any())).called(1);
    },
  );

  test('stops when closed', () async {
    final cubit = build();
    await cubit.start();

    await cubit.close();

    expect(servers.single.closed, isTrue);
  });
}
