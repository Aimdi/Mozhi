import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/gen/app_localizations_en.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';
import 'output_stubs.dart';

const _arabic = Language(code: 'ar', name: 'Arabic', nativeName: 'العربية');

/// "Hello world" -> French on DeepL, with German and Japanese as extra
/// targets.
TranslateState _state({
  List<Language> extraTargets = const [german, japanese],
  List<ExtraTranslation> translations = const [],
  String input = 'Hello world',
}) =>
    translatedState(input: input)
        .copyWith(extraTargets: extraTargets, extraTranslations: translations);

ExtraTranslation _german({
  TranslateStatus status = TranslateStatus.success,
  String text = 'Hallo Welt',
  bool complete = true,
  String madeFor = 'Hello world',
  Object? error,
}) => ExtraTranslation(
  target: german,
  status: status,
  result: text.isEmpty
      ? null
      : TranslationResult(
          engineId: deepl.id,
          engineName: deepl.name,
          text: text,
          isComplete: complete,
        ),
  request: TranslationRequest(
    text: madeFor,
    source: Language.auto,
    target: german,
  ),
  engineId: deepl.id,
  error: error,
);

ExtraTranslation _japanese({
  TranslateStatus status = TranslateStatus.success,
  String text = 'こんにちは世界',
  Object? error,
}) => ExtraTranslation(
  target: japanese,
  status: status,
  result: text.isEmpty
      ? null
      : TranslationResult(
          engineId: deepl.id,
          engineName: deepl.name,
          text: text,
        ),
  request: const TranslationRequest(
    text: 'Hello world',
    source: Language.auto,
    target: japanese,
  ),
  engineId: deepl.id,
  error: error,
);

/// English with a Japanese list separator.
class _SeparatorL10n extends AppLocalizationsEn {
  @override
  String get translateExtraTargetsListSeparator => '、';
}

class _SeparatorL10nDelegate extends LocalizationsDelegate<AppLocalizations> {
  const new();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<AppLocalizations> load(Locale locale) =>
      SynchronousFuture(_SeparatorL10n());

  @override
  bool shouldReload(_SeparatorL10nDelegate old) => false;
}

TranslateHarness _harness(TranslateState state) {
  final harness = TranslateHarness(state: state);
  stubOutputExtras(harness);
  when(() => harness.translate.retryExtraTarget(any()))
      .thenAnswer((_) async {});
  return harness;
}

Finder _card(Language language) =>
    find.byKey(ValueKey('translate_extra_target_${language.code}'));

Finder _inCard(Language language, Finder matching) =>
    find.descendant(of: _card(language), matching: matching);

