// The phrasebook's entry points in other features (History, More tools,
// Delete all local data): only where the app provides a phrasebook.
import 'package:flutter/semantics.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/view/history_page.dart';
import 'package:mozhi/history/view/widgets/history_entry_tile.dart';
import 'package:mozhi/phrasebook/data/phrasebook_repository.dart';
import 'package:mozhi/settings/view/widgets/delete_local_data.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';

import '../settings/view/helpers.dart' as settings_helpers;
import '../translate/helpers/helpers.dart';
import 'helpers.dart';
import 'pump.dart';

void main() {
  setUpAll(() {
    registerTranslateFallbacks();
    settings_helpers.registerFallbacks();
  });

  group('History', () {
    final entry = favoriteEntry(
      '7',
      text: 'Good night',
      translation: 'Boa noite',
    );

    testWidgets('a row offers "Add to phrasebook…" in its menu and to screen '
        'readers', (tester) async {
      final handle = tester.ensureSemantics();
      var added = 0;
      await tester.pumpPhrasebook(
        Scaffold(
          body: HistoryEntryTile(
            entry: entry,
            onTap: () {},
            onToggleFavorite: () {},
            onDelete: () {},
            onAddToPhrasebook: () => added++,
          ),
        ),
      );
      await tester.tap(find.byTooltip('More actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add to phrasebook…'));
      await tester.pumpAndSettle();
      expect(added, 1);
      final node = tester.getSemantics(find.text('Good night'));
      final actions = <String>[];
      node.owner!.rootSemanticsNode!.visitChildren((child) {
        void visit(SemanticsNode node) {
          for (final id
              in node.getSemanticsData().customSemanticsActionIds ??
                  const <int>[]) {
            actions.add(CustomSemanticsAction.getAction(id)?.label ?? '');
          }
          node.visitChildren((child) {
            visit(child);
            return true;
          });
        }

        visit(child);
        return true;
      });
      expect(actions, contains('Add to phrasebook…'));
      handle.dispose();
    });

    testWidgets('the menu has no such entry without a callback', (
      tester,
    ) async {
      await tester.pumpPhrasebook(
        Scaffold(
          body: HistoryEntryTile(
            entry: entry,
            onTap: () {},
            onToggleFavorite: () {},
            onDelete: () {},
          ),
        ),
      );
      await tester.tap(find.byTooltip('More actions'));
      await tester.pumpAndSettle();
      expect(find.text('Add to phrasebook…'), findsNothing);
    });

    testWidgets('the page adds rows to a collection and opens the phrasebook '
        'from Favorites', (tester) async {
      final repository = createPhrasebook();
      final words = await repository.createCollection('Words');
      final history = settings_helpers.createHistoryCubit(
        HistoryState(
          status: HistoryStatus.ready,
          entries: [entry],
          favoritesOnly: true,
        ),
      );
      final translate = settings_helpers.MockTranslateCubit();
      when(() => translate.state).thenReturn(const TranslateState());
      final router = settings_helpers.createRouter();
      when(() => router.push<void>(any(), extra: any(named: 'extra')))
          .thenAnswer((_) async {});
      tester.view
        ..physicalSize = const Size(600, 1200)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpView(
        RepositoryProvider<PhrasebookRepository>.value(
          value: repository,
          child: const HistoryPage(),
        ),
        history: history,
        translate: translate,
        router: router,
      );
      await tester.tap(find.byKey(HistoryView.openPhrasebookKey));
      verify(
        () => router.push<void>(
          '/phrasebook?collection=favorites',
          extra: any(named: 'extra'),
        ),
      ).called(1);

      await tester.tap(find.byTooltip('More actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add to phrasebook…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Words'));
      await tester.pumpAndSettle();
      final phrase = (await repository.phrases(collectionId: words.id)).single;
      expect(phrase.text, 'Good night');
      expect(phrase.origin, PhraseOrigin.history);
    });

    testWidgets('without a phrasebook, Favorites has no such button', (
      tester,
    ) async {
      final history = settings_helpers.createHistoryCubit(
        HistoryState(
          status: HistoryStatus.ready,
          entries: [entry],
          favoritesOnly: true,
        ),
      );
      final translate = settings_helpers.MockTranslateCubit();
      when(() => translate.state).thenReturn(const TranslateState());
      await tester.pumpView(
        const HistoryPage(),
        history: history,
        translate: translate,
      );
      expect(find.byKey(HistoryView.openPhrasebookKey), findsNothing);
    });
  });

  group('Translation', () {
    testWidgets('"Add to phrasebook…" beside the heart adds the result', (
      tester,
    ) async {
      final repository = createPhrasebook();
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(
        tester,
        child: RepositoryProvider<PhrasebookRepository>.value(
          value: repository,
          child: const OutputCard(),
        ),
      );
      await tester.tap(find.byTooltip('Add to phrasebook…'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('phrasebook_choose_new')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Trip');
      await tester.pump();
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      final phrases = await repository.phrases();
      final state = translatedState();
      expect(phrases.single.translation, state.output.trim());
      expect(phrases.single.text, (state.resultInput ?? state.input).trim());
    });

    testWidgets('no such button without a phrasebook', (tester) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const OutputCard());
      expect(find.byTooltip('Add to phrasebook…'), findsNothing);
    });
  });

  group('More tools', () {
    Future<TranslateHarness> open(
      WidgetTester tester, {
      PhrasebookRepository? repository,
    }) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(
        tester,
        size: const Size(400, 800),
        child: Align(
          alignment: Alignment.topRight,
          child: repository == null
              ? const MoreToolsButton()
              : RepositoryProvider<PhrasebookRepository>.value(
                  value: repository,
                  child: const MoreToolsButton(),
                ),
        ),
      );
      await tester.tap(find.byKey(const Key('translate_more_tools')));
      await tester.pumpAndSettle();
      return harness;
    }

    testWidgets('opens the phrasebook where there is one', (tester) async {
      final harness = await open(tester, repository: createPhrasebook());
      final tool = find.byKey(const ValueKey('translate_tool_phrasebook'));
      expect(tool, findsOneWidget);
      expect(find.text('Phrasebook'), findsOneWidget);
      await tester.tap(tool);
      await tester.pumpAndSettle();
      verify(
        () => harness.router.push<void>(
          '/phrasebook',
          extra: any(named: 'extra'),
        ),
      ).called(1);
    });

    testWidgets('has no entry without one', (tester) async {
      await open(tester);
      expect(
        find.byKey(const ValueKey('translate_tool_phrasebook')),
        findsNothing,
      );
    });
  });

  group('Delete all local data', () {
    testWidgets('counts the collections and deletes the phrasebook', (
      tester,
    ) async {
      final repository = createPhrasebook();
      await repository.createCollection('Lisbon');
      await repository.createCollection('Porto');
      final history = settings_helpers.createHistoryCubit();
      when(history.deleteAll).thenAnswer((_) async {});
      final settings = settings_helpers.createSettingsCubit();
      final eraser = LocalDataEraser(
        history: history,
        settings: settings,
        phrasebook: repository,
      );
      final summary = await eraser.summarize();
      expect(summary.phrasebookCollections, 2);
      await tester.pumpPhrasebook(DeleteLocalDataDialog(summary: summary));
      expect(
        find.text('2 phrasebook collections and the starter phrasebooks'),
        findsOneWidget,
      );
      await eraser.erase();
      expect(await repository.collections(), hasLength(1));
    });

    test('a phrasebook that cannot be read counts as none', () async {
      final history = settings_helpers.createHistoryCubit();
      final eraser = LocalDataEraser(
        history: history,
        settings: settings_helpers.createSettingsCubit(),
        phrasebook: _UnreadablePhrasebook(),
      );
      expect((await eraser.summarize()).phrasebookCollections, 0);
    });
  });
}

class _UnreadablePhrasebook extends Mock implements PhrasebookRepository {
  @override
  Future<List<PhraseCollection>> collections() async =>
      throw const PhrasebookUnreadableException(keyMissing: true);
}
