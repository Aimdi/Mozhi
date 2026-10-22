import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/speech_settings_cubit.dart';
import 'package:mozhi/settings/view/widgets/choice_dialog.dart';
import 'package:mozhi/settings/view/widgets/speech_settings_section.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:mozhi/speech/widgets/prefer_device_voice_tile.dart';
import 'package:translation_repository/translation_repository.dart';

class _MockSpeechService extends Mock implements SpeechService;

const _french = Language(code: 'fr', name: 'French', nativeName: 'Français');
const _german = Language(code: 'de', name: 'German');
const _amelie = DeviceVoice(
  name: 'Amélie',
  locale: 'fr-CA',
  quality: 'enhanced',
);
const _thomas = DeviceVoice(
  name: 'Thomas',
  locale: 'fr-FR',
  networkRequired: true,
);
const _frb = DeviceVoice(name: 'fr-fr-x-frb-local', locale: 'fr-FR');
const _frd = DeviceVoice(name: 'fr-fr-x-frd-local', locale: 'fr-FR');
const _frdOnline = DeviceVoice(
  name: 'fr-fr-x-frd-network',
  locale: 'fr-FR',
  networkRequired: true,
);

const _previewError =
    'This voice could not be played. Check that it is installed in your '
    'device’s text-to-speech settings.';

/// Finds the semantics node of a button with [tooltip] that screen readers
/// can reach on its own (not merged into another node).
FinderBase<SemanticsNode> _buttonByTooltip(String tooltip) =>
    find.semantics.byPredicate(
      (node) =>
          !node.isMergedIntoParent &&
          node.tooltip == tooltip &&
          node.getSemanticsData().hasAction(SemanticsAction.tap),
    );

