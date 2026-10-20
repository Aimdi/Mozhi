// TEMPORARY review screenshots (not committed): written to the scratchpad.
@Tags(['golden', 'skip_very_good_optimization'])
library;

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/documents/documents.dart';
import 'package:mozhi/image_translate/image_translate.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/offline/offline.dart';
import 'package:mozhi/quick_translate/quick_translate.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/usage/usage.dart';
import 'package:mozhi/web_translate/web_translate.dart';
import 'package:translation_repository/translation_repository.dart';

import '../documents/helpers/fakes.dart' as doc;
import 'package:mozhi/core/key_value_store.dart';
import '../image_translate/helpers/helpers.dart' as img;
import '../offline/helpers.dart' as off;
import '../quick_translate/helpers/helpers.dart' as quick;
import '../web_translate/helpers/helpers.dart' as web;
import 'helpers/golden_helpers.dart';

const _dir =
    '/tmp/claude-0/-home-user-Mozhi/071da89e-592f-547c-b32a-54fb03071e39/scratchpad/review';

enum Look { light, black, dim }

ThemeData _theme(Look look) => switch (look) {
  Look.light => goldenThemes.light,
  Look.black => goldenThemes.dark,
  Look.dim => AppThemes.fromSettings(const AppSettings(pureBlack: false)).dark,
};

class Variant {
  const Variant(
    this.name, {
    this.look = Look.light,
    this.rtl = false,
    this.small = false,
    this.keyboard = false,
    this.wide = false,
  });
  final bool wide;
  final String name;
  final Look look;
  final bool rtl;
  final bool small;
  final bool keyboard;
}

const variants = [
  Variant('wide', wide: true),
  Variant('light'),
  Variant('black', look: Look.black),
  Variant('dim', look: Look.dim),
  Variant('rtl', rtl: true),
  Variant('small', small: true),
];

