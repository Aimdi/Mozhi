import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/practice/cubit/practice_cubit.dart';
import 'package:mozhi/practice/cubit/practice_speech_cubit.dart';
import 'package:mozhi/practice/data/fsrs.dart';
import 'package:mozhi/practice/data/fsrs_optimizer.dart';
import 'package:mozhi/practice/models/practice_review_log.dart';
import 'package:mozhi/practice/widgets/practice_overview.dart';

import '../helpers.dart';

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

Future<void> _waitForOptimization(WidgetTester tester) async {
  for (var i = 0; i < 300; i++) {
    await tester.pump();
    if (find.textContaining('better fit').evaluate().isNotEmpty) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
  }
}

Future<void> _pumpOverview(
  WidgetTester tester,
  PracticeCubit cubit,
  PracticeSpeechCubit speech,
) async {
  tester.view
    ..physicalSize = const Size(400, 900)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MultiBlocProvider(
      providers: [
        BlocProvider<PracticeCubit>.value(value: cubit),
        BlocProvider<PracticeSpeechCubit>.value(value: speech),
      ],
      child: MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: PracticeOverview(onExport: () {})),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('personalize schedule explains progress, fits and resets', (
    tester,
  ) async {
    final fixture = PracticeFixture(favorites: [favorite('1')]);
    final cubit = PracticeCubit(
      repository: fixture.practice,
      appLanguage: 'en',
      clock: fixture.clock.call,
    );
    final speech = PracticeSpeechCubit(recognizer: FakeRecognizer());
    addTearDown(() async {
      await cubit.close();
      await speech.close();
    });

    await cubit.load();
    await speech.load();
    await _pumpOverview(tester, cubit, speech);

    final tile = find.byKey(const Key('practice_personalize_schedule'));
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    expect(find.text('Personalize schedule'), findsOneWidget);
    expect(find.textContaining('Complete 50 more reviews'), findsOneWidget);
    expect(find.byKey(const Key('practice_personalize_run')), findsNothing);
    expect(find.byKey(const Key('practice_reset_weights')), findsNothing);

    // Seed 60 evaluable reviews with a faster-forgetting pattern.
    final base = DateTime.utc(2026, 1, 1, 9);
    final seededLogs = <Map<String, Object?>>[];
    for (var c = 0; c < 20; c++) {
      final t0 = base.add(Duration(hours: c));
      for (var r = 0; r < 4; r++) {
        seededLogs.add(
          PracticeReviewLog(
            cardKey: 'seed:$c#r',
            rating: r == 0 || r == 2 ? FsrsRating.good : FsrsRating.again,
            elapsedDays: r == 0 ? 0 : 4,
            state: r == 0 ? FsrsState.newCard : FsrsState.review,
            reviewedAt: t0.add(Duration(days: r * 4)),
          ).toJson(),
        );
      }
    }
    await tester.runAsync(
      () => fixture.practice.restoreBackup(
        {'version': 1, 'cards': <Object?>[], 'reviews': seededLogs},
        version: 1,
        merge: false,
      ),
    );
    await tester.runAsync(cubit.load);
    await tester.pumpAndSettle();

    final runButton = find.byKey(const Key('practice_personalize_run'));
    await tester.ensureVisible(runButton);
    await tester.pumpAndSettle();
    expect(find.textContaining('60 reviews'), findsOneWidget);

    await tester.tap(runButton);
    await _waitForOptimization(tester);
    await _settle(tester);
    expect(find.textContaining('better fit'), findsOneWidget);
    expect(cubit.state.settings.hasCustomWeights, isTrue);

    final resetTile = find.byKey(const Key('practice_reset_weights'));
    await tester.ensureVisible(resetTile);
    await tester.pumpAndSettle();
    expect(find.text('Reset schedule weights'), findsOneWidget);

    await tester.tap(resetTile);
    await _settle(tester);
    expect(find.byKey(const Key('practice_reset_weights')), findsNothing);
    expect(cubit.state.settings.hasCustomWeights, isFalse);
  });

  testWidgets('personalize schedule shows a SnackBar when optimization fails', (
    tester,
  ) async {
    final fixture = PracticeFixture(favorites: [favorite('1')]);
    final base = DateTime.utc(2026, 1, 1, 9);
    final seededLogs = <Map<String, Object?>>[];
    for (var c = 0; c < 20; c++) {
      final t0 = base.add(Duration(hours: c));
      for (var r = 0; r < 4; r++) {
        seededLogs.add(
          PracticeReviewLog(
            cardKey: 'seed:$c#r',
            rating: r == 0 || r == 2 ? FsrsRating.good : FsrsRating.again,
            elapsedDays: r == 0 ? 0 : 4,
            state: r == 0 ? FsrsState.newCard : FsrsState.review,
            reviewedAt: t0.add(Duration(days: r * 4)),
          ).toJson(),
        );
      }
    }
    await tester.runAsync(
      () => fixture.practice.restoreBackup(
        {'version': 1, 'cards': <Object?>[], 'reviews': seededLogs},
        version: 1,
        merge: false,
      ),
    );
    final cubit = PracticeCubit(
      repository: fixture.practice,
      appLanguage: 'en',
      clock: fixture.clock.call,
      optimizer: (_) =>
          Future<FsrsOptimizationResult>.error(StateError('optimizer boom')),
    );
    final speech = PracticeSpeechCubit(recognizer: FakeRecognizer());
    addTearDown(() async {
      await cubit.close();
      await speech.close();
    });

    await tester.runAsync(cubit.load);
    await tester.runAsync(speech.load);
    await _pumpOverview(tester, cubit, speech);

    final runButton = find.byKey(const Key('practice_personalize_run'));
    await tester.ensureVisible(runButton);
    await tester.pumpAndSettle();

    await tester.tap(runButton);
    await _settle(tester);

    expect(find.byType(SnackBar), findsOneWidget);
    expect(
      find.text('Could not personalize schedule. Please try again.'),
      findsOneWidget,
    );
    // Button is enabled again (spinner cleared).
    expect(find.byKey(const Key('practice_personalize_run')), findsOneWidget);
    expect(cubit.state.settings.hasCustomWeights, isFalse);
  });
}
