import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/proofread/widgets/proofread_diff_text.dart';
import 'package:mozhi/quick_improve/quick_improve.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

Finder _byKey(String key) => find.byKey(Key(key));

void main() {
  setUpAll(registerQuickImproveFallbacks);

  late MockQuickImproveCubit cubit;

  setUp(() {
    cubit = MockQuickImproveCubit();
    when(() => cubit.retry()).thenAnswer((_) async {});
    when(() => cubit.setLevel(any())).thenAnswer((_) async {});
    when(() => cubit.setStyle(any())).thenAnswer((_) async {});
    when(() => cubit.selectEngine(any())).thenAnswer((_) async {});
  });

  void stub(QuickImproveState state) => whenListen(
    cubit,
    const Stream<QuickImproveState>.empty(),
    initialState: state,
  );

  VoidCallback? pressedOf(WidgetTester tester, String key) {
    final widget = tester.widget(_byKey(key));
    return switch (widget) {
      final XActionButton button => button.onPressed,
      final ButtonStyleButton button => button.onPressed,
      _ => throw StateError('$key is a ${widget.runtimeType}'),
    };
  }

  group('QuickImproveView', () {
    testWidgets('shows the title and closes', (tester) async {
      var closed = 0;
      stub(const QuickImproveState(text: sentence));
      await tester.pumpImprove(improveView(cubit, onClose: () => closed++));

      expect(find.text('Improve writing'), findsOneWidget);
      expect(find.text(sentence), findsOneWidget);
      await tester.tap(_byKey('quick_improve_close'));
      expect(closed, 1);
    });

    testWidgets('closes its route without a close callback', (tester) async {
      stub(improvedState());
      await tester.pumpImprove(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => Scaffold(
                  body: BlocProvider<QuickImproveCubit>.value(
                    value: cubit,
                    child: const QuickImproveView(),
                  ),
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Improve writing'), findsOneWidget);

      await tester.tap(_byKey('quick_improve_close'));
      await tester.pumpAndSettle();
      expect(find.text('Improve writing'), findsNothing);
    });

    testWidgets('loads the engines first', (tester) async {
      stub(const QuickImproveState(text: sentence));
      await tester.pumpImprove(improveView(cubit));

      expect(_byKey('quick_improve_progress'), findsOneWidget);
      expect(find.text('Loading engines…'), findsOneWidget);
      expect(_byKey('quick_improve_engine_chip'), findsNothing);
      expect(pressedOf(tester, 'quick_improve_copy'), isNull);
      expect(pressedOf(tester, 'quick_improve_retry'), isNull);
    });

    testWidgets('shows progress while improving, nothing to act on', (
      tester,
    ) async {
      stub(
        const QuickImproveState(
          text: sentence,
          status: QuickImproveStatus.improving,
          engine: claude,
          engines: [claude],
        ),
      );
      await tester.pumpImprove(
        improveView(cubit, onReplace: (_) {}, onOpenInProofread: () {}),
      );

      expect(find.text('Improving your text…'), findsOneWidget);
      expect(pressedOf(tester, 'quick_improve_copy'), isNull);
      expect(pressedOf(tester, 'quick_improve_retry'), isNull);
      expect(pressedOf(tester, 'quick_improve_replace'), isNull);
      // The options wait for the proofread.
      expect(
        tester.widget<ActionChip>(_byKey('quick_improve_level_chip')).onPressed,
        isNull,
      );
    });

    group('result', () {
      testWidgets('highlights the changes; the eye shows the plain text', (
        tester,
      ) async {
        stub(improvedState());
        await tester.pumpImprove(improveView(cubit));

        expect(find.text('Improved text'), findsWidgets);
        final diff = tester.widget<ProofreadDiffText>(
          _byKey('quick_improve_diff'),
        );
        expect(diff.segments, improvedState().segments);
        expect(find.text('One grammar fix.'), findsOneWidget);
        expect(_byKey('quick_improve_text'), findsNothing);

        await tester.tap(_byKey('quick_improve_show_changes'));
        await tester.pumpAndSettle();

        expect(_byKey('quick_improve_diff'), findsNothing);
        expect(find.text('I have a cat.'), findsOneWidget);
        expect(find.byTooltip('Show changes'), findsOneWidget);
      });

      testWidgets('names the detected language of the text', (tester) async {
        stub(improvedState());
        await tester.pumpImprove(improveView(cubit));
        expect(find.textContaining('English'), findsWidgets);
      });

      testWidgets('says what the personal data shield kept', (tester) async {
        stub(improvedState(result: fixed.withMaskedPersonalData(2)));
        await tester.pumpImprove(improveView(cubit));

        expect(_byKey('quick_improve_personal_data_kept'), findsOneWidget);
        expect(find.text('2 items kept on this device'), findsOneWidget);
      });

      testWidgets('names where the text was sent', (tester) async {
        final repository = MockTranslationRepository();
        when(() => repository.destinationOf('ai:claude'))
            .thenReturn(cloudDestination);
        stub(improvedState());
        await tester.pumpImprove(improveView(cubit, repository: repository));

        expect(_byKey('quick_improve_destination'), findsOneWidget);
      });

      testWidgets('shows no destination the repository cannot tell', (
        tester,
      ) async {
        final repository = MockTranslationRepository();
        when(() => repository.destinationOf(any()))
            .thenThrow(ArgumentError('unknown'));
        stub(improvedState());
        await tester.pumpImprove(improveView(cubit, repository: repository));

        expect(_byKey('quick_improve_destination'), findsNothing);
        expect(_byKey('quick_improve_diff'), findsOneWidget);
      });

      testWidgets('says when there is nothing to improve', (tester) async {
        stub(
          improvedState(
            improved: sentence,
            result: const ProofreadResult(correctedText: sentence),
          ),
        );
        await tester.pumpImprove(improveView(cubit, onReplace: (_) {}));

        expect(
          find.text('Nothing to improve: your text looks good.'),
          findsOneWidget,
        );
        expect(_byKey('quick_improve_diff'), findsNothing);
        expect(pressedOf(tester, 'quick_improve_replace'), isNull);
        expect(pressedOf(tester, 'quick_improve_copy'), isNotNull);
      });
    });

    group('actions', () {
      testWidgets('Replace is hidden for a read-only selection', (
        tester,
      ) async {
        stub(improvedState());
        await tester.pumpImprove(improveView(cubit));

        expect(_byKey('quick_improve_replace'), findsNothing);
        expect(_byKey('quick_improve_open_in_proofread'), findsNothing);
        expect(_byKey('quick_improve_copy'), findsOneWidget);
      });

      testWidgets('Replace closes the sheet, then returns the improved text', (
        tester,
      ) async {
        final events = <String>[];
        stub(improvedState());
        await tester.pumpImprove(
          improveView(
            cubit,
            onReplace: (text) => events.add('replace: $text'),
            onClose: () => events.add('close'),
          ),
        );

        expect(
          find.byTooltip('Replace the selected text with the improved text'),
          findsOneWidget,
        );
        await tester.tap(_byKey('quick_improve_replace'));

        expect(events, ['close', 'replace: I have a cat.']);
      });

      testWidgets('Open in Proofread closes the sheet first', (tester) async {
        final events = <String>[];
        stub(improvedState());
        await tester.pumpImprove(
          improveView(
            cubit,
            onOpenInProofread: () => events.add('proofread'),
            onClose: () => events.add('close'),
          ),
        );

        await tester.tap(find.text('Open in Proofread'));

        expect(events, ['close', 'proofread']);
      });

      testWidgets('Open in Proofread works before any result', (tester) async {
        var opened = 0;
        stub(const QuickImproveState(text: sentence));
        await tester.pumpImprove(
          improveView(cubit, onOpenInProofread: () => opened++),
        );

        await tester.tap(_byKey('quick_improve_open_in_proofread'));
        expect(opened, 1);
      });

      testWidgets('Retry proofreads again', (tester) async {
        stub(improvedState());
        await tester.pumpImprove(improveView(cubit));

        await tester.tap(_byKey('quick_improve_retry'));
        verify(() => cubit.retry()).called(1);
      });

      group('copy', () {
        String? clipboard;

        setUp(() {
          clipboard = null;
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(SystemChannels.platform, (call) async {
                if (call.method == 'Clipboard.setData') {
                  clipboard =
                      (call.arguments as Map<Object?, Object?>)['text']
                          as String?;
                }
                return null;
              });
        });

        tearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(SystemChannels.platform, null);
        });

        testWidgets('copies the improved text and confirms', (tester) async {
          stub(improvedState());
          await tester.pumpImprove(improveView(cubit));

          await tester.tap(_byKey('quick_improve_copy'));
          await tester.pump();

          expect(clipboard, 'I have a cat.');
          expect(find.text('Copied'), findsOneWidget);
          expect(find.text('Copied to clipboard'), findsOneWidget);

          await tester.pump(const Duration(seconds: 2));
          await tester.pumpAndSettle();
          expect(find.text('Copied'), findsNothing);
          await tester.pump(const Duration(seconds: 2));
          await tester.pumpAndSettle();
          expect(find.text('Copied to clipboard'), findsNothing);
        });

        testWidgets('copying twice restarts the confirmation', (tester) async {
          stub(improvedState());
          await tester.pumpImprove(improveView(cubit));

          await tester.tap(_byKey('quick_improve_copy'));
          await tester.pump(const Duration(seconds: 1));
          await tester.tap(_byKey('quick_improve_copy'));
          await tester.pump(const Duration(milliseconds: 1500));
          expect(find.text('Copied'), findsOneWidget);
          await tester.pumpAndSettle(const Duration(seconds: 5));
          expect(find.text('Copied'), findsNothing);
        });
      });
    });

    group('options', () {
      testWidgets('picks a correction level', (tester) async {
        stub(improvedState());
        await tester.pumpImprove(improveView(cubit));

        expect(find.byTooltip('Correction level: Standard'), findsOneWidget);
        await tester.tap(_byKey('quick_improve_level_chip'));
        await tester.pumpAndSettle();
        await tester.tap(_byKey('quick_improve_level_comprehensive'));
        await tester.pumpAndSettle();

        verify(() => cubit.setLevel(CorrectionLevel.comprehensive)).called(1);
      });

      testWidgets('picks a style', (tester) async {
        stub(improvedState());
        await tester.pumpImprove(improveView(cubit));

        expect(find.byTooltip('Style: General'), findsOneWidget);
        await tester.tap(_byKey('quick_improve_style_chip'));
        await tester.pumpAndSettle();
        await tester.tap(_byKey('quick_improve_style_email'));
        await tester.pumpAndSettle();

        verify(() => cubit.setStyle(WritingStyle.email)).called(1);
      });

      testWidgets('a second tap closes the menu', (tester) async {
        stub(improvedState());
        await tester.pumpImprove(improveView(cubit));

        await tester.tap(_byKey('quick_improve_style_chip'));
        await tester.pumpAndSettle();
        expect(_byKey('quick_improve_style_email'), findsOneWidget);
        await tester.tap(_byKey('quick_improve_style_chip'));
        await tester.pumpAndSettle();
        expect(_byKey('quick_improve_style_email'), findsNothing);
      });

      testWidgets('picks another AI model', (tester) async {
        stub(improvedState());
        await tester.pumpImprove(improveView(cubit));

        await tester.tap(_byKey('composer_engine_chip'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('composer_engine:ai:ollama')),
        );
        await tester.pumpAndSettle();

        verify(() => cubit.selectEngine(ollama)).called(1);
      });

      testWidgets('the model menu opens the AI providers', (tester) async {
        final events = <String>[];
        stub(improvedState());
        await tester.pumpImprove(
          improveView(
            cubit,
            onAddProvider: () => events.add('providers'),
            onClose: () => events.add('close'),
          ),
        );

        await tester.tap(_byKey('composer_engine_chip'));
        await tester.pumpAndSettle();
        await tester.tap(_byKey('composer_engine_manage'));
        await tester.pumpAndSettle();

        expect(events, ['close', 'providers']);
      });

      testWidgets('shows the AI model', (tester) async {
        stub(improvedState());
        await tester.pumpImprove(improveView(cubit, onAddProvider: () {}));

        expect(_byKey('quick_improve_engine_chip'), findsOneWidget);
        expect(find.textContaining('Claude'), findsWidgets);
      });
    });

    group('without a result', () {
      testWidgets('explains a failure with the provider message; Retry', (
        tester,
      ) async {
        stub(
          const QuickImproveState(
            text: sentence,
            status: QuickImproveStatus.failure,
            engine: claude,
            engines: [claude],
            error: LlmApiException('Model overloaded', statusCode: 529),
          ),
        );
        await tester.pumpImprove(improveView(cubit));

        expect(find.text("Couldn't improve the text"), findsOneWidget);
        expect(find.textContaining('Model overloaded'), findsOneWidget);
        await tester.tap(_byKey('quick_improve_error_retry'));
        verify(() => cubit.retry()).called(1);
      });

      testWidgets('asks for consent inline before anything is sent', (
        tester,
      ) async {
        final repository = MockTranslationRepository();
        final settings = MockSettingsCubit();
        when(() => settings.state).thenReturn(const AppSettings());
        when(() => repository.instances).thenReturn(const []);
        stub(
          const QuickImproveState(
            text: sentence,
            status: QuickImproveStatus.failure,
            engine: claude,
            engines: [claude],
            error: consent,
          ),
        );
        await tester.pumpImprove(
          BlocProvider<SettingsCubit>.value(
            value: settings,
            child: improveView(cubit, repository: repository),
          ),
        );

        expect(_byKey('quick_improve_consent'), findsOneWidget);
        expect(find.textContaining('Anthropic'), findsWidgets);
        await tester.tap(find.text('Allow'));
        await tester.pump();

        verify(() => settings.consentToProvider('claude')).called(1);
        verify(() => repository.allowOnce(consent)).called(1);
        verify(() => cubit.retry()).called(1);
      });

      testWidgets('offers to add an AI provider', (tester) async {
        final events = <String>[];
        stub(
          const QuickImproveState(
            text: sentence,
            status: QuickImproveStatus.noEngine,
          ),
        );
        await tester.pumpImprove(
          improveView(
            cubit,
            onAddProvider: () => events.add('providers'),
            onClose: () => events.add('close'),
          ),
        );

        expect(find.text('Proofreading needs an AI provider'), findsOneWidget);
        expect(_byKey('quick_improve_set_up_on_device_ai'), findsNothing);
        await tester.tap(_byKey('quick_improve_add_provider'));

        expect(events, ['close', 'providers']);
      });

      testWidgets('offers on-device AI first where a model fits', (
        tester,
      ) async {
        final events = <String>[];
        stub(
          const QuickImproveState(
            text: sentence,
            status: QuickImproveStatus.noEngine,
          ),
        );
        await tester.pumpImprove(
          improveView(
            cubit,
            onAddProvider: () => events.add('providers'),
            onSetUpOnDeviceAi: () => events.add('on-device'),
            onClose: () => events.add('close'),
          ),
        );

        expect(
          tester.widget(_byKey('quick_improve_add_provider')),
          isA<OutlinedButton>(),
        );
        await tester.tap(_byKey('quick_improve_set_up_on_device_ai'));

        expect(events, ['close', 'on-device']);
      });

      testWidgets('has no buttons where nothing can be opened', (tester) async {
        stub(
          const QuickImproveState(
            text: sentence,
            status: QuickImproveStatus.noEngine,
          ),
        );
        await tester.pumpImprove(improveView(cubit));

        expect(_byKey('quick_improve_add_provider'), findsNothing);
        expect(_byKey('quick_improve_set_up_on_device_ai'), findsNothing);
      });

      testWidgets('reloads engines that failed to load', (tester) async {
        var reloads = 0;
        stub(
          const QuickImproveState(
            text: sentence,
            status: QuickImproveStatus.enginesFailed,
          ),
        );
        await tester.pumpImprove(
          improveView(cubit, onReloadEngines: () => reloads++),
        );

        expect(find.text("Couldn't load your AI providers"), findsOneWidget);
        await tester.tap(_byKey('quick_improve_reload_engines'));
        expect(reloads, 1);
      });

      testWidgets('has no reload button without a way to reload', (
        tester,
      ) async {
        stub(
          const QuickImproveState(
            text: sentence,
            status: QuickImproveStatus.enginesFailed,
          ),
        );
        await tester.pumpImprove(improveView(cubit));
        expect(_byKey('quick_improve_reload_engines'), findsNothing);
      });
    });

    group('looks', () {
      for (final style in AppStyle.values) {
        for (final brightness in Brightness.values) {
          testWidgets('works in the ${style.name} look, ${brightness.name}', (
            tester,
          ) async {
            final handle = tester.ensureSemantics();
            final themes = AppThemes.fromSettings(AppSettings(style: style));
            stub(improvedState(result: fixed.withMaskedPersonalData(1)));
            await tester.pumpImprove(
              improveView(cubit, onReplace: (_) {}, onOpenInProofread: () {}),
              theme: themes.light,
              darkTheme: themes.dark,
              themeMode: brightness == Brightness.dark
                  ? ThemeMode.dark
                  : ThemeMode.light,
            );

            expect(tester.takeException(), isNull);
            expect(_byKey('quick_improve_diff'), findsOneWidget);
            await expectLater(
              tester,
              meetsGuideline(androidTapTargetGuideline),
            );
            await expectLater(
              tester,
              meetsGuideline(labeledTapTargetGuideline),
            );
            handle.dispose();
          });
        }
      }

      testWidgets('fits a dialog-sized window with long text', (tester) async {
        final long = List.filled(40, sentence).join(' ');
        stub(
          improvedState(text: long, improved: long.replaceAll('has', 'have')),
        );
        await tester.pumpImprove(
          improveView(cubit, onReplace: (_) {}, onOpenInProofread: () {}),
          size: const Size(320, 560),
        );
        expect(tester.takeException(), isNull);
      });
    });
  });
}
