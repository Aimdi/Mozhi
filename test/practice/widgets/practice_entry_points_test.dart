import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/practice/data/fsrs.dart';
import 'package:mozhi/practice/data/practice_repository.dart';
import 'package:mozhi/practice/models/practice_card.dart';
import 'package:mozhi/practice/widgets/practice_settings_tile.dart';
import 'package:mozhi/translate/widgets/widgets.dart';

import '../../translate/helpers/helpers.dart';
import '../helpers.dart';

void main() {
  setUpAll(registerTranslateFallbacks);

  group('More tools', () {
    Future<TranslateHarness> open(
      WidgetTester tester, {
      PracticeRepository? practice,
    }) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(
        tester,
        size: const Size(400, 800),
        child: Align(
          alignment: Alignment.topRight,
          child: practice == null
              ? const MoreToolsButton()
              : RepositoryProvider<PracticeRepository>.value(
                  value: practice,
                  child: const MoreToolsButton(),
                ),
        ),
      );
      await tester.tap(find.byKey(const Key('translate_more_tools')));
      await tester.pumpAndSettle();
      return harness;
    }

    testWidgets('opens practice, with the cards due in a badge', (
      tester,
    ) async {
      final fixture = PracticeFixture(
        clock: TestClock(DateTime.now()),
        favorites: [favorite('1')],
      );
      final now = fixture.clock.now;
      await fixture.practice.saveCard(
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
      );
      final harness = await open(tester, practice: fixture.practice);
      final tool = find.byKey(const ValueKey('translate_tool_practice'));
      expect(tool, findsOneWidget);
      expect(find.text('Practice'), findsOneWidget);
      // The count is read from the stores.
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
      }
      expect(find.byKey(const Key('practice_due_badge')), findsOneWidget);
      await tester.tap(tool);
      await tester.pumpAndSettle();
      verify(
        () =>
            harness.router.push<void>('/practice', extra: any(named: 'extra')),
      ).called(1);
    });

    testWidgets('has no entry without practice', (tester) async {
      await open(tester);
      expect(
        find.byKey(const ValueKey('translate_tool_practice')),
        findsNothing,
      );
    });
  });

  testWidgets('the settings row opens practice', (tester) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) =>
              const Scaffold(body: PracticeSettingsTile()),
        ),
        GoRoute(
          path: '/practice',
          builder: (context, state) => const Text('practice page'),
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
    expect(PracticeSettingsTile.anchor, 'practice');
    expect(
      find.text(
        'Flashcards of your phrases, short review sessions, export to Anki',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('settings_practice')));
    await tester.pumpAndSettle();
    expect(find.text('practice page'), findsOneWidget);
  });
}