/// The scroll view of the open [ExtraTargetsSheet].
Finder _sheetScrollable() => find
    .descendant(
      of: find.byKey(const Key('translate_extra_targets_list')),
      matching: find.byType(Scrollable),
    )
    .first;

Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('translate_extra_targets_button')));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(registerOutputFallbacks);

  group('ExtraTargetsSection', () {
    testWidgets('offers "Also translate into…"', (tester) async {
      await _harness(_state(extraTargets: const []))
          .pump(tester, child: const ExtraTargetsSection());
      expect(find.text('Also translate into…'), findsOneWidget);
      expect(find.byType(ExtraTargetCard), findsNothing);
    });

    testWidgets('without the picker shows only the chosen languages', (
      tester,
    ) async {
      await _harness(_state())
          .pump(tester, child: const ExtraTargetsSection(showPicker: false));
      expect(
        find.byKey(const Key('translate_extra_targets_button')),
        findsNothing,
      );
      expect(_card(german), findsOneWidget);
      expect(_card(japanese), findsOneWidget);
    });

    testWidgets('without the picker or languages shows nothing', (
      tester,
    ) async {
      await _harness(_state(extraTargets: const []))
          .pump(tester, child: const ExtraTargetsSection(showPicker: false));
      expect(find.byType(Hairline), findsNothing);
      expect(find.byType(TextButton), findsNothing);
    });

    testWidgets('is hidden without an engine', (tester) async {
      await _harness(_state().copyWith(engine: () => null))
          .pump(tester, child: const ExtraTargetsSection());
      expect(
        find.byKey(const Key('translate_extra_targets_button')),
        findsNothing,
      );
    });

    testWidgets('names the chosen languages and shows a card for each', (
      tester,
    ) async {
      await _harness(_state()).pump(tester, child: const ExtraTargetsSection());
      expect(
        find.text('Also into: \u2068German\u2069, \u2068Japanese\u2069'),
        findsOneWidget,
      );
      expect(_card(german), findsOneWidget);
      expect(_card(japanese), findsOneWidget);
      // Not translated yet.
      expect(_inCard(german, find.text('Not translated yet')), findsOneWidget);
      expect(
        _inCard(german, find.byKey(const Key('translate_extra_target_copy'))),
        findsNothing,
      );
    });

    testWidgets('lists the languages with the separator of the UI language', (
      tester,
    ) async {
      final harness = _harness(_state());
      await tester.pumpWidget(
        BlocProvider<TranslateCubit>.value(
          value: harness.translate,
          child: const MaterialApp(
            localizationsDelegates: [
              _SeparatorL10nDelegate(),
              ...GlobalMaterialLocalizations.delegates,
            ],
            home: Scaffold(
              body: SingleChildScrollView(child: ExtraTargetsSection()),
            ),
          ),
        ),
      );
      expect(
        find.text('Also into: \u2068German\u2069、\u2068Japanese\u2069'),
        findsOneWidget,
      );
    });

    testWidgets('shows no cards without input', (tester) async {
      await _harness(_state(input: ''))
          .pump(tester, child: const ExtraTargetsSection());
      expect(find.textContaining('Also into:'), findsOneWidget);
      expect(find.byType(ExtraTargetCard), findsNothing);
    });

    testWidgets('leaves out the main target', (tester) async {
      await _harness(_state(extraTargets: const [french, german]))
          .pump(tester, child: const ExtraTargetsSection());
      expect(find.byType(ExtraTargetCard), findsOneWidget);
      expect(_card(french), findsNothing);
    });

    testWidgets('shows progress while translating', (tester) async {
      await _harness(
        _state(
          translations: [
            _german(status: TranslateStatus.translating, text: ''),
          ],
        ),
      ).pump(tester, child: const ExtraTargetsSection());
      expect(
        _inCard(german, find.byType(LinearProgressIndicator)),
        findsOneWidget,
      );
      expect(_inCard(german, find.text('Translating…')), findsOneWidget);
    });

    testWidgets('streams partial text', (tester) async {
      await _harness(
        _state(
          translations: [
            _german(
              status: TranslateStatus.translating,
              text: 'Hallo',
              complete: false,
            ),
          ],
        ),
      ).pump(tester, child: const ExtraTargetsSection());
      expect(_inCard(german, find.text('Hallo')), findsOneWidget);
      final insert = tester.widget<IconButton>(
        _inCard(german, find.byKey(const Key('translate_extra_target_insert'))),
      );
      expect(insert.onPressed, isNull);
    });

    testWidgets('shows a finished translation in its language', (tester) async {
      await _harness(_state(translations: [_german()]))
          .pump(tester, child: const ExtraTargetsSection());
      final text = tester.widget<SelectableText>(
        _inCard(german, find.byKey(const Key('translate_extra_target_text'))),
      );
      expect(text.textSpan?.toPlainText(), 'Hallo Welt');
      expect(text.textSpan?.locale, const Locale('de'));
      expect(text.textDirection, TextDirection.ltr);
      final opacity = tester.widget<Opacity>(
        find.ancestor(
          of: _inCard(
            german,
            find.byKey(const Key('translate_extra_target_text')),
          ),
          matching: find.byType(Opacity),
        ),
      );
      expect(opacity.opacity, 1);
    });

    testWidgets('dims a translation of text that was edited since', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _harness(_state(translations: [_german(madeFor: 'Hello')]))
          .pump(tester, child: const ExtraTargetsSection());
      final opacity = tester.widget<Opacity>(
        find.ancestor(
          of: _inCard(
            german,
            find.byKey(const Key('translate_extra_target_text')),
          ),
          matching: find.byType(Opacity),
        ),
      );
      expect(opacity.opacity, staleOutputOpacity);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.hint == 'Out of date — translate again',
        ),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('a right-to-left language reads right to left', (tester) async {
      const arabicTranslation = ExtraTranslation(
        target: _arabic,
        status: TranslateStatus.success,
        result: TranslationResult(
          engineId: 'mozhi:deepl',
          engineName: 'DeepL',
          text: 'مرحبا بالعالم',
        ),
        request: TranslationRequest(
          text: 'Hello world',
          source: Language.auto,
          target: _arabic,
        ),
      );
      await _harness(
        _state(
          extraTargets: const [_arabic],
          translations: const [arabicTranslation],
        ).copyWith(targetLanguages: const [...languages, _arabic]),
      ).pump(tester, child: const ExtraTargetsSection());
      final text = tester.widget<SelectableText>(
        _inCard(_arabic, find.byKey(const Key('translate_extra_target_text'))),
      );
      expect(text.textDirection, TextDirection.rtl);
      expect(text.textSpan?.locale, const Locale('ar'));
    });

    testWidgets('a custom language follows the direction of its text', (
      tester,
    ) async {
      const pirate = Language.custom('Pirate speak');
      const translation = ExtraTranslation(
        target: pirate,
        status: TranslateStatus.success,
        result: TranslationResult(
          engineId: 'ai:claude',
          engineName: 'Claude',
          text: 'Ahoy, world',
        ),
        request: TranslationRequest(
          text: 'Hello world',
          source: Language.auto,
          target: pirate,
        ),
      );
      await _harness(
        translatedState(engine: claude).copyWith(
          extraTargets: const [pirate],
          extraTranslations: const [translation],
        ),
      ).pump(tester, child: const ExtraTargetsSection());
      final text = tester.widget<SelectableText>(
        find.byKey(const Key('translate_extra_target_text')),
      );
      expect(text.textDirection, TextDirection.ltr);
      expect(text.textSpan?.locale, isNull);
      final listen = tester.widget<IconButton>(
        find.descendant(
          of: find.byType(ListenButton),
          matching: find.byType(IconButton),
        ),
      );
      expect(listen.onPressed, isNull);
    });

    testWidgets('follows the input, the languages and the engine', (
      tester,
    ) async {
      final initial = _state(translations: [_german()]);
      final harness = _harness(initial);
      final controller = StreamController<TranslateState>();
      addTearDown(controller.close);
      whenListen(harness.translate, controller.stream, initialState: initial);
      await harness.pump(tester, child: const ExtraTargetsSection());
      expect(_card(japanese), findsOneWidget);
      // The input changes: the German translation is out of date.
      final edited = initial.copyWith(input: 'Hello there');
      controller.add(edited);
      await tester.pump();
      await tester.pump();
      final opacity = tester.widget<Opacity>(
        find.ancestor(
          of: _inCard(
            german,
            find.byKey(const Key('translate_extra_target_text')),
          ),
          matching: find.byType(Opacity),
        ),
      );
      expect(opacity.opacity, staleOutputOpacity);
      // Japanese becomes the source.
      final source = edited.copyWith(source: japanese);
      controller.add(source);
      await tester.pump();
      await tester.pump();
      expect(_card(japanese), findsNothing);
      // German becomes the target.
      final target = source.copyWith(target: german);
      controller.add(target);
      await tester.pump();
      await tester.pump();
      expect(_card(german), findsNothing);
      // An engine without German.
      final lists = target.copyWith(
        target: french,
        targetLanguages: const [english, french],
      );
      controller.add(lists);
      await tester.pump();
      await tester.pump();
      expect(find.byType(ExtraTargetCard), findsNothing);
      controller.add(lists.copyWith(engine: () => null));
      await tester.pump();
      await tester.pump();
      expect(
        find.byKey(const Key('translate_extra_targets_button')),
        findsNothing,
      );
    });

    testWidgets('copies and reads aloud a translation, naming its language', (
      tester,
    ) async {
      final clipboard = FakeClipboard(tester);
      final harness = _harness(_state(translations: [_german()]));
      await harness.pump(tester, child: const ExtraTargetsSection());
      await tester.tap(
        _inCard(german, find.byTooltip('Copy \u2068German\u2069')),
      );
      await tester.pump();
      expect(clipboard.copied, 'Hallo Welt');
      await tester.tap(
        _inCard(german, findListenTooltip('Listen to \u2068German\u2069')),
      );
      verify(
        () => harness.speech.toggle(
          id: 'extra:de',
          text: 'Hallo Welt',
          languageCode: 'de',
        ),
      ).called(1);
      // Nothing is called just "Copy" or "Listen" twice on the screen.
      expect(find.byTooltip('Copy'), findsNothing);
      expect(findListenTooltip('Listen'), findsNothing);
      expect(
        find.bySemanticsLabel('Listen to \u2068German\u2069'),
        findsOneWidget,
      );
    });

    testWidgets('names the language while reading it aloud', (tester) async {
      final harness = _harness(_state(translations: [_german()]));
      when(() => harness.speech.current).thenReturn('extra:de');
      await harness.pump(tester, child: const ExtraTargetsSection());
      expect(
        _inCard(
          german,
          findListenTooltip('Stop reading \u2068German\u2069 aloud'),
        ),
        findsOneWidget,
      );
    });

    group('use as input', () {
      Finder button() => _inCard(
        german,
        find.byTooltip('Use the \u2068German\u2069 translation as input'),
      );

      testWidgets('says what changed and offers Undo', (tester) async {
        final initial = _state(translations: [_german()])
            .copyWith(source: english);
        final harness = _harness(initial);
        when(() => harness.translate.insertExtraTranslation(german)).thenAnswer(
          (_) => harness.setState(
            initial.copyWith(input: 'Hallo Welt', source: german),
          ),
        );
        await harness.pump(tester, child: const ExtraTargetsSection());
        await tester.tap(button());
        await tester.pumpAndSettle();
        verify(() => harness.translate.insertExtraTranslation(german))
            .called(1);
        expect(
          find.text(
            'Input replaced with the \u2068German\u2069 translation. '
            'Translating from \u2068German\u2069 now.',
          ),
          findsOneWidget,
        );
        await tester.tap(find.text('Undo'));
        verify(harness.translate.undoInsertExtraTranslation).called(1);
      });

      testWidgets('without a source change', (tester) async {
        final initial = _state(translations: [_german()]);
        final harness = _harness(initial);
        when(() => harness.translate.insertExtraTranslation(german)).thenAnswer(
          (_) => harness.setState(initial.copyWith(input: 'Hallo Welt')),
        );
        await harness.pump(tester, child: const ExtraTargetsSection());
        await tester.tap(button());
        await tester.pump();
        expect(
          find.text('Input replaced with the \u2068German\u2069 translation'),
          findsOneWidget,
        );
      });

      testWidgets('says nothing when nothing changed', (tester) async {
        final harness = _harness(_state(translations: [_german()]));
        await harness.pump(tester, child: const ExtraTargetsSection());
        await tester.tap(button());
        await tester.pump();
        verify(() => harness.translate.insertExtraTranslation(german))
            .called(1);
        expect(
          find.byKey(const Key('translate_extra_target_used_as_input')),
          findsNothing,
        );
      });
    });

    testWidgets('removes a language', (tester) async {
      final harness = _harness(_state(translations: [_german()]));
      await harness.pump(tester, child: const ExtraTargetsSection());
      await tester.tap(
        _inCard(german, find.byTooltip('Remove \u2068German\u2069')),
      );
      verify(() => harness.translate.toggleExtraTarget(german)).called(1);
    });

    testWidgets('shows failures with Retry', (tester) async {
      final harness = _harness(
        _state(
          translations: [
            _german(
              status: TranslateStatus.failure,
              text: '',
              error: Exception('offline'),
            ),
          ],
        ),
      );
      final handle = tester.ensureSemantics();
      await harness.pump(tester, child: const ExtraTargetsSection());
      expect(find.bySemanticsLabel('Retry \u2068German\u2069'), findsOneWidget);
      await tester.tap(_inCard(german, find.bySubtype<FilledButton>()));
      verify(() => harness.translate.retryExtraTarget(german)).called(1);
      handle.dispose();
    });

    testWidgets('announces the translations once none is in flight', (
      tester,
    ) async {
      final initial = _state(
        translations: [
          _german(status: TranslateStatus.translating, text: ''),
          _japanese(status: TranslateStatus.translating, text: ''),
        ],
      );
      final harness = _harness(initial);
      final controller = StreamController<TranslateState>();
      addTearDown(controller.close);
      whenListen(harness.translate, controller.stream, initialState: initial);
      await harness.pump(
        tester,
        child: const ExtraTargetsSection(),
        supportsAnnounce: true,
      );
      Future<void> emit(TranslateState state) async {
        controller.add(state);
        await tester.pump();
        await tester.pump();
      }

      // German arrives while Japanese is still in flight: nothing yet.
      await emit(
        _state(
          translations: [
            _german(),
            _japanese(status: TranslateStatus.translating, text: ''),
          ],
        ),
      );
      expect(tester.takeAnnouncements(), isEmpty);
      final done = _state(
        translations: [
          _german(),
          _japanese(
            status: TranslateStatus.failure,
            text: '',
            error: Exception('offline'),
          ),
        ],
      );
      await emit(done);
      expect(tester.takeAnnouncements(), [
        isAccessibilityAnnouncement(
          'Also translated into \u2068German\u2069. '
          'Could not translate into \u2068Japanese\u2069.',
        ),
      ]);
      // Removing a language announces nothing.
      await emit(done.copyWith(extraTargets: const [german]));
      expect(tester.takeAnnouncements(), isEmpty);
      // The next round is announced again, also when it reads the same.
      await emit(
        done.copyWith(
          extraTargets: const [german],
          extraTranslations: [
            _german(status: TranslateStatus.translating, text: ''),
          ],
        ),
      );
      await emit(
        done.copyWith(
          extraTargets: const [german],
          extraTranslations: [_german()],
        ),
      );
      expect(tester.takeAnnouncements(), [
        isAccessibilityAnnouncement('Also translated into \u2068German\u2069.'),
      ]);
      // Translations of text edited since are not announced.
      await emit(
        done.copyWith(
          input: 'Hello',
          extraTargets: const [german],
          extraTranslations: [
            _german(status: TranslateStatus.translating, text: ''),
          ],
        ),
      );
      await emit(
        done.copyWith(
          input: 'Hello',
          extraTargets: const [german],
          extraTranslations: [_german()],
        ),
      );
      expect(tester.takeAnnouncements(), isEmpty);
    });

    testWidgets('names each card for screen readers', (tester) async {
      final handle = tester.ensureSemantics();
      await _harness(_state(translations: [_german()]))
          .pump(tester, child: const ExtraTargetsSection());
      expect(
        find.bySemanticsLabel(RegExp('^Translation into German')),
        findsOneWidget,
      );
      handle.dispose();
    });

    for (final themeMode in [ThemeMode.light, ThemeMode.dark]) {
      testWidgets('meets the accessibility guidelines ($themeMode)', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await _harness(
          _state(
            translations: [
              _german(),
              const ExtraTranslation(
                target: japanese,
                status: TranslateStatus.failure,
              ),
            ],
          ),
        ).pump(
          tester,
          child: const ExtraTargetsSection(),
          themeMode: themeMode,
        );
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await expectLater(tester, meetsGuideline(textContrastGuideline));
        handle.dispose();
      });
    }

    testWidgets('fits at 200 % text on a phone', (tester) async {
      await _harness(_state(translations: [_german()])).pump(
        tester,
        child: const ExtraTargetsSection(),
        size: const Size(360, 800),
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('ExtraTargetsSheet', () {
    testWidgets('lists the target languages except the main target', (
      tester,
    ) async {
      final harness = _harness(_state(extraTargets: const [german]));
      await harness.pump(tester, child: const ExtraTargetsSection());
      await _openSheet(tester);
      expect(find.text('Also translate into'), findsOneWidget);
      expect(
        find.byKey(const Key('translate_extra_targets_hint')),
        findsOneWidget,
      );
      expect(find.textContaining('Pick up to 4 more languages.'), findsOne);
      final tiles = tester
          .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
          .toList();
      // Chosen languages first.
      expect(
        [for (final tile in tiles) tile.key],
        const [
          ValueKey('translate_extra_targets_de'),
          ValueKey('translate_extra_targets_en'),
          ValueKey('translate_extra_targets_ja'),
        ],
      );
      expect([for (final tile in tiles) tile.value], [true, false, false]);
      expect(find.text('Deutsch'), findsOneWidget);
      // English has no other native name.
      expect(find.text('English'), findsOneWidget);
    });

    testWidgets('toggles languages', (tester) async {
      final harness = _harness(_state(extraTargets: const [german]));
      await harness.pump(tester, child: const ExtraTargetsSection());
      await _openSheet(tester);
      await tester.tap(
        find.byKey(const ValueKey('translate_extra_targets_ja')),
      );
      verify(() => harness.translate.toggleExtraTarget(japanese)).called(1);
      await tester.tap(
        find.byKey(const ValueKey('translate_extra_targets_de')),
      );
      verify(() => harness.translate.toggleExtraTarget(german)).called(1);
    });

    testWidgets('takes no more than four languages', (tester) async {
      const swedish = Language(code: 'sv', name: 'Swedish');
      const italian = Language(code: 'it', name: 'Italian');
      const dutch = Language(code: 'nl', name: 'Dutch');
      final harness = _harness(
        _state(extraTargets: const [german, swedish, italian, dutch]).copyWith(
          targetLanguages: const [...languages, swedish, italian, dutch],
        ),
      );
      final handle = tester.ensureSemantics();
      await harness.pump(tester, child: const ExtraTargetsSection());
      await _openSheet(tester);
      // Said under the list, where the disabled rows are.
      expect(
        find.byKey(const Key('translate_extra_targets_limit')),
        findsOneWidget,
      );
      expect(
        find.text('Remove a language to pick another one.'),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('translate_extra_targets_ja')),
        100,
        scrollable: _sheetScrollable(),
      );
      final japaneseTile = tester.widget<CheckboxListTile>(
        find.byKey(const ValueKey('translate_extra_targets_ja')),
      );
      expect(japaneseTile.onChanged, isNull);
      // ...and to screen readers on each disabled row.
      expect(
        tester.getSemantics(
          find.byKey(const ValueKey('translate_extra_targets_ja')),
        ),
        isSemantics(
          label: 'Japanese\n日本語',
          hint: 'Remove a language to pick another one.',
          isEnabled: false,
        ),
      );
      final germanTile = tester.widget<CheckboxListTile>(
        find.byKey(const ValueKey('translate_extra_targets_de')),
      );
      expect(germanTile.onChanged, isNotNull);
      expect(
        tester
            .getSemantics(
              find.byKey(const ValueKey('translate_extra_targets_de')),
            )
            .hint,
        isEmpty,
      );
      handle.dispose();
    });

    testWidgets('announces when the most languages are picked', (tester) async {
      const swedish = Language(code: 'sv', name: 'Swedish');
      const italian = Language(code: 'it', name: 'Italian');
      final initial = _state(extraTargets: const [german, swedish, italian])
          .copyWith(targetLanguages: const [...languages, swedish, italian]);
      final harness = _harness(initial);
      final controller = StreamController<TranslateState>();
      addTearDown(controller.close);
      whenListen(harness.translate, controller.stream, initialState: initial);
      await harness.pump(
        tester,
        child: const ExtraTargetsSection(),
        supportsAnnounce: true,
      );
      await _openSheet(tester);
      expect(
        find.byKey(const Key('translate_extra_targets_limit')),
        findsNothing,
      );
      final full = initial.copyWith(
        extraTargets: const [german, swedish, italian, english],
      );
      when(() => harness.translate.state).thenReturn(full);
      controller.add(full);
      await tester.pump();
      await tester.pump();
      expect(
        find.byKey(const Key('translate_extra_targets_limit')),
        findsOneWidget,
      );
      expect(tester.takeAnnouncements(), [
        isAccessibilityAnnouncement('Remove a language to pick another one.'),
      ]);
    });

    for (final size in [const Size(320, 568), const Size(568, 320)]) {
      testWidgets('keeps the languages reachable at 200 % text ($size)', (
        tester,
      ) async {
        final harness = _harness(_state(extraTargets: const [german]));
        await harness.pump(
          tester,
          child: const ExtraTargetsSection(),
          size: size,
          textScale: 2,
        );
        await _openSheet(tester);
        expect(tester.takeException(), isNull);
        final list = find.byKey(const Key('translate_extra_targets_list'));
        expect(tester.getSize(list).height, greaterThan(size.height / 3));
        final row = find.byKey(const ValueKey('translate_extra_targets_ja'));
        await tester.scrollUntilVisible(
          row,
          100,
          scrollable: _sheetScrollable(),
        );
        await tester.ensureVisible(row);
        await tester.pumpAndSettle();
        await tester.tap(row);
        verify(() => harness.translate.toggleExtraTarget(japanese)).called(1);
        // The actions are reachable too.
        final done = find.byKey(const Key('translate_extra_targets_done'));
        await tester.scrollUntilVisible(
          done,
          -100,
          scrollable: _sheetScrollable(),
        );
        await tester.ensureVisible(done);
        await tester.pumpAndSettle();
        await tester.tap(done);
        await tester.pumpAndSettle();
        expect(find.byType(ExtraTargetsSheet), findsNothing);
      });
    }

    testWidgets('searches by name, native name and code', (tester) async {
      final harness = _harness(_state(extraTargets: const []));
      await harness.pump(tester, child: const ExtraTargetsSection());
      await _openSheet(tester);
      final search = find.byKey(const Key('translate_extra_targets_search'));
      await tester.enterText(search, 'jap');
      await tester.pump();
      expect(find.byType(CheckboxListTile), findsOneWidget);
      await tester.enterText(search, 'deutsch');
      await tester.pump();
      expect(
        find.byKey(const ValueKey('translate_extra_targets_de')),
        findsOneWidget,
      );
      await tester.enterText(search, 'EN');
      await tester.pump();
      expect(
        find.byKey(const ValueKey('translate_extra_targets_en')),
        findsOneWidget,
      );
      await tester.enterText(search, 'zzz');
      await tester.pump();
      expect(
        find.byKey(const Key('translate_extra_targets_no_results')),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Clear'));
      await tester.pump();
      expect(find.byType(CheckboxListTile), findsNWidgets(3));
    });

    testWidgets('removes all languages and closes', (tester) async {
      final harness = _harness(_state());
      await harness.pump(tester, child: const ExtraTargetsSection());
      await _openSheet(tester);
      await tester.tap(find.byKey(const Key('translate_extra_targets_clear')));
      verify(() => harness.translate.setExtraTargets(const [])).called(1);
      await tester.tap(find.byKey(const Key('translate_extra_targets_done')));
      await tester.pumpAndSettle();
      expect(find.byType(ExtraTargetsSheet), findsNothing);
    });

    group('picks the engine does not offer', () {
      const thai = Language(code: 'th', name: 'Thai', nativeName: 'ไทย');
      const pirate = Language.custom('Pirate speak');
      const kept = 'Not offered by this engine; kept for one that does';

      testWidgets('are listed checked after the others, as kept', (
        tester,
      ) async {
        final harness = _harness(
          _state(extraTargets: const [thai, german, pirate]),
        );
        await harness.pump(tester, child: const ExtraTargetsSection());
        // Nothing to translate into with this engine but German.
        expect(find.text('Also into: \u2068German\u2069'), findsOneWidget);
        await _openSheet(tester);
        // The rows built first (the list is built lazily).
        final tiles = tester
            .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
            .take(4)
            .toList();
        expect(
          [for (final tile in tiles) tile.key],
          const [
            ValueKey('translate_extra_targets_de'),
            ValueKey('translate_extra_targets_th'),
            ValueKey('translate_extra_targets_Pirate speak'),
            ValueKey('translate_extra_targets_en'),
          ],
        );
        expect(
          [for (final tile in tiles) tile.value],
          [true, true, true, false],
        );
        expect(find.text(kept), findsNWidgets(2));
        // Unchecking one removes it.
        await tester.tap(
          find.byKey(const ValueKey('translate_extra_targets_th')),
        );
        verify(() => harness.translate.toggleExtraTarget(thai)).called(1);
      });

      testWidgets('are found by the search', (tester) async {
        final harness = _harness(_state(extraTargets: const [thai]));
        await harness.pump(tester, child: const ExtraTargetsSection());
        await _openSheet(tester);
        await tester.enterText(
          find.byKey(const Key('translate_extra_targets_search')),
          'ไท',
        );
        await tester.pump();
        expect(find.byType(CheckboxListTile), findsOneWidget);
        expect(find.text(kept), findsOneWidget);
      });

      testWidgets('are removed by "Remove all"', (tester) async {
        final harness = _harness(_state(extraTargets: const [thai]));
        await harness.pump(tester, child: const ExtraTargetsSection());
        expect(find.text('Also translate into…'), findsOneWidget);
        await _openSheet(tester);
        await tester.tap(
          find.byKey(const Key('translate_extra_targets_clear')),
        );
        verify(() => harness.translate.setExtraTargets(const [])).called(1);
      });

      testWidgets('count towards the limit', (tester) async {
        final harness = _harness(
          _state(extraTargets: const [thai, german, pirate, english]),
        );
        await harness.pump(tester, child: const ExtraTargetsSection());
        await _openSheet(tester);
        expect(
          find.byKey(const Key('translate_extra_targets_limit')),
          findsOneWidget,
        );
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('translate_extra_targets_ja')),
          100,
          scrollable: _sheetScrollable(),
        );
        expect(
          tester
              .widget<CheckboxListTile>(
                find.byKey(const ValueKey('translate_extra_targets_ja')),
              )
              .onChanged,
          isNull,
        );
        expect(
          tester
              .widget<CheckboxListTile>(
                find.byKey(const ValueKey('translate_extra_targets_th')),
              )
              .onChanged,
          isNotNull,
        );
      });

      testWidgets('meet the accessibility guidelines', (tester) async {
        final handle = tester.ensureSemantics();
        await _harness(_state(extraTargets: const [thai, german]))
            .pump(tester, child: const ExtraTargetsSection());
        await _openSheet(tester);
        expect(
          tester.getSemantics(
            find.byKey(const ValueKey('translate_extra_targets_th')),
          ),
          isSemantics(label: 'Thai\n$kept', isChecked: true, isEnabled: true),
        );
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        handle.dispose();
      });
    });

    testWidgets('offers no "Remove all" without languages', (tester) async {
      await _harness(_state(extraTargets: const []))
          .pump(tester, child: const ExtraTargetsSection());
      await _openSheet(tester);
      expect(
        find.byKey(const Key('translate_extra_targets_clear')),
        findsNothing,
      );
    });

    testWidgets('meets the accessibility guidelines', (tester) async {
      final handle = tester.ensureSemantics();
      await _harness(_state(extraTargets: const [german]))
          .pump(tester, child: const ExtraTargetsSection());
      await _openSheet(tester);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      handle.dispose();
    });
  });

  group('TranslateView', () {
    testWidgets('shows the extra targets under the translation', (
      tester,
    ) async {
      await _harness(_state(translations: [_german()])).pump(tester);
      expect(find.byType(ExtraTargetsSection), findsOneWidget);
      expect(_card(german), findsOneWidget);
    });
  });
}
