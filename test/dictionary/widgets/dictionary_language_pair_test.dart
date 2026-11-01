import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/dictionary/cubit/dictionary_cubit.dart';
import 'package:mozhi/dictionary/widgets/dictionary_composer.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/dictionary_helpers.dart';

void main() {
  group('DictionaryLanguagePair', () {
    Future<void> pumpPair(
      WidgetTester tester, {
      required double width,
      Language source = Language.auto,
      Language target = french,
      Locale locale = const Locale('de'),
    }) async {
      final cubit = MockDictionaryCubit();
      when(() => cubit.state)
          .thenReturn(DictionaryState(source: source, target: target));
      tester.view
        ..physicalSize = const Size(800, 844)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          locale: locale,
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: BlocProvider<DictionaryCubit>.value(
              value: cubit,
              child: Center(
                child: SizedBox(
                  width: width,
                  child: const DictionaryLanguagePair(),
                ),
              ),
            ),
          ),
        ),
      );
    }

    Finder inButton(String key, Finder finder) =>
        find.descendant(of: find.byKey(Key(key)), matching: finder);

    void expectNothingCut(WidgetTester tester) {
      for (final paragraph in tester.renderObjectList<RenderParagraph>(
        find.descendant(
          of: find.byKey(const Key('dictionary_language_pair')),
          matching: find.byType(RichText),
        ),
      )) {
        expect(paragraph.didExceedMaxLines, isFalse);
        expect(
          paragraph.size.width,
          lessThanOrEqualTo(paragraph.textSize.width + 0.01),
        );
      }
    }

    testWidgets('shows the names in full where they fit', (tester) async {
      await pumpPair(tester, width: 600);
      expect(
        inButton('dictionary_bar_source', find.text('Sprache erkennen')),
        findsOneWidget,
      );
      expect(
        inButton('dictionary_bar_target', find.text('Französisch')),
        findsOneWidget,
      );
      expectNothingCut(tester);
    });

    testWidgets('shortens to "Auto" and the code instead of cutting names', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      // About the composer's bar on a 390 dp phone, in the (wide) test
      // font.
      await pumpPair(tester, width: 250);

      expect(find.textContaining('Sprache'), findsNothing);
      expect(
        inButton('dictionary_bar_source', find.text('Auto')),
        findsOneWidget,
      );
      expect(
        inButton(
          'dictionary_bar_source',
          find.byIcon(Icons.auto_awesome_outlined),
        ),
        findsOneWidget,
      );
      expect(inButton('dictionary_bar_target', find.text('FR')), findsOne);
      expectNothingCut(tester);
      // Screen readers still hear the whole names.
      expect(find.bySemanticsLabel('Französisch'), findsNothing);
      expect(find.bySemanticsLabel(RegExp('Französisch')), findsOneWidget);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    });

    testWidgets('names a chosen source language', (tester) async {
      await pumpPair(tester, width: 600, source: spanish);

      expect(
        inButton('dictionary_bar_source', find.text('Spanisch')),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.auto_awesome_outlined), findsNothing);
    });
  });
}
