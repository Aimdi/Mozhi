@Timeout(Duration(seconds: 60))
library;

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/documents/data/document_file_service.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/phrasebook/data/phrasebook_repository.dart';
import 'package:mozhi/practice/data/fsrs.dart';
import 'package:mozhi/practice/data/practice_repository.dart';
import 'package:mozhi/practice/data/practice_speech.dart';
import 'package:mozhi/practice/models/practice_card.dart';
import 'package:mozhi/practice/models/practice_settings.dart';
import 'package:mozhi/practice/view/practice_page.dart';
import 'package:mozhi/practice/widgets/anki_export_sheet.dart';
import 'package:mozhi/practice/widgets/practice_entry_points.dart';
import 'package:mozhi/practice/widgets/rating_bar.dart';
import 'package:mozhi/speech/speech_service.dart';

import '../helpers.dart';

class _MockSpeech extends Mock implements SpeechService;

class _MockFiles extends Mock implements DocumentFileService;

class _Harness {
  new(this.fixture, {PracticeRecognizer? recognizer})
    : recognizer = recognizer ?? FakeRecognizer();

  final PracticeFixture fixture;
  final PracticeRecognizer recognizer;
  final speech = _MockSpeech();
  late final GoRouter router;

  Future<void> pump(
    WidgetTester tester, {
    String location = '/practice',
    Size size = const Size(400, 900),
  }) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    when(() => speech.speaking).thenAnswer((_) => const Stream.empty());
    when(() => speech.current).thenReturn(null);
    when(
      () => speech.toggle(
        id: any(named: 'id'),
        text: any(named: 'text'),
        languageCode: any(named: 'languageCode'),
      ),
    ).thenAnswer((_) async {});
    router = GoRouter(
      initialLocation: location,
      routes: [
        GoRoute(
          path: '/practice',
          builder: (context, state) => PracticePage(
            collectionId: state.uri.queryParameters['collection'],
            recognizer: recognizer,
          ),
        ),
        GoRoute(
          path: '/phrasebook',
          builder: (context, state) => const Scaffold(body: Text('phrasebook')),
        ),
        GoRoute(
          path: '/settings/voice',
          builder: (context, state) => const Scaffold(body: Text('voice')),
        ),
      ],
    );
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<PracticeRepository>.value(value: fixture.practice),
          RepositoryProvider<SpeechService>.value(value: speech),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await settle(tester);
  }
}

/// Lets the stores answer (they work outside the fake clock's control).
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }
  await tester.pumpAndSettle();
  // The due count is recounted shortly after the phrasebook changed.
  await tester.pump(const Duration(milliseconds: 400));
}