void _device(WidgetTester tester, Variant v) {
  tester.view
    ..physicalSize = v.wide
        ? const Size(1280, 800)
        : v.small
        ? const Size(320, 640)
        : const Size(411, 891)
    ..devicePixelRatio = 1;
  if (v.small) tester.platformDispatcher.textScaleFactorTestValue = 2;
  if (v.keyboard) {
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
  }
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

Widget _app(Variant v, Widget home, {GlobalKey<NavigatorState>? key}) =>
    MaterialApp(
      navigatorKey: key,
      debugShowCheckedModeBanner: false,
      theme: _theme(v.look),
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => Directionality(
        textDirection: v.rtl ? TextDirection.rtl : TextDirection.ltr,
        child: child!,
      ),
      home: home,
    );

Future<void> _shot(String name) => expectLater(
  find.byType(MaterialApp),
  matchesGoldenFile(Uri.file('$_dir/$name.png')),
);

void main() {
  setUpAll(() {
    doc.registerDocumentFallbacks();
    img.registerImageTranslateFallbacks();
    quick.registerQuickTranslateFallbacks();
  });

  goldenGroup('review', () {
    for (final v in [
      ...variants,
      const Variant('keyboard', keyboard: true),
    ]) {
      testWidgets('documents ${v.name}', (tester) async {
        _device(tester, v);
        final translate = doc.MockTranslateCubit();
        whenListen(
          translate,
          const Stream<TranslateState>.empty(),
          initialState: doc.readyTranslateState,
        );
        final repository = doc.MockTranslationRepository();
        doc.stubLanguages(repository);
        doc.stubTranslate(repository);
        await tester.pumpWidget(
          RepositoryProvider<TranslationRepository>.value(
            value: repository,
            child: BlocProvider<TranslateCubit>.value(
              value: translate,
              child: _app(
                v,
                DocumentTranslatePage(
                  fileService: doc.FakeDocumentFileService(),
                  initialText: v.keyboard ? 'Hello there.' : null,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (v.keyboard) {
          await tester.showKeyboard(
            find.byKey(const Key('documents_text_field')),
          );
          await tester.pumpAndSettle();
        }
        await _shot('documents_${v.name}');
      });
    }

    for (final v in [const Variant('light'), const Variant('black', look: Look.black), const Variant('small', small: true)]) {
      testWidgets('documents translated ${v.name}', (tester) async {
        _device(tester, v);
        final translate = doc.MockTranslateCubit();
        whenListen(
          translate,
          const Stream<TranslateState>.empty(),
          initialState: doc.readyTranslateState,
        );
        final repository = doc.MockTranslationRepository();
        doc.stubLanguages(repository);
        doc.stubTranslate(repository);
        await tester.pumpWidget(
          RepositoryProvider<TranslationRepository>.value(
            value: repository,
            child: BlocProvider<TranslateCubit>.value(
              value: translate,
              child: _app(
                v,
                DocumentTranslatePage(
                  fileService: doc.FakeDocumentFileService(),
                  initialFile: PickedFile(
                    name: 'movie.en.srt',
                    bytes: doc.bytesOf(doc.srtText),
                  ),
                  translator: DocumentTranslator(
                    repository: repository,
                    maxAttempts: 1,
                    retryDelay: Duration.zero,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('documents_translate')));
        await tester.pumpAndSettle();
        await _shot('documents_translated_${v.name}');
      });
    }

    for (final v in variants) {
      testWidgets('image ${v.name}', (tester) async {
        _device(tester, v);
        final harness = img.ImageTranslateHarness();
        await tester.pumpWidget(
          InheritedGoRouter(
            goRouter: harness.router,
            child: RepositoryProvider<TranslationRepository>.value(
              value: harness.repository,
              child: MultiBlocProvider(
                providers: [
                  BlocProvider<TranslateCubit>.value(value: harness.translate),
                  BlocProvider<SettingsCubit>.value(value: harness.settings),
                ],
                child: _app(
                  v,
                  ImageTranslatePage(
                    picker: harness.picker,
                    encoder: harness.encoder,
                    recognizer: harness.recognizer,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await _shot('image_${v.name}');
      });
    }

    for (final v in [
      ...variants,
      const Variant('keyboard', keyboard: true),
      const Variant('small_keyboard', small: true, keyboard: true),
    ]) {
      testWidgets('web ${v.name}', (tester) async {
        _device(tester, v);
        final translate = web.MockTranslateCubit();
        whenListen(
          translate,
          const Stream<TranslateState>.empty(),
          initialState: web.translateState(),
        );
        await tester.pumpWidget(
          RepositoryProvider<TranslationRepository>.value(
            value: web.FakeTranslationRepository(),
            child: BlocProvider<TranslateCubit>.value(
              value: translate,
              child: _app(
                v,
                WebTranslatePage(
                  fetcher: WebPageFetcher(
                    isWeb: false,
                    client: web.htmlClient(web.samplePageHtml),
                  ),
                  extract: (page) async => extractFetchedPage(page),
                  isWeb: v.rtl,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (v.keyboard) {
          await tester.showKeyboard(
            find.byKey(const Key('web_translate_url_field')),
          );
          await tester.pumpAndSettle();
        }
        await _shot('web_${v.name}');
        if (v.name == 'light' || v.name == 'black') {
          await tester.enterText(
            find.byKey(const Key('web_translate_url_field')),
            'https://example.com/sample',
          );
          await tester.tap(find.byKey(const Key('web_translate_go_button')));
          await tester.pumpAndSettle();
          await _shot('web_loaded_${v.name}');
        }
      });
    }

    for (final v in variants) {
      testWidgets('quick ${v.name}', (tester) async {
        _device(tester, v);
        final cubit = quick.MockQuickTranslateCubit();
        whenListen(
          cubit,
          const Stream<QuickTranslateState>.empty(),
          initialState: quick.readyState(
            text: 'The museum is open every day except Monday.',
            translation: quick.result(
              'Le musée est ouvert tous les jours sauf le lundi.',
            ),
          ),
        );
        final navigator = GlobalKey<NavigatorState>();
        await tester.pumpWidget(_app(v, const Scaffold(), key: navigator));
        showModalBottomSheet<void>(
          context: navigator.currentContext!,
          isScrollControlled: true,
          useSafeArea: true,
          showDragHandle: true,
          builder: (context) => BlocProvider<QuickTranslateCubit>.value(
            value: cubit,
            child: QuickTranslateView(
              canReplace: true,
              onReplace: (_) {},
              onOpenInApp: () {},
              onClose: () {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        await _shot('quick_${v.name}');
      });
    }

    for (final v in [const Variant('light'), const Variant('black', look: Look.black), const Variant('small', small: true)]) {
      testWidgets('usage empty ${v.name}', (tester) async {
        _device(tester, v);
        final tracker = UsageTracker(store: MemoryStore());
        addTearDown(tracker.dispose);
        await tester.pumpWidget(_app(v, UsageSummaryPage(tracker: tracker)));
        await tester.pumpAndSettle();
        await _shot('usage_${v.name}');
      });

      testWidgets('offline ${v.name}', (tester) async {
        _device(tester, v);
        await tester.pumpWidget(
          _app(
            v,
            OfflineModelsPage(
              translator: off.stubOfflineTranslator(),
              store: MemoryStore(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await _shot('offline_${v.name}');
      });
    }
  });
}
