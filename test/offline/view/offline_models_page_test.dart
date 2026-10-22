import 'dart:async';
import 'dart:io';

import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/core/network/http_client_factory.dart';
import 'package:mozhi/core/network/network_policy.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/offline/data/offline_model_details.dart';
import 'package:mozhi/offline/data/offline_model_error.dart';
import 'package:mozhi/offline/data/offline_model_import.dart';
import 'package:mozhi/offline/offline.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../helpers/helpers.dart';
import '../helpers.dart';

void main() {
  late MockOfflineTranslator translator;
  late MemoryStore store;

  setUp(() {
    translator = stubOfflineTranslator();
    store = MemoryStore();
  });

  /// Tall enough to show every language without scrolling.
  void useTallView(WidgetTester tester) {
    tester.view
      ..physicalSize = const Size(800, 2400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<void> pumpPage(WidgetTester tester) async {
    useTallView(tester);
    await tester.pumpApp(
      OfflineModelsPage(translator: translator, store: store),
    );
    await tester.pumpAndSettle();
  }

  group('OfflineModelsPage', () {
    testWidgets('shows a spinner while loading', (tester) async {
      final completer = Completer<Set<String>>();
      when(translator.downloadedLanguages).thenAnswer((_) => completer.future);
      await tester.pumpApp(
        OfflineModelsPage(translator: translator, store: store),
      );
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      completer.complete({'en'});
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('lists downloaded and available languages', (tester) async {
      await pumpPage(tester);
      expect(find.text('Offline languages'), findsOneWidget);
      expect(find.text('2 languages downloaded'), findsOneWidget);
      expect(find.text('Downloaded'), findsNWidgets(3)); // header + 2 badges
      expect(find.text('Available to download'), findsOneWidget);
      expect(
        find.text('Offline translation is available in the Android app'),
        findsNothing,
      );

      // Downloaded first, each section sorted by name; unknown codes fall
      // back to the code.
      final names = tester
          .widgetList<OfflineLanguageTile>(find.byType(OfflineLanguageTile))
          .map((tile) => tile.language.name)
          .toList();
      expect(names, ['English', 'German', 'French', 'Japanese', 'xx']);
    });

    testWidgets('shows a banner and disables actions when unavailable', (
      tester,
    ) async {
      translator = stubOfflineTranslator(available: false);
      await pumpPage(tester);
      // On Android only the CPU can be the reason.
      expect(
        find.text(
          'This device’s processor can’t run the offline translation engine',
        ),
        findsOneWidget,
      );
      expect(find.text('No languages downloaded'), findsOneWidget);
      await tester.tap(find.byTooltip('Download French'));
      final toggle = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
      expect(toggle.onChanged, isNull);
      verifyNever(
        () => translator.downloadLanguage(
          any(),
          wifiOnly: any(named: 'wifiOnly'),
        ),
      );
    });

    testWidgets('points to the Android app elsewhere', (tester) async {
      translator = stubOfflineTranslator(available: false);
      await pumpPage(tester);
      expect(
        find.text('Offline translation is available in the Android app'),
        findsOneWidget,
      );
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('falls back to an unavailable engine', (tester) async {
      useTallView(tester);
      await tester.pumpApp(OfflineModelsPage(store: store));
      await tester.pumpAndSettle();
      expect(find.text('Offline languages'), findsOneWidget);
      expect(
        find.text('Offline translation is available in the Android app'),
        findsOneWidget,
      );
      expect(find.byType(OfflineLanguageTile), findsNothing);
      expect(find.textContaining('No languages match'), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('shows a retry button when loading fails', (tester) async {
      when(translator.downloadedLanguages).thenThrow(StateError('plugin'));
      await pumpPage(tester);
      expect(
        find.text('Couldn’t check which languages are downloaded'),
        findsOneWidget,
      );
      when(translator.downloadedLanguages).thenAnswer((_) async => {'en'});
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('1 language downloaded'), findsOneWidget);
    });

    testWidgets('downloads a language with progress and a snackbar', (
      tester,
    ) async {
      final completer = Completer<void>();
      when(
        () => translator.downloadLanguage(
          any(),
          wifiOnly: any(named: 'wifiOnly'),
        ),
      ).thenAnswer((_) => completer.future);
      await pumpPage(tester);

      await tester.tap(find.byTooltip('Download French'));
      await tester.pump();
      expect(find.text('Downloading…'), findsOneWidget);
      verify(() => translator.downloadLanguage('fr')).called(1);

      completer.complete();
      await tester.pumpAndSettle();
      expect(find.text('French is ready for offline use'), findsOneWidget);
      expect(find.text('3 languages downloaded'), findsOneWidget);
      expect(find.byTooltip('Delete French'), findsOneWidget);
    });

    testWidgets('reports a failed download', (tester) async {
      when(
        () => translator.downloadLanguage(
          any(),
          wifiOnly: any(named: 'wifiOnly'),
        ),
      ).thenThrow(Exception('network'));
      await pumpPage(tester);
      await tester.tap(find.byTooltip('Download Japanese'));
      await tester.pumpAndSettle();
      expect(find.text('Couldn’t download Japanese'), findsOneWidget);
      expect(find.byTooltip('Download Japanese'), findsOneWidget);

      // The snack bar retries.
      clearInteractions(translator);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      verify(() => translator.downloadLanguage('ja')).called(1);
    });

    testWidgets('deletes a language after confirmation', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.byTooltip('Delete German'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      verifyNever(() => translator.deleteLanguage(any()));

      await tester.tap(find.byTooltip('Delete German'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();
      verify(() => translator.deleteLanguage('de')).called(1);
      expect(find.text('German deleted'), findsOneWidget);
      expect(find.text('1 language downloaded'), findsOneWidget);
    });

    testWidgets('reports a failed deletion', (tester) async {
      when(() => translator.deleteLanguage(any())).thenThrow(Exception('busy'));
      await pumpPage(tester);
      await tester.tap(find.byTooltip('Delete English'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Couldn’t delete English'), findsOneWidget);
    });

    testWidgets('persists the Wi-Fi only switch', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.text('Download over Wi-Fi only'));
      await tester.pumpAndSettle();
      expect(store.values[OfflineModelsCubit.wifiOnlyKey], 'false');

      await tester.tap(find.byTooltip('Download French'));
      await tester.pumpAndSettle();
      verify(() => translator.downloadLanguage('fr', wifiOnly: false))
          .called(1);
    });

    testWidgets('searches languages', (tester) async {
      await pumpPage(tester);
      await tester.enterText(find.byType(TextField), 'fren');
      await tester.pumpAndSettle();
      expect(find.byType(OfflineLanguageTile), findsOneWidget);
      expect(find.text('French'), findsOneWidget);
      expect(find.text('Downloaded'), findsNothing);

      await tester.enterText(find.byType(TextField), 'klingon');
      await tester.pumpAndSettle();
      expect(find.text('No languages match “klingon”'), findsOneWidget);

      await tester.tap(find.byTooltip('Clear'));
      await tester.pumpAndSettle();
      expect(find.byType(OfflineLanguageTile), findsNWidgets(5));
      expect(find.byTooltip('Clear'), findsNothing);
    });

    testWidgets('uses the provided translator and store', (tester) async {
      store.values[OfflineModelsCubit.wifiOnlyKey] = 'false';
      await tester.pumpApp(
        MultiRepositoryProvider(
          providers: [
            RepositoryProvider<OfflineTranslator>.value(value: translator),
            RepositoryProvider<KeyValueStore>.value(value: store),
          ],
          child: const OfflineModelsPage(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('2 languages downloaded'), findsOneWidget);
      final toggle = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
      expect(toggle.value, isFalse);
    });

    testWidgets('falls back to the preferences', (tester) async {
      await tester.pumpApp(const OfflineModelsPage());
      await tester.pumpAndSettle();
      expect(
        find.text('Offline translation is available in the Android app'),
        findsOneWidget,
      );
      expect(find.byType(SwitchListTile), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
  });

  group('OfflineModelsPage with Mozilla models', () {
    late FakeOfflineModelDetails details;

    setUp(() => details = FakeOfflineModelDetails());

    Future<void> pumpDetailed(WidgetTester tester) async {
      useTallView(tester);
      await tester.pumpApp(
        OfflineModelsPage(
          translator: translator,
          store: store,
          details: details,
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('shows sizes, the storage and how pairs work', (tester) async {
      await pumpDetailed(tester);
      // English needs no download, so only German counts.
      expect(find.text('1 language downloaded'), findsOneWidget);
      expect(find.text('70.0 MB used on this device'), findsOneWidget);
      expect(find.text('Deutsch · 70.0 MB on this device'), findsOneWidget);
      expect(find.text('Français · 40.0 MB download'), findsOneWidget);
      expect(find.text('No download needed'), findsOneWidget);
      expect(find.byTooltip('Delete English'), findsNothing);
      expect(find.textContaining('through English'), findsOneWidget);
      expect(find.textContaining('storage.googleapis.com'), findsOneWidget);
      expect(
        find.text(
          'On mobile data or a metered network, Mozhi asks before downloading',
        ),
        findsOneWidget,
      );
    });

    testWidgets('downloads with a percentage', (tester) async {
      details
        ..progressSteps = [0.42]
        ..hold = Completer<void>();
      await pumpDetailed(tester);

      await tester.tap(find.byTooltip('Download French'));
      await tester.pump();
      expect(find.text('Downloading… 42%'), findsOneWidget);

      when(translator.downloadedLanguages)
          .thenAnswer((_) async => {'en', 'de', 'fr'});
      details.hold!.complete();
      await tester.pumpAndSettle();
      expect(find.text('French is ready for offline use'), findsOneWidget);
      expect(find.text('2 languages downloaded'), findsOneWidget);
      expect(details.downloads, [('fr', true)]);
    });

    testWidgets('updates outdated languages', (tester) async {
      details
        ..storageValue = const OfflineStorage(
          installedBytes: {'de': 70 * 1024 * 1024},
          totalBytes: 70 * 1024 * 1024,
          outdated: {'de'},
        )
        ..storageAfterDownload = testStorage;
      await pumpDetailed(tester);
      expect(find.text('Deutsch · Update available · 50.0 MB'), findsOneWidget);

      await tester.tap(find.byTooltip('Update German'));
      await tester.pumpAndSettle();
      expect(details.downloads, [('de', true)]);
      expect(find.text('German is up to date'), findsOneWidget);
      expect(find.byTooltip('Update German'), findsNothing);
    });

    testWidgets('asks before downloading over mobile data', (tester) async {
      details.error = const MeteredConnectionException();
      await pumpDetailed(tester);

      await tester.tap(find.byTooltip('Download Japanese'));
      await tester.pumpAndSettle();
      expect(find.text('Download over mobile data?'), findsOneWidget);
      expect(
        find.text(
          'You’re on mobile data or a metered network. Japanese needs about '
          '60.0 MB.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(details.downloads, [('ja', true)]);
      expect(find.byType(SnackBar), findsNothing);

      await tester.tap(find.byTooltip('Download Japanese'));
      await tester.pumpAndSettle();
      details.error = null;
      await tester.tap(find.text('Download anyway'));
      await tester.pumpAndSettle();
      expect(details.downloads, [('ja', true), ('ja', true), ('ja', false)]);
      expect(find.text('Japanese is ready for offline use'), findsOneWidget);
    });

    testWidgets('explains why a download failed', (tester) async {
      details.error = const ModelChecksumException('en-fr', 'bad hash');
      await pumpDetailed(tester);

      await tester.tap(find.byTooltip('Download French'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'French didn’t download correctly (a file was damaged or '
          'incomplete), so it was discarded. Try again.',
        ),
        findsOneWidget,
      );
      expect(find.text('Retry'), findsOneWidget);
    });
  });

  group('OfflineModelsPage imports', () {
    late FakeImportingModelDetails details;
    late MockOfflineModelFilePicker picker;

    setUp(() {
      details = FakeImportingModelDetails();
      picker = stubOfflineModelFilePicker();
    });

    Future<void> pumpImporting(
      WidgetTester tester, {
      OfflineModelDetails? withDetails,
    }) async {
      useTallView(tester);
      await tester.pumpApp(
        OfflineModelsPage(
          translator: translator,
          store: store,
          details: withDetails ?? details,
          picker: picker,
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('offers an import from files', (tester) async {
      await pumpImporting(tester);
      expect(find.text('Import from files'), findsOneWidget);
      expect(
        find.text(
          'Install model files you copied to this device. Mozhi doesn’t go '
          'online for this.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('offers no import where it is impossible', (tester) async {
      await pumpImporting(tester, withDetails: FakeOfflineModelDetails());
      expect(find.text('Import from files'), findsNothing);

      translator = stubOfflineTranslator(available: false);
      await pumpImporting(tester);
      expect(find.text('Import from files'), findsNothing);
    });

    testWidgets('imports the picked files and summarises', (tester) async {
      details
        ..report = const OfflineImportReport(
          models: [
            OfflineImportedModel(
              source: 'fr',
              target: 'en',
              status: OfflineImportStatus.installed,
            ),
            OfflineImportedModel(
              source: 'en',
              target: 'fr',
              status: OfflineImportStatus.incomplete,
              missingFiles: ['vocab.enfr.spm.gz'],
            ),
          ],
          unmatchedFiles: ['notes.txt'],
        )
        ..importHold = Completer<void>();
      await pumpImporting(tester);

      await tester.tap(find.text('Import from files'));
      await tester.pump();
      expect(find.text('Importing…'), findsOneWidget);
      expect(
        tester.widget<ListTile>(find.byKey(const Key('offline_import'))).onTap,
        isNull,
      );

      when(translator.downloadedLanguages)
          .thenAnswer((_) async => {'en', 'de', 'fr'});
      details.importHold!.complete();
      await tester.pumpAndSettle();

      expect(details.imports, [
        ['/picked/model.deen.intgemm.alphas.bin.gz'],
      ]);
      verify(picker.clearCopies).called(1);
      expect(find.text('Models imported'), findsOneWidget);
      expect(
        find.text('Installed \u2068French\u2069 → \u2068English\u2069'),
        findsOneWidget,
      );
      expect(
        find.text(
          'Missing 1 file for \u2068English\u2069 → \u2068French\u2069',
        ),
        findsOneWidget,
      );
      expect(find.text('vocab.enfr.spm.gz'), findsOneWidget);
      expect(find.text('1 file didn’t match any model'), findsOneWidget);

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Import from files'), findsOneWidget);
      expect(find.text('Importing…'), findsNothing);
      // French is downloaded now (English needs no download).
      expect(find.text('2 languages downloaded'), findsOneWidget);
    });

    testWidgets('does nothing when the picker is cancelled', (tester) async {
      picker = stubOfflineModelFilePicker(paths: const []);
      await pumpImporting(tester);
      await tester.tap(find.text('Import from files'));
      await tester.pumpAndSettle();
      expect(find.byType(OfflineImportSummaryDialog), findsNothing);
      expect(details.imports, isEmpty);
    });

    testWidgets('shows the files of a language to download by hand', (
      tester,
    ) async {
      await pumpImporting(tester);

      await tester.tap(find.text('German'));
      await tester.pumpAndSettle();
      expect(find.text('Files for German'), findsOneWidget);
      expect(find.text('model.deen.intgemm.alphas.bin.gz'), findsOneWidget);
      expect(find.text('model.ende.intgemm.alphas.bin.gz'), findsOneWidget);

      Navigator.of(tester.element(find.text('Files for German'))).pop();
      await tester.pumpAndSettle();
      // French has no files listed, so its row does nothing.
      await tester.tap(find.text('French'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Files for'), findsNothing);
    });
  });

  group('MeteredDownloadDialog', () {
    testWidgets('works without a known size', (tester) async {
      await tester.pumpApp(
        const MeteredDownloadDialog(
          language: OfflineLanguage(code: 'de', name: 'German'),
        ),
      );
      expect(
        find.text(
          'You’re on mobile data or a metered network, and downloading '
          'German may use a lot of data.',
        ),
        findsOneWidget,
      );
    });
  });

  group('offlineOutcomeMessage', () {
    final l10n = lookupAppLocalizations(const Locale('en'));
    const german = OfflineLanguage(code: 'de', name: 'German');

    String message(
      OfflineModelOperation operation, {
      bool succeeded = false,
      OfflineModelError? error,
    }) => offlineOutcomeMessage(
      l10n,
      OfflineModelOutcome(
        language: german,
        operation: operation,
        succeeded: succeeded,
        error: error,
      ),
    );

    test('describes successes', () {
      expect(
        message(OfflineModelOperation.download, succeeded: true),
        'German is ready for offline use',
      );
      expect(
        message(OfflineModelOperation.update, succeeded: true),
        'German is up to date',
      );
      expect(
        message(OfflineModelOperation.delete, succeeded: true),
        'German deleted',
      );
    });

    test('falls back to a generic failure', () {
      for (final error in [
        null,
        const OfflineModelError(OfflineModelErrorKind.unknown),
      ]) {
        expect(
          message(OfflineModelOperation.download, error: error),
          'Couldn’t download German',
        );
        expect(
          message(OfflineModelOperation.update, error: error),
          'Couldn’t update German',
        );
        expect(
          message(OfflineModelOperation.delete, error: error),
          'Couldn’t delete German',
        );
      }
    });

    test('explains each kind of failure', () {
      String of(Object error) => message(
        OfflineModelOperation.download,
        error: OfflineModelError.of(error),
      );

      expect(
        of(const ModelDownloadException('de-en', 'HTTP 503', statusCode: 503)),
        'Couldn’t download German: the server answered with error 503.',
      );
      expect(
        of(const ModelDownloadException('de-en', 'offline')),
        'Couldn’t download German. Check your connection and try again.',
      );
      expect(
        of(
          const ModelDownloadException(
            'de-en',
            InvalidProxyException.defaultMessage,
          ),
        ),
        l10n.commonErrorInvalidProxy,
      );
      expect(
        of(const FileSystemException('full')),
        'Couldn’t save German. Free up some storage and try again.',
      );
      expect(
        of(const BergamotEngineException('boom')),
        'The offline engine reported an error with German. Try again, or '
        'restart Mozhi.',
      );
      expect(
        of(UnsupportedError('no')),
        'German can’t be translated offline on this device.',
      );
      expect(
        message(
          OfflineModelOperation.download,
          error: const OfflineModelError(OfflineModelErrorKind.server),
        ),
        contains('error 0'),
      );
    });

    test('names the network rule that refused a download', () {
      for (final (policy, text) in [
        (NetworkPolicyError.cleartext, l10n.commonErrorCleartextRefused),
        (NetworkPolicyError.proxyRequired, l10n.commonErrorProxyRequired),
      ]) {
        expect(
          message(
            OfflineModelOperation.download,
            error: OfflineModelError(
              OfflineModelErrorKind.network,
              networkPolicy: policy,
            ),
          ),
          text,
        );
      }
    });

    test('names the mirror a failed download came from', () {
      String of(OfflineModelErrorKind kind, {int? status}) => message(
        OfflineModelOperation.download,
        error: OfflineModelError(
          kind,
          statusCode: status,
          mirror: 'mirror.example',
        ),
      );

      expect(
        of(OfflineModelErrorKind.checksum),
        'German didn’t download correctly from mirror.example: a file '
        'didn’t match the one Mozhi expects, so it was discarded. The mirror '
        'may be out of date.',
      );
      expect(
        of(OfflineModelErrorKind.server, status: 404),
        'Couldn’t download German from mirror.example: it answered with '
        'error 404. The mirror may not have this language yet; ask its owner '
        'or change the model source.',
      );
      expect(of(OfflineModelErrorKind.server), contains('error 0'));
      expect(
        of(OfflineModelErrorKind.network),
        'Couldn’t reach mirror.example to download German. Check your '
        'connection or the model source.',
      );
      // The network rules still come first.
      expect(
        message(
          OfflineModelOperation.download,
          error: const OfflineModelError(
            OfflineModelErrorKind.network,
            networkPolicy: NetworkPolicyError.cleartext,
            mirror: 'mirror.example',
          ),
        ),
        l10n.commonErrorCleartextRefused,
      );
    });
  });

  group('OfflineModelsPage model source', () {
    late SettingsCubit settings;

    setUp(() {
      settings = _MockSettingsCubit();
      when(() => settings.state).thenReturn(
        const AppSettings(
          modelSource: ModelSource(
            kind: ModelSourceKind.custom,
            customUrl: 'https://mirror.example/models/',
          ),
        ),
      );
    });

    testWidgets('shows the source and where models come from', (tester) async {
      useTallView(tester);
      await tester.pumpApp(
        BlocProvider<SettingsCubit>.value(
          value: settings,
          child: OfflineModelsPage(
            translator: translator,
            store: store,
            details: FakeOfflineModelDetails(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Model source'), findsOneWidget);
      expect(find.text('Mirror: mirror.example'), findsOneWidget);
      expect(
        find.text(
          'Models download from mirror.example, a mirror, and are checked '
          'before use. None of your text is sent.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('storage.googleapis.com'), findsNothing);
    });
  });
}

class _MockSettingsCubit extends MockCubit<AppSettings>
    implements SettingsCubit;