/// Scrolls [finder] into view.
Future<void> bringIntoView(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

PracticeFixture _fixture({int favorites = 2}) => PracticeFixture(
  clock: TestClock(DateTime.now()),
  favorites: [for (var i = 1; i <= favorites; i++) favorite('$i')],
);

void main() {
  setUpAll(() {
    registerFallbackValue(Uint8List(0));
  });

  testWidgets('the overview says what is due and starts a session', (
    tester,
  ) async {
    final harness = _Harness(_fixture());
    await harness.pump(tester);
    expect(find.text('Nothing to review'), findsOneWidget);
    expect(find.text('2 new cards today'), findsOneWidget);
    expect(find.text('Favorites'), findsOneWidget);
    expect(find.text('2 phrases'), findsOneWidget);

    await tester.tap(find.byKey(const Key('practice_start')));
    await settle(tester);
    expect(find.text('2 cards left'), findsOneWidget);
    expect(find.text('What does it mean?'), findsOneWidget);
    expect(find.text('New'), findsOneWidget);
    expect(find.byKey(const Key('practice_back')), findsNothing);

    await tester.tap(find.byKey(const Key('practice_show_answer')));
    await settle(tester);
    expect(find.byKey(const Key('practice_back')), findsOneWidget);
    expect(find.text('Again'), findsOneWidget);
    expect(find.text('1 min'), findsOneWidget);
    expect(find.text('10 min'), findsOneWidget);
    expect(find.bySemanticsLabel('Good, next in 10 min'), findsOneWidget);

    await tester.tap(find.byKey(const Key('practice_rate_good')));
    await settle(tester);
    expect(find.text('2 cards left'), findsOneWidget);
    expect(find.byKey(const Key('practice_back')), findsNothing);
    expect(await harness.fixture.practice.reviewedCount(), 1);

    // Undo shows the card again.
    await tester.tap(find.byKey(const Key('practice_undo')));
    await settle(tester);
    expect(await harness.fixture.practice.reviewedCount(), 0);

    // End the session: the summary, then the overview.
    await tester.tap(find.byKey(const Key('practice_end')));
    await settle(tester);
    expect(find.text('Nothing to review right now'), findsOneWidget);
    expect(find.byKey(const Key('practice_keep_going')), findsOneWidget);
    await tester.tap(find.byKey(const Key('practice_done')));
    await settle(tester);
    expect(find.byKey(const Key('practice_start')), findsOneWidget);
  });

  testWidgets('keys: Space shows the answer, 1 to 4 rate, Z undoes', (
    tester,
  ) async {
    final harness = _Harness(_fixture(favorites: 1));
    await harness.pump(tester);
    await tester.tap(find.byKey(const Key('practice_start')));
    await settle(tester);
    // Not before the answer shows.
    await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
    await settle(tester);
    expect(await harness.fixture.practice.reviewedCount(), 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await settle(tester);
    expect(find.byKey(const Key('practice_back')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await settle(tester);
    expect(await harness.fixture.practice.reviewedCount(), 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await settle(tester);
    expect(await harness.fixture.practice.reviewedCount(), 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.numpad4);
    await settle(tester);
    // Easy: learned for days, the session is over.
    expect(find.text('Session done'), findsOneWidget);
    expect(find.text('You reviewed 1 card'), findsOneWidget);
    expect(find.text('1 remembered'), findsOneWidget);
    expect(find.text('1 new card learned'), findsOneWidget);
    // The other direction is new, but one phrase a day.
    await tester.tap(find.byKey(const Key('practice_done')));
    await settle(tester);
    expect(find.text('Nothing to review'), findsOneWidget);
  });

  testWidgets('typing practice compares the answer', (tester) async {
    final fixture = _fixture(favorites: 1);
    await tester.runAsync(
      () => fixture.practice.saveSettings(
        const PracticeSettings(
          directions: {CardDirection.produce},
          typeAnswers: true,
        ),
      ),
    );
    final harness = _Harness(
      fixture,
      recognizer: FakeRecognizer(
        available: PracticeSpeechAvailability.unsupported,
      ),
    );
    await harness.pump(tester);
    await tester.tap(find.byKey(const Key('practice_start')));
    await settle(tester);
    expect(find.text('How do you say it?'), findsOneWidget);
    expect(find.byKey(const Key('practice_speak')), findsNothing);
    await tester.enterText(
      find.byKey(const Key('practice_answer')),
      'tradução',
    );
    // Digits typed into the field are not ratings.
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(find.text('1 of 2 words right'), findsOneWidget);
    expect(find.text('You typed: tradução'), findsOneWidget);
    expect(find.bySemanticsLabel('1, missed'), findsOneWidget);
    expect(find.bySemanticsLabel('tradução, right'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('Again, next in .*, Suggested')),
      findsOneWidget,
    );
    expect(await fixture.practice.reviewedCount(), 0);
  });

  testWidgets('speaking practice: tap to start and stop, then compare', (
    tester,
  ) async {
    final fixture = _fixture(favorites: 1);
    await tester.runAsync(
      () => fixture.practice.saveSettings(
        const PracticeSettings(directions: {CardDirection.produce}),
      ),
    );
    final recognizer = FakeRecognizer();
    final harness = _Harness(fixture, recognizer: recognizer);
    await harness.pump(tester);
    expect(find.byKey(const Key('practice_speaking')), findsOneWidget);
    await tester.tap(find.byKey(const Key('practice_start')));
    await settle(tester);
    final mic = find.byKey(const Key('practice_speak'));
    expect(mic, findsOneWidget);

    await tester.tap(mic);
    await tester.pump();
    expect(recognizer.language, 'pt');
    expect(find.text('Listening…'), findsOneWidget);
    recognizer.onLevel!(0.7);
    await tester.pump();
    await tester.tap(mic);
    await tester.pump();
    expect(recognizer.stops, 1);
    expect(find.text('Transcribing on this phone…'), findsOneWidget);
    recognizer.answer('tradução 1');
    await settle(tester);
    expect(find.text('Heard: tradução 1'), findsOneWidget);
    expect(find.text('2 of 2 words right'), findsOneWidget);
    expect(find.byKey(const Key('practice_back')), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('Good, next in .*, Suggested')),
      findsOneWidget,
    );

    // Hold to speak: letting go stops.
    final gesture = await tester.createGesture();
    await gesture.down(tester.getCenter(mic));
    await tester.pump();
    expect(find.text('Listening…'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.up(timeStamp: const Duration(milliseconds: 600));
    await tester.pump();
    expect(recognizer.stops, 2);
    recognizer.fail(
      const PracticeSpeechException(PracticeSpeechFailure.noSpeech),
    );
    await settle(tester);
    expect(
      find.text(
        'Nothing was heard. Try again a little closer to the microphone.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('without a speech model the overview points to the settings', (
    tester,
  ) async {
    final recognizer = FakeRecognizer(
      available: PracticeSpeechAvailability.modelMissing,
    );
    final harness = _Harness(_fixture(favorites: 1), recognizer: recognizer);
    await harness.pump(tester);
    await bringIntoView(
      tester,
      find.byKey(const Key('practice_voice_settings')),
    );
    recognizer.available = PracticeSpeechAvailability.ready;
    await tester.tap(find.byKey(const Key('practice_voice_settings')));
    await settle(tester);
    expect(find.text('voice'), findsOneWidget);
    harness.router.pop();
    await settle(tester);
    expect(
      find.textContaining('hold the microphone and say the phrase'),
      findsOneWidget,
    );
  });

  testWidgets('without speech recognition it says why', (tester) async {
    final harness = _Harness(
      _fixture(favorites: 1),
      recognizer: FakeRecognizer(
        available: PracticeSpeechAvailability.unsupported,
      ),
    );
    await harness.pump(tester);
    await bringIntoView(tester, find.byKey(const Key('practice_speaking')));
    expect(
      find.textContaining('Speaking practice works in the Android app'),
      findsOneWidget,
    );
  });

  testWidgets('without phrases it offers the phrasebook', (tester) async {
    final harness = _Harness(_fixture(favorites: 0));
    await harness.pump(tester);
    expect(find.text('Nothing to practice yet'), findsOneWidget);
    await tester.tap(find.byKey(const Key('practice_open_phrasebook')));
    await settle(tester);
    expect(find.text('phrasebook'), findsOneWidget);
  });

  testWidgets('choosing collections and directions', (tester) async {
    final fixture = _fixture(favorites: 1);
    final harness = _Harness(fixture);
    await harness.pump(tester);
    await tester.tap(
      find.byKey(const ValueKey('practice_collection_favorites')),
    );
    await settle(tester);
    expect(
      (await tester.runAsync(fixture.practice.settings))!.collectionIds,
      isEmpty,
    );
    expect(find.text('No new cards today'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('practice_collection_favorites')),
    );
    await settle(tester);
    expect(
      (await tester.runAsync(fixture.practice.settings))!.collectionIds,
      isNull,
    );

    final produce = find.byKey(const ValueKey('practice_direction_produce'));
    await bringIntoView(tester, produce);
    await tester.tap(produce);
    await settle(tester);
    expect((await tester.runAsync(fixture.practice.settings))!.directions, {
      CardDirection.recognize,
    });
    // The last direction stays.
    final recognize = tester.widget<CheckboxListTile>(
      find.byKey(const ValueKey('practice_direction_recognize')),
    );
    expect(recognize.onChanged, isNull);
    await tester.tap(produce);
    await settle(tester);

    final typing = find.byKey(const Key('practice_type_answers'));
    await bringIntoView(tester, typing);
    await tester.tap(typing);
    await settle(tester);
    expect(
      (await tester.runAsync(fixture.practice.settings))!.typeAnswers,
      isTrue,
    );

    // Sliders store the value when let go.
    final perDay = find.descendant(
      of: find.byKey(const Key('practice_new_per_day')),
      matching: find.byType(Slider),
    );
    await bringIntoView(tester, perDay);
    await tester.drag(perDay, const Offset(-600, 0));
    await settle(tester);
    expect(
      (await tester.runAsync(fixture.practice.settings))!.newCardsPerDay,
      0,
    );
    final retention = find.descendant(
      of: find.byKey(const Key('practice_retention')),
      matching: find.byType(Slider),
    );
    await bringIntoView(tester, retention);
    await tester.drag(retention, const Offset(600, 0));
    await settle(tester);
    expect(
      (await tester.runAsync(fixture.practice.settings))!.desiredRetention,
      0.97,
    );
  });

  testWidgets('exports a collection for Anki', (tester) async {
    final files = _MockFiles();
    when(() => files.canShareFiles).thenReturn(true);
    when(
      () => files.saveFile(
        fileName: any(named: 'fileName'),
        bytes: any(named: 'bytes'),
        mimeType: any(named: 'mimeType'),
      ),
    ).thenAnswer((_) async => true);
    PracticeExport.files = files;
    addTearDown(
      () => PracticeExport.files = const PlatformDocumentFileService(),
    );
    final harness = _Harness(_fixture(favorites: 1));
    await harness.pump(tester);
    final export = find.byKey(const Key('practice_export'));
    await bringIntoView(tester, export);
    await tester.tap(export);
    await settle(tester);
    expect(find.byKey(const Key('practice_export_share')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('practice_export_favorites')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('practice_export_save')));
    await settle(tester);
    final captured = verify(
      () => files.saveFile(
        fileName: 'mozhi-anki-favorites.txt',
        bytes: captureAny(named: 'bytes'),
        mimeType: 'text/plain',
      ),
    ).captured;
    final text = String.fromCharCodes(captured.single as Uint8List);
    expect(text, startsWith('#separator:tab\n'));
    expect(find.text('Saved 1 card'), findsOneWidget);
  });

  testWidgets('a failed export says so', (tester) async {
    final files = _MockFiles();
    when(() => files.canShareFiles).thenReturn(true);
    when(
      () => files.shareFile(
        fileName: any(named: 'fileName'),
        bytes: any(named: 'bytes'),
        mimeType: any(named: 'mimeType'),
        origin: any(named: 'origin'),
      ),
    ).thenThrow(const ShareUnsupportedException());
    PracticeExport.files = files;
    addTearDown(
      () => PracticeExport.files = const PlatformDocumentFileService(),
    );
    final harness = _Harness(_fixture(favorites: 1));
    await harness.pump(tester);
    final export = find.byKey(const Key('practice_export'));
    await bringIntoView(tester, export);
    await tester.tap(export);
    await settle(tester);
    await tester.tap(find.byKey(const Key('practice_export_share')));
    await settle(tester);
    expect(
      find.text(
        "Sharing files isn't supported on this device. Use Save instead.",
      ),
      findsOneWidget,
    );
  });

  testWidgets('unreadable progress can be started over', (tester) async {
    final fixture = _fixture(favorites: 1);
    await tester.runAsync(
      () => fixture.practice.saveSettings(const PracticeSettings()),
    );
    fixture.keyStore.values.clear();
    fixture.practice = fixture.newPractice();
    final harness = _Harness(fixture);
    await harness.pump(tester);
    expect(find.text("Your practice progress can't be read"), findsOneWidget);
    await tester.tap(find.byKey(const Key('practice_start_over')));
    await settle(tester);
    expect(find.byKey(const Key('practice_start')), findsOneWidget);
  });

  testWidgets('a failed load can be retried', (tester) async {
    final fixture = _fixture(favorites: 1);
    final broken = _ThrowingPhrasebook(fixture.phrasebook);
    fixture.practice = PracticeRepository(
      phrasebook: broken,
      store: fixture.store,
      keyStore: fixture.keyStore,
    );
    final harness = _Harness(fixture);
    await harness.pump(tester);
    expect(find.text("Couldn't load your phrases"), findsOneWidget);
    broken.failing = false;
    await tester.tap(find.byKey(const Key('practice_retry')));
    await settle(tester);
    expect(find.byKey(const Key('practice_start')), findsOneWidget);
  });

  testWidgets('one collection, on a wide screen', (tester) async {
    final fixture = _fixture(favorites: 1);
    final trip = await tester.runAsync(
      () => fixture.collection('Trip to Lisbon', ['Hello']),
    );
    final harness = _Harness(fixture);
    await harness.pump(
      tester,
      location: '/practice?collection=${trip!.id}',
      size: const Size(1200, 900),
    );
    expect(find.text('Trip to Lisbon'), findsOneWidget);
    expect(find.text('1 new card today'), findsOneWidget);
    // No collection picker when practising one.
    expect(find.text('Collections'), findsNothing);
    await tester.tap(find.byKey(const Key('practice_start')));
    await settle(tester);
    expect(find.text('Hello (pt)'), findsOneWidget);
  });

  testWidgets('the answer shows the pronunciation and the note', (
    tester,
  ) async {
    final fixture = _fixture(favorites: 0);
    await tester.runAsync(() async {
      final trip = await fixture.phrasebook.createCollection('Trip');
      final addition = await fixture.phrasebook.addPhrase(
        const PhraseDraft(
          text: 'Thank you',
          translation: 'Obrigado',
          sourceCode: 'en',
          targetCode: 'pt',
          pronunciation: 'oh-bree-GAH-doo',
        ),
        trip.id,
      );
      await fixture.phrasebook.updateNote(
        addition.phrase.id,
        'Obrigada if female',
      );
      await fixture.practice.saveSettings(
        const PracticeSettings(directions: {CardDirection.recognize}),
      );
    });
    final harness = _Harness(fixture);
    await harness.pump(tester);
    await tester.tap(find.byKey(const Key('practice_start')));
    await settle(tester);
    expect(find.text('Obrigado'), findsOneWidget);
    await tester.tap(find.byKey(const Key('practice_show_answer')));
    await settle(tester);
    expect(find.text('Thank you'), findsOneWidget);
    expect(find.text('oh-bree-GAH-doo'), findsOneWidget);
    expect(find.text('Obrigada if female'), findsOneWidget);
    // Listen reads the Portuguese.
    await tester.tap(find.byIcon(Icons.volume_up_outlined).first);
    await tester.pump();
    verify(
      () => harness.speech.toggle(
        id: 'practice_front',
        text: 'Obrigado',
        languageCode: 'pt',
      ),
    ).called(1);
    // Easy: nothing else is due; the summary says when.
    await tester.tap(find.byKey(const Key('practice_rate_easy')));
    await settle(tester);
    expect(find.text('Next cards due in 16 days'), findsOneWidget);
    expect(find.byKey(const Key('practice_keep_going')), findsNothing);
    await tester.tap(find.byKey(const Key('practice_done')));
    await settle(tester);
    expect(find.text("You're all caught up"), findsOneWidget);
    expect(find.text('Next cards due in 16 days'), findsOneWidget);
  });

  testWidgets('a typed answer nearly right, with extra words', (tester) async {
    final fixture = _fixture(favorites: 1);
    await tester.runAsync(
      () => fixture.practice.saveSettings(
        const PracticeSettings(
          directions: {CardDirection.produce},
          typeAnswers: true,
        ),
      ),
    );
    final harness = _Harness(fixture);
    await harness.pump(tester);
    await tester.tap(find.byKey(const Key('practice_start')));
    await settle(tester);
    // An empty answer is not checked.
    await tester.tap(find.byTooltip('Check'));
    await settle(tester);
    expect(find.byKey(const Key('practice_back')), findsNothing);
    await tester.enterText(
      find.byKey(const Key('practice_answer')),
      'tradusao 1 mais',
    );
    await tester.tap(find.byTooltip('Check'));
    await settle(tester);
    expect(find.bySemanticsLabel('tradução, nearly'), findsOneWidget);
    expect(find.text('Also said: mais'), findsOneWidget);
  });

  testWidgets('speaking practice explains failures; keys toggle the mic', (
    tester,
  ) async {
    final fixture = _fixture(favorites: 1);
    await tester.runAsync(
      () => fixture.practice.saveSettings(
        const PracticeSettings(directions: {CardDirection.produce}),
      ),
    );
    final recognizer = FakeRecognizer();
    final harness = _Harness(fixture, recognizer: recognizer);
    await harness.pump(tester);
    await tester.tap(find.byKey(const Key('practice_start')));
    await settle(tester);
    final mic = find.byKey(const Key('practice_speak'));
    Focus.of(
      tester.element(find.descendant(of: mic, matching: find.byType(Listener))),
    ).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(find.text('Listening…'), findsOneWidget);
    // Enter stops (it does not show the answer while the mic has focus).
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(recognizer.stops, 1);
    recognizer.fail(
      const PracticeSpeechException(PracticeSpeechFailure.permissionDenied),
    );
    await settle(tester);
    expect(
      find.text('Allow the microphone to practice speaking.'),
      findsOneWidget,
    );
    await tester.tap(mic);
    await tester.pump();
    recognizer.fail(
      const PracticeSpeechException(PracticeSpeechFailure.engine),
    );
    await settle(tester);
    expect(find.text("Couldn't hear that. Try again."), findsOneWidget);
  });

  testWidgets('a review that cannot be stored is said once', (tester) async {
    final fixture = _fixture();
    final harness = _Harness(fixture);
    await harness.pump(tester);
    await tester.tap(find.byKey(const Key('practice_start')));
    await settle(tester);
    fixture.keyStore.values.clear();
    fixture.store.failWrites = true;
    await tester.tap(find.byKey(const Key('practice_show_answer')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('practice_rate_good')));
    await settle(tester);
    expect(
      find.text("Couldn't save your progress on this device"),
      findsOneWidget,
    );
  });

  testWidgets('without a recognizer it uses the offline speech, if any', (
    tester,
  ) async {
    final fixture = _fixture(favorites: 1);
    await tester.pumpWidget(
      RepositoryProvider<PracticeRepository>.value(
        value: fixture.practice,
        child: const MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: PracticePage(),
        ),
      ),
    );
    await settle(tester);
    await bringIntoView(tester, find.byKey(const Key('practice_speaking')));
    expect(
      find.textContaining('Speaking practice works in the Android app'),
      findsOneWidget,
    );
  });

  group(PracticeMenuLabel, () {
    Future<void> pumpLabel(
      WidgetTester tester,
      PracticeRepository? practice,
    ) async {
      const label = MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: PracticeMenuLabel()),
      );
      await tester.pumpWidget(
        practice == null
            ? label
            : RepositoryProvider.value(value: practice, child: label),
      );
    }

    testWidgets('counts the cards due in a badge', (tester) async {
      final fixture = _fixture(favorites: 1);
      final now = fixture.clock.now;
      await tester.runAsync(
        () => fixture.practice.saveCard(
          PracticeCard(
            phraseId: 'h:1',
            direction: CardDirection.recognize,
            fsrs: FsrsCard(
              due: now.subtract(const Duration(days: 1)),
              state: FsrsState.review,
              stability: 3,
              difficulty: 5,
              lastReview: now.subtract(const Duration(days: 4)),
            ),
            createdAt: now.subtract(const Duration(days: 5)),
            updatedAt: now.subtract(const Duration(days: 4)),
            reps: 2,
          ),
        ),
      );
      await pumpLabel(tester, fixture.practice);
      await settle(tester);
      expect(find.byKey(const Key('practice_due_badge')), findsOneWidget);
      expect(find.bySemanticsLabel('1 card to review'), findsOneWidget);
    });

    testWidgets('is a plain label without practice', (tester) async {
      await pumpLabel(tester, null);
      expect(find.text('Practice'), findsOneWidget);
      expect(find.byKey(const Key('practice_due_badge')), findsNothing);
    });
  });

  testWidgets('rating buttons without intervals', (tester) async {
    FsrsRating? rated;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: RatingBar(intervals: const {}, onRate: (r) => rated = r),
        ),
      ),
    );
    expect(find.bySemanticsLabel('Hard'), findsOneWidget);
    await tester.tap(find.text('Hard'));
    expect(rated, FsrsRating.hard);
  });

  testWidgets('a collection Practice button opens practice of it', (
    tester,
  ) async {
    String? opened;
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(
            body: Column(
              children: [
                PracticeCollectionButton(collectionId: 'c:1'),
                PracticeCollectionButton(collectionId: 'c:2', compact: true),
              ],
            ),
          ),
        ),
        GoRoute(
          path: '/practice',
          builder: (context, state) {
            opened = state.uri.queryParameters['collection'];
            return const SizedBox();
          },
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    );
    await tester.tap(find.text('Practice'));
    await tester.pumpAndSettle();
    expect(opened, 'c:1');
    router.pop();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Practice this collection'));
    await tester.pumpAndSettle();
    expect(opened, 'c:2');
    expect(PracticePage.locationFor(), '/practice');
  });
}

/// A phrasebook whose reads fail while [failing].
class _ThrowingPhrasebook implements PhrasebookRepository {
  new(this._inner);

  final PhrasebookRepository _inner;
  bool failing = true;

  @override
  Stream<void> get changes => _inner.changes;

  @override
  Future<List<PhraseCollection>> collections() async {
    if (failing) throw StateError('broken');
    return await _inner.collections();
  }

  @override
  Future<List<Phrase>> phrases({String? collectionId}) =>
      _inner.phrases(collectionId: collectionId);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
