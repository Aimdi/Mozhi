// TEMPORARY language bar screenshots (not committed): written to the scratchpad.
@Tags(['golden', 'skip_very_good_optimization'])
library;

import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../translate/helpers/helpers.dart';
import 'helpers/golden_helpers.dart';

const _dir =
    '/tmp/claude-0/-home-user-Mozhi/071da89e-592f-547c-b32a-54fb03071e39/scratchpad/langbar';

void main() {
  setUpAll(registerTranslateFallbacks);

  final states = <String, TranslateState Function()>{
    'auto_de': () => readyState(target: german),
    'en_ja': () => readyState(source: english, target: japanese),
    'detected': translatedState,
    'pt': () => readyState(
      source: const Language(code: 'pt-BR', name: 'Portuguese (Brazil)'),
      target: const Language(code: 'zh-TW', name: 'Chinese (Traditional)'),
    ),
  };
  goldenGroup('bar', () {
    for (final width in [320.0, 360.0, 411.0]) {
      for (final scale in [1.0, 1.3, 2.0]) {
        for (final entry in states.entries) {
          testWidgets('${entry.key} $width $scale', (tester) async {
            final harness = TranslateHarness(state: entry.value());
            tester.view
              ..physicalSize = Size(width, 400)
              ..devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            await tester.pumpWidget(
              InheritedGoRouter(
                goRouter: harness.router,
                child: MultiRepositoryProvider(
                  providers: [
                    RepositoryProvider<SpeechService>.value(
                      value: harness.speech,
                    ),
                    RepositoryProvider<TranslationRepository>.value(
                      value: harness.repository,
                    ),
                  ],
                  child: MultiBlocProvider(
                    providers: [
                      BlocProvider<TranslateCubit>.value(
                        value: harness.translate,
                      ),
                      BlocProvider<SettingsCubit>.value(
                        value: harness.settings,
                      ),
                      BlocProvider<HistoryCubit>.value(value: harness.history),
                    ],
                    child: MaterialApp(
                      debugShowCheckedModeBanner: false,
                      theme: goldenTheme(Brightness.light),
                      localizationsDelegates: appLocalizationsDelegates,
                      supportedLocales: AppLocalizations.supportedLocales,
                      builder: (context, child) => MediaQuery(
                        data: MediaQuery.of(context)
                            .copyWith(textScaler: TextScaler.linear(scale)),
                        child: child!,
                      ),
                      home: Scaffold(
                        body: Align(
                          alignment: Alignment.bottomCenter,
                          child: Padding(
                            padding: const EdgeInsets.all(19),
                            child: const LanguageBar(),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            final texts = [
              for (final e
                  in find
                      .descendant(
                        of: find.byKey(const Key('translate_language_bar')),
                        matching: find.byType(RichText),
                      )
                      .evaluate())
                () {
                  final ro = e.renderObject! as RenderParagraph;
                  return '"${ro.text.toPlainText()}" ${ro.size.width.toStringAsFixed(1)}'
                      '${ro.didExceedMaxLines ? ' CUT' : ''}';
                }(),
            ];
            // ignore: avoid_print
            print('${entry.key} $width $scale: ${texts.join(' | ')}');
            await expectLater(
              find.byKey(const Key('translate_language_bar')),
              matchesGoldenFile(
                Uri.file('$_dir/${entry.key}_${width.toInt()}_$scale.png'),
              ),
            );
          });
        }
      }
    }
  });
}
