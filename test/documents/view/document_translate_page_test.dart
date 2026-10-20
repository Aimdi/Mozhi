import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/widgets/composer_card.dart';
import 'package:mozhi/core/widgets/language_pair_bar.dart';
import 'package:mozhi/core/widgets/tab_hero.dart';
import 'package:mozhi/documents/documents.dart';
import 'package:mozhi/documents/widgets/widgets.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../helpers/helpers.dart';
import '../helpers/fakes.dart';

void main() {
  late MockTranslateCubit translateCubit;
  late MockTranslationRepository repository;
  late FakeDocumentFileService files;
  late List<TranslationRequest> requests;

  setUpAll(registerDocumentFallbacks);

  setUp(() {
    translateCubit = MockTranslateCubit();
    repository = MockTranslationRepository();
    files = FakeDocumentFileService();
    requests = [];
    stubTranslate(repository, requests: requests);
    stubLanguages(repository);
  });

  Future<void> pumpPage(
    WidgetTester tester, {
    TranslateState state = readyTranslateState,
    Stream<TranslateState>? stream,
    Size size = const Size(600, 3000),
    PickedFile? initialFile,
    String? initialText,
    SettingsCubit? settings,
  }) async {
    setSurface(tester, size);
    whenListen(
      translateCubit,
      stream ?? const Stream<TranslateState>.empty(),
      initialState: state,
    );
    await tester.pumpDocuments(
      translateCubit: translateCubit,
      repository: repository,
      files: files,
      initialFile: initialFile,
      initialText: initialText,
      settings: settings,
      translator: DocumentTranslator(
        repository: repository,
        maxAttempts: 1,
        retryDelay: Duration.zero,
      ),
    );
  }

  DocumentTranslateCubit cubitOf(WidgetTester tester) =>
      tester.element(find.byType(DocumentTranslateView)).read();

  Future<void> pickFile(WidgetTester tester, String name, String text) async {
    files.pickResult = PickedFile(name: name, bytes: bytesOf(text));
    final pick = find.byKey(const Key('documents_pick_file'));
    await tester.tap(
      pick.evaluate().isEmpty
          ? find.byKey(const Key('documents_replace_file'))
          : pick,
    );
    await tester.pumpAndSettle();
  }

  group('DocumentTranslatePage', () {
    testWidgets('starts from the translate screen settings', (tester) async {
      await pumpPage(tester);
      expect(find.text('Translate documents'), findsOneWidget);
      expect(find.text('Pick a document'), findsOneWidget);
      // The tabs' empty state: an accent icon over a bold headline.
      expect(
        find.descendant(
          of: find.byType(TabHero),
          matching: find.text('Pick a document'),
        ),
        findsOneWidget,
      );
      final headline = tester.widget<Text>(find.text('Pick a document'));
      expect(headline.style?.fontWeight, FontWeight.w800);
      // The languages in the translate screen's language bar.
      expect(
        find.descendant(
          of: find.byType(LanguagePairBar),
          matching: find.byKey(const Key('documents_target_language')),
        ),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Translate into German'), findsOneWidget);
      expect(find.bySemanticsLabel('Translate from Detect language'), findsOne);
      final state = cubitOf(tester).state;
      expect(state.engine, googleEngine);
      expect(state.target, german);
      expect(find.text('Google · mozhi.example'), findsOneWidget);
      expect(find.text('Detect language'), findsOneWidget);
      expect(find.text('German'), findsOneWidget);
      // The go button ends the language bar, disabled without a document.
      final translate = tester.widget<ComposerGoButton>(
        find.byKey(const Key('documents_translate')),
      );
      expect(translate.onPressed, isNull);
      expect(translate.label, 'Translate');
      expect(
        find.descendant(
          of: find.byType(LanguagePairBar),
          matching: find.byKey(const Key('documents_translate')),
        ),
        findsOneWidget,
      );
    });

    testWidgets('opens an initial file or text', (tester) async {
      await pumpPage(
        tester,
        initialFile: PickedFile(name: 'shared.vtt', bytes: bytesOf('WEBVTT')),
        initialText: 'ignored',
      );
      expect(find.text('shared.vtt'), findsOneWidget);
      expect(cubitOf(tester).state.format, DocumentFormat.vtt);
    });

    testWidgets('large text moves Replace below the file name', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpPage(
        tester,
        size: const Size(320, 3000),
        initialFile: PickedFile(name: 'movie.en.srt', bytes: bytesOf(srtText)),
      );
      expect(tester.takeException(), isNull);
      final name = find.byKey(const Key('documents_file_name'));
      final replace = find.byKey(const Key('documents_replace_file'));
      expect(
        tester.getTopLeft(replace).dy,
        greaterThan(tester.getBottomLeft(name).dy),
      );
      // The name keeps its line instead of breaking letter by letter.
      expect(tester.getSize(name).height, lessThan(2 * 2 * 17 * 1.5));
    });

    testWidgets('opens initial text in text mode', (tester) async {
      await pumpPage(tester, initialText: 'Some long text');
      expect(cubitOf(tester).state.mode, DocumentInputMode.text);
      final field = tester.widget<TextField>(
        find.byKey(const Key('documents_text_field')),
      );
      expect(field.controller!.text, 'Some long text');
    });

    testWidgets('shows a hint when no engine is available', (tester) async {
      await pumpPage(tester, state: const TranslateState());
      expect(find.byKey(const Key('documents_no_engines')), findsOneWidget);
    });

    testWidgets('follows engines that load later', (tester) async {
      final controller = StreamController<TranslateState>();
      addTearDown(controller.close);
      await pumpPage(
        tester,
        state: const TranslateState(enginesStatus: EnginesStatus.loading),
        stream: controller.stream,
      );
      expect(cubitOf(tester).state.engine, isNull);
      controller.add(readyTranslateState);
      await tester.pumpAndSettle();
      expect(cubitOf(tester).state.engine, googleEngine);
      expect(cubitOf(tester).state.targetLanguages, targetLanguages);

      // Options-only changes are mirrored as well.
      controller.add(
        readyTranslateState.copyWith(
          options: const TranslationOptions(context: 'Film dialogue'),
        ),
      );
      await tester.pumpAndSettle();
      expect(cubitOf(tester).state.options.context, 'Film dialogue');
    });

    testWidgets('picks, translates and exports a subtitle file', (
      tester,
    ) async {
      await pumpPage(tester);
      await pickFile(tester, 'movie.en.srt', srtText);

      expect(find.byKey(const Key('documents_file_name')), findsOneWidget);
      expect(find.text('movie.en.srt'), findsOneWidget);
      expect(find.text('SubRip subtitles (SRT)'), findsOneWidget);
      expect(find.text('2 segments'), findsOneWidget);
      expect(find.text('1 request'), findsOneWidget);
      expect(find.text('Under a minute'), findsOneWidget);
      expect(find.textContaining('Hello there.'), findsOneWidget);

      await tester.tap(find.byKey(const Key('documents_translate')));
      await tester.pumpAndSettle();

      expect(find.text('Translation complete'), findsOneWidget);
      expect(
        tester
            .widget<ComposerGoButton>(
              find.byKey(const Key('documents_translate')),
            )
            .label,
        'Translate again',
      );
      expect(find.textContaining('HELLO THERE.'), findsOneWidget);
      expect(find.text('File name: movie.de.srt'), findsOneWidget);

      // Bilingual export for subtitles.
      await tester.tap(find.byKey(const Key('documents_bilingual')));
      await tester.pumpAndSettle();
      expect(cubitOf(tester).state.bilingual, isTrue);
      expect(find.textContaining('Hello there.\nHELLO THERE.'), findsOneWidget);

      await tester.tap(find.byKey(const Key('documents_copy')));
      await tester.pumpAndSettle();
      expect(find.text('Copied to clipboard'), findsOneWidget);
      expect(files.copied.single, contains('HELLO THERE.'));

      await tester.tap(find.byKey(const Key('documents_save')));
      await tester.pumpAndSettle();
      expect(find.text('File saved'), findsOneWidget);
      expect(files.saved.single.fileName, 'movie.de.srt');

      await tester.tap(find.byKey(const Key('documents_share')));
      await tester.pumpAndSettle();
      expect(files.shared.single.origin, isNotNull);

      // The original tab still shows the source.
      await tester.tap(find.text('Original'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('documents_preview_original')),
        findsOneWidget,
      );
    });

    testWidgets('hides sharing where files cannot be shared', (tester) async {
      files.shareSupported = false;
      await pumpPage(tester);
      await pickFile(tester, 'a.txt', 'hello');
      await tester.tap(find.byKey(const Key('documents_translate')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('documents_share')), findsNothing);
      expect(find.byKey(const Key('documents_save')), findsOneWidget);
      expect(find.byKey(const Key('documents_bilingual')), findsNothing);
    });

    testWidgets('shows notices for failed exports', (tester) async {
      files
        ..saveError = Exception('disk')
        ..shareError = const ShareUnsupportedException();
      await pumpPage(tester);
      await pickFile(tester, 'a.txt', 'hello');
      await tester.tap(find.byKey(const Key('documents_translate')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('documents_save')));
      await tester.pumpAndSettle();
      expect(find.text("Couldn't save the file."), findsOneWidget);

      await tester.tap(find.byKey(const Key('documents_share')));
      await tester.pumpAndSettle();
      expect(
        find.text(
          "Sharing files isn't supported on this device. Use Save instead.",
        ),
        findsOneWidget,
      );

      files.shareError = Exception('x');
      await tester.tap(find.byKey(const Key('documents_share')));
      await tester.pumpAndSettle();
      expect(find.text("Couldn't share the file."), findsOneWidget);
    });

    testWidgets('shows load errors', (tester) async {
      await pumpPage(tester);
      await pickFile(tester, 'photo.png', 'x');
      expect(find.byKey(const Key('documents_error')), findsOneWidget);
      expect(find.textContaining("isn't supported"), findsOneWidget);

      await pickFile(tester, 'bad.json', '{"a": ');
      expect(
        find.text(
          "This isn't valid JSON. Check the file or choose "
          'another format.',
        ),
        findsOneWidget,
      );

      await pickFile(tester, 'nums.json', '{"a": 1}');
      expect(
        find.text("There's nothing to translate in this document."),
        findsOneWidget,
      );

      files.pickError = Exception('denied');
      await tester.tap(find.byKey(const Key('documents_replace_file')));
      await tester.pumpAndSettle();
      expect(find.text("The file couldn't be read."), findsOneWidget);
    });

    testWidgets('shows size and binary errors', (tester) async {
      await pumpPage(tester);
      final cubit = cubitOf(tester)
        ..loadFile('b.txt', bytesOf('a${String.fromCharCode(0)}b'));
      await tester.pumpAndSettle();
      expect(find.text("This doesn't look like a text file."), findsOneWidget);

      cubit.loadFile('big.txt', bytesOf('x' * (2 * 1024 * 1024 + 1)));
      await tester.pumpAndSettle();
      expect(
        find.text('This file is too large. The limit is 2 MB.'),
        findsOneWidget,
      );
    });

    testWidgets('pasted text with format selection', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.text('Text'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('documents_text_field')),
        '# Title\n\nBody text',
      );
      await tester.pumpAndSettle();
      expect(find.text('Markdown'), findsOneWidget);
      expect(find.text('2 segments'), findsOneWidget);

      await tester.tap(find.byKey(const Key('documents_format')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('documents_format_plainText')));
      await tester.pumpAndSettle();
      expect(cubitOf(tester).state.format, DocumentFormat.plainText);
      expect(find.text('Plain text'), findsOneWidget);
    });

    testWidgets('paste button fills the text field', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.text('Text'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('documents_paste')));
      await tester.pumpAndSettle();
      expect(find.text('The clipboard has no text.'), findsOneWidget);

      files.clipboard = 'From the clipboard';
      await tester.tap(find.byKey(const Key('documents_paste')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('documents_text_field')))
            .controller!
            .text,
        'From the clipboard',
      );
    });

    testWidgets('lists failed parts and retries them', (tester) async {
      var failing = true;
      stubTranslate(
        repository,
        respond: (request) => failing
            ? Stream.error(const MozhiApiException('down'))
            : Stream.value(result(request.text.toUpperCase())),
      );
      await pumpPage(tester);
      await pickFile(tester, 'a.txt', 'hello');
      await tester.tap(find.byKey(const Key('documents_translate')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('documents_failures')), findsOneWidget);
      expect(find.text('Part 1'), findsOneWidget);
      expect(find.text("1 part isn't translated yet"), findsOneWidget);

      failing = false;
      await tester.tap(find.byTooltip('Retry part 1'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('documents_failures')), findsNothing);
      expect(find.text('Translation complete'), findsOneWidget);
    });

    group('privacy', () {
      const consent = ConsentRequiredException(
        kind: ConsentKind.pair,
        destination: PublicInstanceDestination(
          'mozhi.example',
          engine: 'google',
        ),
        engineId: 'mozhi:google',
        target: 'de',
      );

      late MockSettingsCubit settings;
      late bool refusing;

      setUp(() {
        settings = MockSettingsCubit();
        when(() => settings.state).thenReturn(const AppSettings());
        when(() => repository.instances).thenReturn(const []);
        refusing = true;
        stubTranslate(
          repository,
          respond: (request) => refusing
              ? Stream.error(consent)
              : Stream.value(result(request.text.toUpperCase())),
        );
        when(
          () => repository.allowOnce(consent, requests: any(named: 'requests')),
        ).thenAnswer((_) => refusing = false);
      });

      testWidgets('translating asks right away, then translates', (
        tester,
      ) async {
        await pumpPage(tester, settings: settings);
        await pickFile(tester, 'a.txt', 'hello');
        await tester.tap(find.byKey(const Key('documents_translate')));
        await tester.pumpAndSettle();
        expect(
          find.text('Send this text to Google via mozhi.example?'),
          findsOneWidget,
        );
        // The inline prompt waits behind the dialog.
        expect(find.byKey(const Key('documents_consent')), findsOneWidget);
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('Once'),
          ),
        );
        await tester.pumpAndSettle();
        verify(() => repository.allowOnce(consent)).called(1);
        expect(find.text('Translation complete'), findsOneWidget);
      });

      testWidgets('after Cancel, the parts wait for an inline answer', (
        tester,
      ) async {
        await pumpPage(tester, settings: settings);
        await pickFile(tester, 'a.txt', 'hello');
        await tester.tap(find.byKey(const Key('documents_translate')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('documents_consent')), findsOneWidget);
        expect(find.byKey(const Key('documents_failures')), findsNothing);
        await tester.tap(
          find.descendant(
            of: find.byKey(const Key('documents_consent')),
            matching: find.text('Once'),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Translation complete'), findsOneWidget);
      });
    });

    testWidgets('partial translations warn that parts stay original', (
      tester,
    ) async {
      stubTranslate(
        repository,
        respond: (request) => request.text.contains('bad')
            ? Stream.error(const MozhiApiException('down'))
            : Stream.value(result(request.text.toUpperCase())),
      );
      await pumpPage(tester);
      final good = List.filled(200, 'good').join(' ');
      final bad = List.filled(200, 'bad').join(' ');
      await pickFile(tester, 'a.txt', '$good\n\n$bad');
      expect(find.text('2 requests'), findsOneWidget);
      await tester.tap(find.byKey(const Key('documents_translate')));
      await tester.pumpAndSettle();
      expect(
        find.text('Untranslated parts keep the original text.'),
        findsOneWidget,
      );
      expect(find.text('Part 2'), findsOneWidget);
    });

    testWidgets('the translation tab explains where results appear', (
      tester,
    ) async {
      await pumpPage(tester);
      await pickFile(tester, 'a.txt', 'hello');
      await tester.tap(find.text('Translation'));
      await tester.pumpAndSettle();
      expect(find.text('The translation appears here.'), findsOneWidget);
    });

    testWidgets('shows a spinner while engine languages load', (tester) async {
      final gate = Completer<List<Language>>();
      await pumpPage(tester);
      when(() => repository.getSourceLanguages(deeplEngine))
          .thenAnswer((_) => gate.future);
      await tester.tap(find.byKey(const Key('documents_engine')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('documents_engine_mozhi:deepl')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const Key('documents_swap')), findsNothing);
      gate.complete(sourceLanguages);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('documents_swap')), findsOneWidget);
    });

    testWidgets('retry all translates missing parts', (tester) async {
      var failing = true;
      stubTranslate(
        repository,
        respond: (request) => failing
            ? Stream.error(const MozhiApiException('down'))
            : Stream.value(result(request.text.toUpperCase())),
      );
      await pumpPage(tester);
      await pickFile(tester, 'a.txt', 'hello');
      await tester.tap(find.byKey(const Key('documents_translate')));
      await tester.pumpAndSettle();
      failing = false;
      await tester.tap(find.byKey(const Key('documents_retry_all')));
      await tester.pumpAndSettle();
      expect(find.text('Translation complete'), findsOneWidget);
    });

    testWidgets('shows progress and cancels', (tester) async {
      stubTranslate(
        repository,
        respond: (request) => StreamController<TranslationResult>().stream,
      );
      await pumpPage(tester);
      await pickFile(tester, 'a.txt', 'hello');
      await tester.tap(find.byKey(const Key('documents_translate')));
      await tester.pump();
      expect(find.byKey(const Key('documents_progress')), findsOneWidget);
      expect(find.text('Translating… 0 of 1 parts'), findsOneWidget);
      // Input is locked while translating.
      final clear = tester.widget<IconButton>(
        find.byKey(const Key('documents_clear')),
      );
      expect(clear.onPressed, isNull);
      final target = tester.widget<TextButton>(
        find.byKey(const Key('documents_target_language')),
      );
      expect(target.onPressed, isNull);
      // A ring turns around the go button.
      expect(find.byKey(const Key('composer_go_progress')), findsOneWidget);

      await tester.tap(find.byKey(const Key('documents_cancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('documents_progress')), findsNothing);
      expect(cubitOf(tester).state.status, DocumentStatus.ready);
    });

    testWidgets('clear removes the document', (tester) async {
      await pumpPage(tester);
      await pickFile(tester, 'a.txt', 'hello');
      await tester.tap(find.byKey(const Key('documents_clear')));
      await tester.pumpAndSettle();
      expect(find.text('Pick a document'), findsOneWidget);
      expect(find.byKey(const Key('documents_clear')), findsNothing);
    });

    testWidgets('changes the engine through the engine sheet', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.byKey(const Key('documents_engine')));
      await tester.pumpAndSettle();
      expect(find.text('Choose an engine'), findsOneWidget);
      await tester.tap(find.byKey(const Key('documents_engine_ai:openai')));
      await tester.pumpAndSettle();
      expect(cubitOf(tester).state.engine, aiEngine);
      expect(find.text('OpenAI · gpt-4o-mini'), findsOneWidget);
    });

    testWidgets('reports engines whose languages fail to load', (tester) async {
      await pumpPage(tester);
      stubLanguages(repository);
      when(() => repository.getSourceLanguages(deeplEngine))
          .thenThrow(Exception('offline'));
      await tester.tap(find.byKey(const Key('documents_engine')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('documents_engine_mozhi:deepl')));
      await tester.pumpAndSettle();
      expect(
        find.text("Couldn't load the languages of this engine."),
        findsOneWidget,
      );
    });

    testWidgets('picks languages, searches and swaps', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.byKey(const Key('documents_target_language')));
      await tester.pumpAndSettle();
      expect(find.text('Translate into'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('documents_language_search')),
        'span',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('documents_language_de')), findsNothing);
      await tester.tap(find.byKey(const Key('documents_language_es')));
      await tester.pumpAndSettle();
      expect(cubitOf(tester).state.target, spanish);

      await tester.tap(find.byKey(const Key('documents_source_language')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('documents_language_en')));
      await tester.pumpAndSettle();
      expect(cubitOf(tester).state.source, english);

      await tester.tap(find.byKey(const Key('documents_swap')));
      await tester.pumpAndSettle();
      expect(cubitOf(tester).state.source, spanish);
      expect(cubitOf(tester).state.target, english);
    });

    testWidgets('language search without results; custom AI target', (
      tester,
    ) async {
      await pumpPage(
        tester,
        state: readyTranslateState.copyWith(engine: () => aiEngine),
      );
      await tester.tap(find.byKey(const Key('documents_source_language')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('documents_language_search')),
        'zzz',
      );
      await tester.pumpAndSettle();
      expect(find.text('No matching languages'), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('documents_target_language')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('documents_language_search')),
        'Pirate speak',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('documents_language_custom')));
      await tester.pumpAndSettle();
      expect(
        cubitOf(tester).state.target,
        const Language.custom('Pirate speak'),
      );
      expect(find.text('Pirate speak'), findsOneWidget);
    });

    testWidgets('wide layout shows original and translation side by side', (
      tester,
    ) async {
      await pumpPage(tester, size: const Size(1200, 900));
      expect(find.text('Pick a document'), findsOneWidget);
      expect(find.text('The translation appears here.'), findsOneWidget);
      await pickFile(tester, 'movie.srt', srtText);
      expect(find.byKey(const Key('documents_side_by_side')), findsOneWidget);
      expect(find.text('…'), findsNWidgets(2));
      await tester.tap(find.byKey(const Key('documents_translate')));
      await tester.pumpAndSettle();
      expect(find.text('HELLO THERE.'), findsOneWidget);
      expect(find.text('GOOD <i>BYE</i>.'), findsOneWidget);
      expect(find.text('Good <i>bye</i>.'), findsOneWidget);
    });

    testWidgets('wide layout without translatable text', (tester) async {
      await pumpPage(tester, size: const Size(1200, 900));
      await pickFile(tester, 'n.json', '{"a": 1}');
      expect(
        find.text("There's nothing to translate in this document."),
        findsWidgets,
      );
    });

    testWidgets('long previews are truncated', (tester) async {
      await pumpPage(tester);
      final text = List.filled(3000, 'Lorem ipsum dolor.').join('\n\n');
      cubitOf(tester).loadFile('long.txt', bytesOf(text));
      await tester.pumpAndSettle();
      expect(
        find.text('Preview shows the first 20,000 characters.'),
        findsOneWidget,
      );
      expect(find.textContaining('KB'), findsOneWidget);
    });
  });

  group('labels', () {
    testWidgets('sizes, estimates and languages', (tester) async {
      late BuildContext context;
      await tester.pumpApp(
        Builder(
          builder: (c) {
            context = c;
            return const SizedBox();
          },
        ),
      );
      final l10n = context.l10n;
      expect(documentSizeLabel(context, 512), '512 B');
      expect(documentSizeLabel(context, 2048), '2 KB');
      expect(documentSizeLabel(context, 1536 * 1024), '1.5 MB');
      expect(
        documentEstimateLabel(l10n, const Duration(seconds: 30)),
        'Under a minute',
      );
      expect(
        documentEstimateLabel(l10n, const Duration(minutes: 3)),
        'About 3 minutes',
      );
      expect(documentLanguageLabel(l10n, Language.auto), 'Detect language');
      expect(documentLanguageLabel(l10n, german), 'German');
      for (final format in DocumentFormat.values) {
        expect(documentFormatLabel(l10n, format), isNotEmpty);
        expect(documentFormatIcon(format), isNotNull);
      }
      expect(documentFormatIcon(null), Icons.insert_drive_file_outlined);
    });
  });

  test('documentRequests counts what retrying the failed parts sends', () {
    expect(documentRequests(const DocumentTranslateState()), 1);
    Chunk chunk(int index, int units) => Chunk(
      index: index,
      encoding: ChunkEncoding.markers,
      units: [
        for (var i = 0; i < units; i++)
          TranslationUnit(segment: i, part: 0, text: 'unit $i'),
      ],
    );
    final plan = ChunkPlan(
      chunks: [chunk(0, 1), chunk(1, 3)],
      separators: const [],
    );
    final error = Exception('stopped');
    // One request for a single unit; a batch of three may be retried unit
    // by unit; a part the plan does not know is one request.
    expect(
      documentRequests(
        DocumentTranslateState(
          plan: plan,
          failures: {0: error, 1: error, 5: error},
        ),
      ),
      1 + 4 + 1,
    );
  });
}