void main() {
  late _MockSpeechService speech;
  late StreamController<String?> speaking;

  setUpAll(() => registerFallbackValue(_amelie));

  setUp(() {
    speech = _MockSpeechService();
    speaking = StreamController<String?>.broadcast();
    when(() => speech.speaking).thenAnswer((_) => speaking.stream);
    when(() => speech.current).thenReturn(null);
    when(() => speech.deviceVoiceSupported).thenReturn(true);
    when(() => speech.preferDeviceVoice).thenReturn(false);
    when(speech.loadPreferDeviceVoice).thenAnswer((_) async => false);
    when(() => speech.setPreferDeviceVoice(enabled: any(named: 'enabled')))
        .thenAnswer((_) async {});
    when(speech.loadSettings).thenAnswer((_) async => const SpeechSettings());
    when(() => speech.setSpeechRate(any())).thenAnswer((_) async {});
    when(() => speech.setVoice(any(), any())).thenAnswer((_) async {});
    when(() => speech.deviceVoices(any()))
        .thenAnswer((_) async => const [_amelie, _thomas]);
    when(
      () => speech.toggle(
        id: any(named: 'id'),
        text: any(named: 'text'),
        languageCode: any(named: 'languageCode'),
        remember: any(named: 'remember'),
      ),
    ).thenAnswer((_) async {});
    when(
      () => speech.speak(
        id: any(named: 'id'),
        text: any(named: 'text'),
        languageCode: any(named: 'languageCode'),
        remember: any(named: 'remember'),
      ),
    ).thenAnswer((_) async {});
    when(
      () => speech.previewVoice(
        id: any(named: 'id'),
        text: any(named: 'text'),
        languageCode: any(named: 'languageCode'),
        voice: any(named: 'voice'),
      ),
    ).thenAnswer((_) async {});
    when(speech.stop).thenAnswer((_) async {});
  });

  tearDown(() => speaking.close());

  Future<void> pump(
    WidgetTester tester, {
    List<Language> languages = const [_french, Language.auto, _german],
    ThemeData? theme,
    double textScale = 1,
    TextDirection? direction,
  }) async {
    await tester.pumpWidget(
      RepositoryProvider<SpeechService>.value(
        value: speech,
        child: MaterialApp(
          theme: theme ?? ThemeData(useMaterial3: true),
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: direction == null
                ? child!
                : Directionality(textDirection: direction, child: child!),
          ),
          home: Scaffold(
            body: ListView(
              children: [SpeechSettingsSection(languages: languages)],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Slider slider(WidgetTester tester) => tester.widget(find.byType(Slider));

  group(SpeechSettingsSection, () {
    group('voiceLanguages', () {
      List<String> codes(List<Language> recent, [SpeechSettings? settings]) => [
        for (final language in SpeechSettingsSection.voiceLanguages(
          recent,
          settings ?? const SpeechSettings(),
        ))
          language.code,
      ];

      test('keeps speakable languages once per device tag', () {
        expect(
          codes([
            _french,
            Language.auto,
            const Language.custom('Pirate speak'),
            const Language(code: 'fr-FR', name: 'French (France)'),
            const Language(code: 'iw', name: 'Hebrew'),
            const Language(code: 'he', name: 'Hebrew'),
            const Language(code: 'not a code', name: 'Broken'),
          ]),
          ['fr', 'fr-FR', 'iw'],
        );
      });

      test('offers at most four recent languages', () {
        expect(
          codes([
            for (final code in ['fr', 'de', 'es', 'it', 'pt'])
              Language(code: code, name: code),
          ]),
          ['fr', 'de', 'es', 'it'],
        );
      });

      test('adds languages that have a chosen voice', () {
        final languages = SpeechSettingsSection.voiceLanguages(
          const [_french],
          const SpeechSettings(
            voices: {'fr': _amelie, 'he': _amelie, 'xx-YY': _amelie},
          ),
        );

        expect(
          [for (final language in languages) language.name],
          ['French', 'Hebrew', 'xx-YY'],
        );
      });
    });

    testWidgets('shows the rate, device voice switch and voices', (
      tester,
    ) async {
      await pump(tester);

      expect(find.text('Read aloud'), findsOneWidget);
      expect(find.text('Speech rate'), findsOneWidget);
      expect(find.text('How fast text is read aloud.'), findsOneWidget);
      // There is no "listen slowly" control to point to.
      expect(find.textContaining('slowly'), findsNothing);
      expect(find.text('1.0×'), findsOneWidget);
      expect(find.byType(PreferDeviceVoiceTile), findsOneWidget);
      expect(find.text('Voice per language'), findsOneWidget);
      expect(find.text('French voice'), findsOneWidget);
      expect(find.text('German voice'), findsOneWidget);
      expect(find.text('System default'), findsNWidgets(2));
    });

    testWidgets('shows the stored settings', (tester) async {
      when(speech.loadSettings).thenAnswer(
        (_) async => const SpeechSettings(rate: 1.3, voices: {'fr': _amelie}),
      );

      await pump(tester);

      expect(find.text('1.3×'), findsOneWidget);
      expect(slider(tester).value, 1.3);
      expect(find.text('Amélie'), findsOneWidget);
    });

    testWidgets('hides the voices without a device speech engine', (
      tester,
    ) async {
      when(() => speech.deviceVoiceSupported).thenReturn(false);

      await pump(tester);

      expect(find.byType(Slider), findsOneWidget);
      expect(find.byType(PreferDeviceVoiceTile), findsNothing);
      expect(find.text('Voice per language'), findsNothing);
    });

    testWidgets('hides the voice heading without speakable languages', (
      tester,
    ) async {
      await pump(tester, languages: const [Language.auto]);

      expect(find.byType(PreferDeviceVoiceTile), findsOneWidget);
      expect(find.text('Voice per language'), findsNothing);
    });

    testWidgets('still shows the rate when the service fails', (tester) async {
      when(speech.loadSettings).thenThrow(StateError('broken'));

      await pump(tester);

      expect(find.byType(Slider), findsOneWidget);
      expect(find.byType(PreferDeviceVoiceTile), findsNothing);
    });

    group('rate', () {
      testWidgets('dragging to the end sets 1.5x', (tester) async {
        await pump(tester);

        await tester.drag(find.byType(Slider), const Offset(1000, 0));
        await tester.pump();

        expect(find.text('1.5×'), findsOneWidget);
        verify(() => speech.setSpeechRate(1.5)).called(1);
      });

      testWidgets('is adjustable by screen readers in 0.1 steps', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        await pump(tester);

        expect(
          tester.getSemantics(find.byType(Slider)),
          isSemantics(
            label: 'Speech rate',
            value: '1.0×',
            increasedValue: '1.1×',
            decreasedValue: '0.9×',
            isSlider: true,
            hasIncreaseAction: true,
            hasDecreaseAction: true,
          ),
        );

        tester.semantics.increase(find.semantics.byLabel('Speech rate'));
        await tester.pump();

        verify(() => speech.setSpeechRate(1.1)).called(1);
        expect(find.text('1.1×'), findsOneWidget);
        semantics.dispose();
      });

      testWidgets('previews the rate in the app language', (tester) async {
        await pump(tester);

        await tester.tap(find.byTooltip('Preview speech rate'));
        await tester.pump();

        verify(
          () => speech.toggle(
            id: SpeechSettingsCubit.ratePreviewId,
            text: 'This is how fast translations will be read aloud.',
            languageCode: 'en',
            remember: false,
          ),
        ).called(1);
      });

      testWidgets('shows a stop button while the preview plays', (
        tester,
      ) async {
        await pump(tester);

        speaking.add(SpeechSettingsCubit.ratePreviewId);
        await tester.pump();

        final button = tester.widget<IconButton>(
          find.byKey(const Key('speech_rate_preview')),
        );
        expect(button.isSelected, isTrue);
        expect(find.byTooltip('Stop'), findsOneWidget);
      });

      testWidgets('replays a playing preview at the new rate', (tester) async {
        await pump(tester);
        await tester.tap(find.byTooltip('Preview speech rate'));
        speaking.add(SpeechSettingsCubit.ratePreviewId);
        await tester.pump();

        await tester.drag(find.byType(Slider), const Offset(-1000, 0));
        await tester.pump();

        verify(() => speech.setSpeechRate(0.5)).called(1);
        verify(
          () => speech.speak(
            id: SpeechSettingsCubit.ratePreviewId,
            text: any(named: 'text'),
            languageCode: 'en',
            remember: false,
          ),
        ).called(1);
      });

      testWidgets('explains a preview that cannot play', (tester) async {
        when(
          () => speech.toggle(
            id: any(named: 'id'),
            text: any(named: 'text'),
            languageCode: any(named: 'languageCode'),
            remember: any(named: 'remember'),
          ),
        ).thenThrow(const SpeechUnavailableException('en'));
        await pump(tester);

        await tester.tap(find.byTooltip('Preview speech rate'));
        await tester.pump();

        expect(find.byType(SnackBar), findsOneWidget);
        expect(
          find.textContaining('No voice is available for this language'),
          findsOneWidget,
        );
      });
    });

    group('online voices', () {
      testWidgets('say which were allowed and can be forgotten', (
        tester,
      ) async {
        final allowed = const SpeechSettings().withOnlineVoice(_thomas);
        when(speech.loadSettings).thenAnswer((_) async => allowed);
        when(speech.forgetOnlineVoices).thenAnswer((_) async {});
        await pump(tester);

        expect(find.text('Allowed online voices'), findsOneWidget);
        expect(
          find.textContaining('1 online voice may read aloud'),
          findsOneWidget,
        );

        await tester.tap(find.text('French voice'));
        await tester.pumpAndSettle();
        expect(
          find.text(
            'fr-FR · Online voice: the text goes to its speech service · '
            'Allowed',
          ),
          findsOneWidget,
        );
        await tester.tapAt(Offset.zero);
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('speech_online_voices_forget')));
        await tester.pumpAndSettle();

        verify(speech.forgetOnlineVoices).called(1);
        expect(find.text('Allowed online voices'), findsNothing);
      });

      testWidgets('are not listed while none was allowed', (tester) async {
        await pump(tester);

        expect(find.byKey(const Key('speech_online_voices')), findsNothing);
      });
    });

    group('voice picker', () {
      Future<void> open(WidgetTester tester) async {
        await tester.tap(find.text('French voice'));
        await tester.pumpAndSettle();
      }

      testWidgets('lists the device voices with their details', (tester) async {
        await pump(tester);

        await open(tester);

        expect(find.byType(ChoiceDialog<String>), findsOneWidget);
        expect(
          find.textContaining('Voices installed on this device for French'),
          findsOneWidget,
        );
        expect(find.text('fr-CA · High quality'), findsOneWidget);
        expect(
          find.text(
            'fr-FR · Online voice: the text goes to its speech service',
          ),
          findsOneWidget,
        );
        expect(find.byTooltip('Play Amélie'), findsOneWidget);
        expect(find.byTooltip('Play System default'), findsOneWidget);
        verify(() => speech.deviceVoices('fr')).called(1);
      });

      testWidgets('saves the chosen voice', (tester) async {
        await pump(tester);
        await open(tester);

        await tester.tap(find.text('Thomas'));
        await tester.tap(find.byKey(ChoiceDialog.saveKey));
        await tester.pumpAndSettle();

        verify(() => speech.setVoice('fr', _thomas)).called(1);
        expect(find.text('Thomas'), findsOneWidget);
        expect(find.byType(ChoiceDialog<String>), findsNothing);
      });

      testWidgets('goes back to the default voice', (tester) async {
        when(speech.loadSettings).thenAnswer(
          (_) async => const SpeechSettings(voices: {'fr': _amelie}),
        );
        await pump(tester);
        await open(tester);

        await tester.tap(find.text('System default').last);
        await tester.tap(find.byKey(ChoiceDialog.saveKey));
        await tester.pumpAndSettle();

        verify(() => speech.setVoice('fr', null)).called(1);
      });

      testWidgets('keeps the voice when cancelled', (tester) async {
        await pump(tester);
        await open(tester);

        await tester.tap(find.text('Amélie'));
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        verifyNever(() => speech.setVoice(any(), any()));
      });

      testWidgets('keeps offering a chosen voice that is gone', (tester) async {
        const gone = DeviceVoice(name: 'Old voice', locale: 'fr-BE');
        when(
          speech.loadSettings,
        ).thenAnswer((_) async => const SpeechSettings(voices: {'fr': gone}));
        await pump(tester);

        await open(tester);

        expect(find.text('fr-BE'), findsOneWidget);
      });

      testWidgets('explains when the device has no voice', (tester) async {
        when(() => speech.deviceVoices(any())).thenAnswer((_) async => []);
        await pump(tester);

        await open(tester);

        expect(
          find.textContaining('This device has no voices for French'),
          findsOneWidget,
        );
        // Nothing to preview: the default voice could not play either.
        expect(find.byTooltip('Play System default'), findsNothing);
        expect(
          find.descendant(
            of: find.byType(ChoiceDialog<String>),
            matching: find.text('System default'),
          ),
          findsOneWidget,
        );
      });

      testWidgets('shows progress while the voices load', (tester) async {
        final voices = Completer<List<DeviceVoice>>();
        when(() => speech.deviceVoices(any())).thenAnswer((_) => voices.future);
        await pump(tester);

        await tester.tap(find.text('French voice'));
        await tester.pump();

        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(
          tester
              .widget<ListTile>(find.widgetWithText(ListTile, 'French voice'))
              .onTap,
          isNull,
        );

        voices.complete(const [_amelie]);
        await tester.pumpAndSettle();
        expect(find.byType(ChoiceDialog<String>), findsOneWidget);
      });

      testWidgets('tells screen readers the voices are loading', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        final voices = Completer<List<DeviceVoice>>();
        when(() => speech.deviceVoices(any())).thenAnswer((_) => voices.future);
        await pump(tester);

        await tester.tap(find.text('French voice'));
        await tester.pump();

        expect(find.semantics.byLabel(RegExp('Loading voices…')), findsOne);

        voices.complete(const [_amelie]);
        await tester.pumpAndSettle();
        expect(find.semantics.byLabel(RegExp('Loading voices…')), findsNothing);
        semantics.dispose();
      });

      testWidgets('previews a voice with a sample in its language', (
        tester,
      ) async {
        await pump(tester);
        await open(tester);

        await tester.tap(find.byTooltip('Play Amélie'));
        await tester.pump();

        verify(
          () => speech.previewVoice(
            id: SpeechSettingsCubit.voicePreviewId('fr', _amelie),
            text: 'Français. 1, 2, 3, 4, 5.',
            languageCode: 'fr',
            voice: _amelie,
          ),
        ).called(1);

        speaking.add(SpeechSettingsCubit.voicePreviewId('fr', _amelie));
        await tester.pump();
        expect(find.byTooltip('Stop'), findsOneWidget);

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        verify(speech.stop).called(1);
      });

      testWidgets('previews the default voice', (tester) async {
        await pump(tester, languages: const [_german]);
        await tester.tap(find.text('German voice'));
        await tester.pumpAndSettle();

        await tester.tap(find.byTooltip('Play System default'));
        await tester.pump();

        verify(
          () => speech.previewVoice(
            id: SpeechSettingsCubit.voicePreviewId('de', null),
            text: 'Deutsch. 1, 2, 3, 4, 5.',
            languageCode: 'de',
          ),
        ).called(1);
      });
      testWidgets('previews unknown languages with their name', (tester) async {
        await pump(
          tester,
          languages: const [Language(code: 'xx', name: 'Xish')],
        );
        await tester.tap(find.text('Xish voice'));
        await tester.pumpAndSettle();

        await tester.tap(find.byTooltip('Play Amélie'));
        await tester.pump();

        verify(
          () => speech.previewVoice(
            id: any(named: 'id'),
            text: 'Xish. 1, 2, 3, 4, 5.',
            languageCode: 'xx',
            voice: _amelie,
          ),
        ).called(1);
      });

      testWidgets('lets screen readers play a voice without choosing it', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        await pump(tester);
        await open(tester);

        expect(_buttonByTooltip('Play Amélie'), findsOne);
        expect(_buttonByTooltip('Play System default'), findsOne);
        tester.semantics.tap(_buttonByTooltip('Play Amélie'));
        await tester.pump();

        verify(
          () => speech.previewVoice(
            id: SpeechSettingsCubit.voicePreviewId('fr', _amelie),
            text: any(named: 'text'),
            languageCode: 'fr',
            voice: _amelie,
          ),
        ).called(1);
        // Playing did not select the voice.
        await tester.tap(find.byKey(ChoiceDialog.saveKey));
        await tester.pumpAndSettle();
        verifyNever(() => speech.setVoice(any(), any()));
        semantics.dispose();
      });

      group('when a preview fails', () {
        setUp(() {
          when(
            () => speech.previewVoice(
              id: any(named: 'id'),
              text: any(named: 'text'),
              languageCode: any(named: 'languageCode'),
              voice: any(named: 'voice'),
            ),
          ).thenThrow(const SpeechUnavailableException('fr'));
        });

        testWidgets('explains it inside the voice picker', (tester) async {
          final semantics = tester.ensureSemantics();
          await pump(tester);
          await open(tester);

          await tester.tap(find.byTooltip('Play Amélie'));
          await tester.pump();

          expect(find.byType(SnackBar), findsNothing);
          expect(
            find.descendant(
              of: find.byType(ChoiceDialog<String>),
              matching: find.text(_previewError),
            ),
            findsOneWidget,
          );
          expect(
            find.semantics.byPredicate(
              (node) =>
                  node.label == _previewError &&
                  node.getSemanticsData().flagsCollection.isLiveRegion,
            ),
            findsOne,
          );
          // Not the general message about Mozhi instances.
          expect(find.textContaining('Add a Mozhi instance'), findsNothing);
          semantics.dispose();
        });

        testWidgets('forgets it once the picker is closed', (tester) async {
          await pump(tester);
          await open(tester);
          await tester.tap(find.byTooltip('Play Amélie'));
          await tester.pump();

          await tester.tap(find.text('Cancel'));
          await tester.pumpAndSettle();
          expect(find.byType(SnackBar), findsNothing);
          await open(tester);

          expect(find.text(_previewError), findsNothing);
        });

        testWidgets('shows it for its own language only', (tester) async {
          await pump(tester);
          await open(tester);
          await tester.tap(find.byTooltip('Play Amélie'));
          await tester.pump();

          final context = tester.element(find.byType(ChoiceDialog<String>));
          context.read<SpeechSettingsCubit>().emit(
            context.read<SpeechSettingsCubit>().state.copyWith(
              failedPreviewId: () =>
                  SpeechSettingsCubit.voicePreviewId('de', null),
            ),
          );
          await tester.pump();

          expect(find.text(_previewError), findsNothing);
        });

        testWidgets('lays out at 200% text', (tester) async {
          tester.view
            ..physicalSize = const Size(360, 640)
            ..devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await pump(tester, textScale: 2);
          await tester.ensureVisible(find.text('French voice'));
          await tester.pumpAndSettle();
          await open(tester);
          await tester.ensureVisible(find.byTooltip('Play Amélie'));
          await tester.pumpAndSettle();

          await tester.tap(find.byTooltip('Play Amélie'));
          await tester.pump();

          expect(tester.takeException(), isNull);
          // Pinned under the scrolling options, so it starts on screen.
          final message = tester.getRect(find.text(_previewError));
          expect(message.top, greaterThanOrEqualTo(0));
          expect(message.top, lessThan(640 - 48));
        });
      });

      group('with engine voice names', () {
        setUp(() {
          when(() => speech.deviceVoices(any()))
              .thenAnswer((_) async => const [_frb, _frd, _frdOnline, _amelie]);
        });

        testWidgets('numbers them instead of showing the engine ids', (
          tester,
        ) async {
          await pump(tester);
          await open(tester);

          expect(find.textContaining('-x-'), findsNothing);
          expect(find.text('Voice 1'), findsOneWidget);
          expect(find.text('Voice 2'), findsOneWidget);
          expect(find.text('Voice 3'), findsOneWidget);
          expect(
            find.text('fr-FR · Online voice: the text goes to Google'),
            findsOneWidget,
          );
          expect(find.text('Amélie'), findsOneWidget);
          expect(find.byTooltip('Play Voice 3'), findsOneWidget);
        });

        testWidgets('shows the chosen one by its number', (tester) async {
          await pump(tester);
          await open(tester);

          await tester.tap(find.text('Voice 2'));
          await tester.tap(find.byKey(ChoiceDialog.saveKey));
          await tester.pumpAndSettle();

          verify(() => speech.setVoice('fr', _frd)).called(1);
          expect(find.text('Voice 2'), findsOneWidget);
        });

        testWidgets('numbers a stored choice once the voices are listed', (
          tester,
        ) async {
          final voices = Completer<List<DeviceVoice>>();
          when(() => speech.deviceVoices(any()))
              .thenAnswer((_) => voices.future);
          when(
            speech.loadSettings,
          ).thenAnswer((_) async => const SpeechSettings(voices: {'fr': _frd}));
          await pump(tester);

          expect(find.text('Voice FRD'), findsOneWidget);
          expect(find.textContaining('-x-'), findsNothing);

          voices.complete(const [_frb, _frd]);
          await tester.pump();

          expect(find.text('Voice 2'), findsOneWidget);
          verify(() => speech.deviceVoices('fr')).called(1);
        });
      });
    });

    group('accessibility', () {
      testWidgets('meets the tap target and label guidelines', (tester) async {
        final semantics = tester.ensureSemantics();
        await pump(tester);

        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        semantics.dispose();
      });

      testWidgets('adds no empty semantics node over the screen', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        await pump(tester);

        // The slider's value indicator lives in the overlay; when it is
        // built it adds an empty, screen-sized node that covers (and on the
        // web blocks pointer events to) everything below it.
        final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
        final covering = find.semantics.byPredicate((node) {
          final data = node.getSemanticsData();
          return !node.isMergedIntoParent &&
              !node.hasChildren &&
              data.label.isEmpty &&
              data.actions == 0 &&
              node.rect.width >= screen.width &&
              node.rect.height >= screen.height;
        });
        expect(covering, findsNothing);
        semantics.dispose();
      });

      for (final brightness in Brightness.values) {
        testWidgets('has readable text in $brightness', (tester) async {
          await pump(
            tester,
            theme: ThemeData(useMaterial3: true, brightness: brightness),
          );

          await expectLater(tester, meetsGuideline(textContrastGuideline));
        });
      }

      testWidgets('lays out at 200% text without overflow', (tester) async {
        tester.view
          ..physicalSize = const Size(360, 2400)
          ..devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await pump(tester, textScale: 2);

        expect(tester.takeException(), isNull);
        expect(find.text('Speech rate'), findsOneWidget);
      });

      testWidgets('works right to left', (tester) async {
        await pump(tester, direction: TextDirection.rtl);

        final slider = tester.getRect(find.byType(Slider));
        final preview = tester.getRect(
          find.byKey(const Key('speech_rate_preview')),
        );
        expect(preview.right, lessThanOrEqualTo(slider.left));
      });
    });
  });
}
