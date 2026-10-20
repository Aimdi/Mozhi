import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/network/network.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/web_translate/web_translate.dart';
import 'package:mozhi/web_translate/widgets/readable_block_view.dart';
import 'package:mozhi/web_translate/widgets/web_reader.dart';
import 'package:mozhi/web_translate/widgets/web_translate_messages.dart';
import 'package:mozhi/web_translate/widgets/web_translate_status.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

const page = ReadablePage(
  title: 'Title',
  blocks: [
    ReadableBlock(kind: ReadableBlockKind.paragraph, text: 'One'),
    ReadableBlock(kind: ReadableBlockKind.paragraph, text: 'Two'),
  ],
);

Future<void> pumpWithCubit(
  WidgetTester tester,
  WebTranslateCubit cubit,
  Widget child,
) => tester.pumpWidget(
  MaterialApp(
    localizationsDelegates: appLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: BlocProvider<WebTranslateCubit>.value(value: cubit, child: child),
    ),
  ),
);

Future<void> pumpBlock(WidgetTester tester, Widget child) => tester.pumpWidget(
  MaterialApp(
    localizationsDelegates: appLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  ),
);

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  group('WebTranslateStatusPanel', () {
    late MockWebTranslateCubit cubit;

    setUp(() {
      cubit = MockWebTranslateCubit();
      when(() => cubit.cancel()).thenAnswer((_) async {});
      when(() => cubit.resume()).thenAnswer((_) async {});
    });

    Future<void> pumpPanel(
      WidgetTester tester,
      WebTranslateState state, {
      VoidCallback? onRetryLoad,
    }) {
      when(() => cubit.state).thenReturn(state);
      return pumpWithCubit(
        tester,
        cubit,
        WebTranslateStatusPanel(onRetryLoad: onRetryLoad ?? () {}),
      );
    }

    testWidgets('is empty when idle or translated', (tester) async {
      await pumpPanel(tester, const WebTranslateState());
      expect(tester.getSize(find.byType(WebTranslateStatusPanel)), Size.zero);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('loading shows a spinner and stops', (tester) async {
      await pumpPanel(
        tester,
        const WebTranslateState(status: WebTranslateStatus.loading),
      );
      expect(find.text(l10n.webTranslateLoading), findsOneWidget);
      await tester.tap(find.byKey(const Key('web_translate_stop_button')));
      verify(() => cubit.cancel()).called(1);
    });

    testWidgets('translating shows progress and stops', (tester) async {
      await pumpPanel(
        tester,
        const WebTranslateState(
          status: WebTranslateStatus.translating,
          page: page,
          translations: ['Uno', null],
        ),
      );
      expect(find.text('Translating… 1 of 3'), findsOneWidget);
      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, closeTo(1 / 3, 1e-9));
      await tester.tap(find.byKey(const Key('web_translate_stop_button')));
      verify(() => cubit.cancel()).called(1);
    });

    testWidgets('translating without items is indeterminate', (tester) async {
      await pumpPanel(
        tester,
        const WebTranslateState(status: WebTranslateStatus.translating),
      );
      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, isNull);
    });

    testWidgets('stopped offers to continue', (tester) async {
      await pumpPanel(
        tester,
        const WebTranslateState(
          status: WebTranslateStatus.stopped,
          page: page,
          translations: ['Uno', null],
          translatedTitle: 'Título',
        ),
      );
      expect(
        find.text('Translation stopped: 2 of 3 parts translated.'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('web_translate_resume_button')));
      verify(() => cubit.resume()).called(1);
    });

    testWidgets('loaded without an engine explains why', (tester) async {
      await pumpPanel(
        tester,
        const WebTranslateState(status: WebTranslateStatus.loaded, page: page),
      );
      expect(find.text(l10n.webTranslateNoEngine), findsOneWidget);
    });

    testWidgets('loaded with an engine shows nothing', (tester) async {
      await pumpPanel(
        tester,
        const WebTranslateState(
          status: WebTranslateStatus.loaded,
          page: page,
          selection: googleToSpanish,
        ),
      );
      expect(tester.getSize(find.byType(WebTranslateStatusPanel)), Size.zero);
    });

    testWidgets('a translation failure resumes on retry', (tester) async {
      await pumpPanel(
        tester,
        const WebTranslateState(
          status: WebTranslateStatus.failure,
          page: page,
          selection: googleToSpanish,
          error: MozhiApiException('down', statusCode: 429),
        ),
      );
      expect(find.text(l10n.translateErrorRateLimited), findsOneWidget);
      await tester.tap(find.byKey(const Key('web_translate_retry_button')));
      verify(() => cubit.resume()).called(1);
    });

    testWidgets('a refusal for consent asks inline, then continues', (
      tester,
    ) async {
      const consent = ConsentRequiredException(
        kind: ConsentKind.pair,
        destination: PublicInstanceDestination('mozhi.example.org'),
        engineId: 'mozhi:google',
        source: 'en',
        target: 'es',
      );
      final repository = _MockTranslationRepository();
      final settings = _MockSettingsCubit();
      when(() => settings.state).thenReturn(const AppSettings());
      when(() => cubit.state).thenReturn(
        const WebTranslateState(
          status: WebTranslateStatus.failure,
          page: page,
          selection: googleToSpanish,
          translations: ['One', null],
          error: consent,
        ),
      );
      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: [
            RepositoryProvider<TranslationRepository>.value(value: repository),
          ],
          child: BlocProvider<SettingsCubit>.value(
            value: settings,
            child: MaterialApp(
              localizationsDelegates: appLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: BlocProvider<WebTranslateCubit>.value(
                  value: cubit,
                  child: WebTranslateStatusPanel(onRetryLoad: () {}),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('web_translate_consent')), findsOneWidget);
      await tester.tap(find.text(l10n.commonConsentOnce));
      await tester.pump();
      // The title and the second block are left.
      verify(() => repository.allowOnce(consent, requests: 2)).called(1);
      verify(() => cubit.resume()).called(1);
    });

    test('a one-time consent covers what is left of the page', () {
      expect(webTranslateRequests(const WebTranslateState()), 1);
      expect(
        webTranslateRequests(
          const WebTranslateState(page: page, translations: ['One', null]),
        ),
        2,
      );
      expect(
        webTranslateRequests(
          const WebTranslateState(
            page: page,
            translatedTitle: 'Titre',
            translations: ['Un', 'Deux'],
          ),
        ),
        1,
      );
    });

    testWidgets('a download failure reloads on retry', (tester) async {
      var reloads = 0;
      await pumpPanel(
        tester,
        const WebTranslateState(
          status: WebTranslateStatus.failure,
          error: WebPageException(WebPageError.timeout),
        ),
        onRetryLoad: () => reloads++,
      );
      expect(find.text(l10n.webTranslateErrorTimeout), findsOneWidget);
      await tester.tap(find.byKey(const Key('web_translate_retry_button')));
      expect(reloads, 1);
      verifyNever(() => cubit.resume());
    });
  });

  group('WebReaderSliver', () {
    late MockWebTranslateCubit cubit;

    setUp(() => cubit = MockWebTranslateCubit());

    Future<void> pumpReader(WidgetTester tester, WebTranslateState state) {
      when(() => cubit.state).thenReturn(state);
      return pumpWithCubit(
        tester,
        cubit,
        const CustomScrollView(slivers: [WebReaderSliver(wide: false)]),
      );
    }

    testWidgets('renders nothing without a page', (tester) async {
      await pumpReader(tester, const WebTranslateState());
      expect(find.byType(ReadableBlockView), findsNothing);
    });

    testWidgets('dims untranslated blocks and shows notices', (tester) async {
      await pumpReader(
        tester,
        WebTranslateState(
          status: WebTranslateStatus.translating,
          page: page,
          pageUri: Uri.parse('https://example.com/a'),
          translations: const ['Uno', null],
          selection: googleToSpanish,
          truncated: true,
          unsupportedCharset: 'gbk',
          mode: ReaderMode.sideBySide,
        ),
      );
      // Side by side falls back to the translation on narrow screens.
      expect(find.text('Uno'), findsOneWidget);
      expect(find.text('One'), findsNothing);
      final pending = tester.widget<ReadableBlockView>(
        find.ancestor(
          of: find.text('Two'),
          matching: find.byType(ReadableBlockView),
        ),
      );
      expect(pending.pending, isTrue);
      expect(find.text(l10n.webTranslateTruncated), findsOneWidget);
      expect(
        find.text(l10n.webTranslateUnsupportedCharset('gbk')),
        findsOneWidget,
      );
      // Untitled: the original title is shown until translated.
      expect(find.text('Title'), findsOneWidget);
    });

    testWidgets('selecting a mode updates the cubit', (tester) async {
      await pumpReader(
        tester,
        WebTranslateState(
          status: WebTranslateStatus.translated,
          page: page,
          pageUri: Uri.parse('https://example.com/a'),
          translations: const ['Uno', 'Dos'],
        ),
      );
      await tester.tap(find.text(l10n.webTranslateModeOriginal));
      verify(() => cubit.setMode(ReaderMode.original)).called(1);
    });

    test('effectiveReaderMode', () {
      expect(
        effectiveReaderMode(ReaderMode.sideBySide, wide: false),
        ReaderMode.translated,
      );
      expect(
        effectiveReaderMode(ReaderMode.sideBySide, wide: true),
        ReaderMode.sideBySide,
      );
      expect(
        effectiveReaderMode(ReaderMode.original, wide: false),
        ReaderMode.original,
      );
    });
  });

  group('ReadableBlockView', () {
    testWidgets('renders headings as headers', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpBlock(
        tester,
        const ReadableBlockView(
          block: ReadableBlock(kind: ReadableBlockKind.heading1, text: 'H'),
          text: 'H',
        ),
      );
      expect(
        tester.getSemantics(find.text('H')),
        matchesSemantics(label: 'H', isHeader: true),
      );
      semantics.dispose();
    });

    testWidgets('renders every heading level', (tester) async {
      for (final level in [2, 3, 4]) {
        await pumpBlock(
          tester,
          ReadableBlockView(
            block: ReadableBlock(
              kind: ReadableBlockKind.heading(level),
              text: 'H$level',
            ),
            text: 'H$level',
          ),
        );
        expect(find.text('H$level'), findsOneWidget);
      }
    });

    testWidgets('renders list items with bullets and numbers', (tester) async {
      await pumpBlock(
        tester,
        const Column(
          children: [
            ReadableBlockView(
              block: ReadableBlock(kind: ReadableBlockKind.listItem, text: 'a'),
              text: 'a',
            ),
            ReadableBlockView(
              block: ReadableBlock(
                kind: ReadableBlockKind.listItem,
                text: 'b',
                number: 3,
                depth: 1,
              ),
              text: 'b',
            ),
          ],
        ),
      );
      expect(find.text('•'), findsOneWidget);
      expect(find.text('3.'), findsOneWidget);
    });

    testWidgets('renders quotes, code and images', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpBlock(
        tester,
        const Column(
          children: [
            ReadableBlockView(
              block: ReadableBlock(kind: ReadableBlockKind.quote, text: 'q'),
              text: 'q',
            ),
            ReadableBlockView(
              block: ReadableBlock(kind: ReadableBlockKind.code, text: 'c()'),
              text: 'c()',
              languageCode: 'ar',
            ),
            ReadableBlockView(
              block: ReadableBlock(kind: ReadableBlockKind.image, text: 'Cat'),
              text: 'Cat',
              pending: true,
            ),
          ],
        ),
      );
      expect(find.text('q'), findsOneWidget);
      expect(find.text('c()'), findsOneWidget);
      expect(find.bySemanticsLabel('Image: Cat'), findsOneWidget);
      final opacity = tester.widget<AnimatedOpacity>(
        find.ancestor(
          of: find.byIcon(Icons.image_outlined),
          matching: find.byType(AnimatedOpacity),
        ),
      );
      expect(opacity.opacity, lessThan(1));
      // Code is always left to right.
      final code = tester.widget<Directionality>(
        find
            .ancestor(
              of: find.text('c()'),
              matching: find.byType(Directionality),
            )
            .first,
      );
      expect(code.textDirection, TextDirection.ltr);
      semantics.dispose();
    });

    testWidgets('lays out right-to-left languages', (tester) async {
      await pumpBlock(
        tester,
        const ReadableBlockView(
          block: ReadableBlock(kind: ReadableBlockKind.paragraph, text: 'x'),
          text: 'مرحبا',
          languageCode: 'ar-EG',
        ),
      );
      final direction = tester.widget<Directionality>(
        find
            .ancestor(
              of: find.text('مرحبا'),
              matching: find.byType(Directionality),
            )
            .first,
      );
      expect(direction.textDirection, TextDirection.rtl);
    });
  });

  group('describeWebTranslateError', () {
    test('describes every page error', () {
      String describe(WebPageException error) =>
          describeWebTranslateError(l10n, error);
      expect(
        describe(const WebPageException(WebPageError.invalidUrl)),
        l10n.webTranslateErrorInvalidUrl,
      );
      expect(
        describe(const WebPageException(WebPageError.network)),
        l10n.webTranslateErrorNetwork,
      );
      expect(
        describe(
          const WebPageException(WebPageError.httpStatus, statusCode: 403),
        ),
        l10n.webTranslateErrorStatus('403'),
      );
      expect(
        describe(const WebPageException(WebPageError.httpStatus)),
        l10n.webTranslateErrorStatus('?'),
      );
      expect(
        describe(
          const WebPageException(
            WebPageError.unsupportedContent,
            contentType: 'image/png',
          ),
        ),
        l10n.webTranslateErrorUnsupported('image/png'),
      );
      expect(
        describe(const WebPageException(WebPageError.unsupportedContent)),
        l10n.webTranslateErrorUnsupported('?'),
      );
      expect(
        describe(const WebPageException(WebPageError.timeout)),
        l10n.webTranslateErrorTimeout,
      );
      expect(
        describe(const WebPageException(WebPageError.blockedByBrowser)),
        l10n.webTranslateErrorBlocked,
      );
      expect(
        describe(const WebPageException(WebPageError.tooManyRedirects)),
        l10n.webTranslateErrorRedirects,
      );
      expect(
        describe(const WebPageException(WebPageError.blockedRedirect)),
        l10n.webTranslateErrorBlockedRedirect,
      );
      expect(
        describe(const WebPageException(WebPageError.noContent)),
        l10n.webTranslateErrorNoContent,
      );
    });

    test('says when the network policy refused the download', () {
      expect(
        describeWebTranslateError(
          l10n,
          WebPageException(
            WebPageError.network,
            cause: CleartextRefusedException(Uri.parse('http://example.com')),
          ),
        ),
        l10n.commonErrorCleartextRefused,
      );
    });

    test('falls back to the translation error descriptions', () {
      expect(
        describeWebTranslateError(l10n, StateError('x')),
        l10n.translateErrorGeneric,
      );
    });
  });

  test('isRtlLanguage', () {
    expect(isRtlLanguage(null), isFalse);
    expect(isRtlLanguage(''), isFalse);
    expect(isRtlLanguage('en'), isFalse);
    expect(isRtlLanguage('he'), isTrue);
    expect(isRtlLanguage('fa_IR'), isTrue);
    expect(isRtlLanguage('UR'), isTrue);
  });
}

class _MockTranslationRepository extends Mock implements TranslationRepository;

class _MockSettingsCubit extends MockCubit<AppSettings>
    implements SettingsCubit;
