import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/platform/model_file_picker.dart';
import 'package:mozhi/settings/view/widgets/delete_local_data.dart'
    show formatStoredSize;
import 'package:mozhi/settings/view/widgets/voice_input_settings_section.dart';
import 'package:mozhi/voice/voice.dart';
import 'package:translation_repository/translation_repository.dart'
    show PrivacyMode;
import 'package:whisper_speech/whisper_speech.dart';

import '../../helpers/helpers.dart';
import '../../voice/helpers/fake_offline_recognizer.dart';
import '../../voice/helpers/fake_speech_recognizer.dart';

class _MockOfflineSpeech extends Mock implements OfflineSpeech;

class _MockPicker extends Mock implements ModelFilePicker;

final _tiny = WhisperCatalogModel(
  id: 'tiny',
  name: 'ggml-tiny.bin',
  url: Uri.parse('https://models.example/ggml-tiny.bin'),
  size: 77691713,
  sha1: 'a' * 40,
);
final _base = WhisperCatalogModel(
  id: 'base',
  name: 'ggml-base.bin',
  url: Uri.parse('https://models.example/ggml-base.bin'),
  size: 147951465,
  sha1: 'b' * 40,
);

final _vad = WhisperCatalogModel(
  id: 'silero-vad',
  name: 'ggml-silero-v6.2.0.bin',
  url: Uri.parse('https://models.example/ggml-silero-v6.2.0.bin'),
  size: 885098,
  sha1: 'c' * 40,
);

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  late MemoryStore store;
  late SpeechInputService speech;
  late _MockOfflineSpeech offline;
  late _MockPicker picker;
  late Set<String> installed;
  late String? selected;

  setUp(() {
    store = MemoryStore();
    speech = SpeechInputService(
      store: store,
      adapter: FakeSpeechRecognizer(),
      offlineAdapter: FakeOfflineRecognizer(),
      platformSupported: true,
      onDeviceSupported: true,
    );
    offline = _MockOfflineSpeech();
    picker = _MockPicker();
    installed = {};
    selected = null;
    when(() => offline.isAvailable).thenReturn(true);
    when(() => offline.models).thenReturn([_tiny, _base]);
    when(() => offline.installed()).thenAnswer((_) async => {...installed});
    when(() => offline.selected()).thenAnswer(
      (_) async => selected ?? (installed.isEmpty ? null : installed.last),
    );
    when(
      () => offline.download(
        any(),
        overMeteredNetwork: any(named: 'overMeteredNetwork'),
        onProgress: any(named: 'onProgress'),
      ),
    ).thenAnswer((invocation) async {
      installed.add(invocation.positionalArguments.single as String);
    });
    when(() => offline.delete(any())).thenAnswer((invocation) async {
      installed.remove(invocation.positionalArguments.single);
    });
    when(() => offline.select(any())).thenAnswer((invocation) async {
      selected = invocation.positionalArguments.single as String;
    });
    when(() => picker.clearCopies()).thenAnswer((_) async {});
  });

  tearDown(() => speech.dispose());

  Future<void> pumpSection(
    WidgetTester tester, {
    PrivacyMode privacyMode = PrivacyMode.offlineFirst,
    bool withOffline = true,
    bool withSpeech = true,
  }) async {
    Widget child = Scaffold(
      body: SingleChildScrollView(
        child: VoiceInputSettingsSection(privacyMode: privacyMode),
      ),
    );
    if (withOffline) {
      child = RepositoryProvider<OfflineSpeech>.value(
        value: offline,
        child: child,
      );
    }
    if (withSpeech) {
      child = RepositoryProvider<SpeechInputService>.value(
        value: speech,
        child: child,
      );
    }
    await tester.pumpApp(child);
    await tester.pumpAndSettle();
  }

  /// Delivers states emitted by the test (the bloc's stream is
  /// asynchronous) and builds them.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  Future<VoiceSettingsCubit> pumpView(
    WidgetTester tester, {
    PrivacyMode privacyMode = PrivacyMode.offlineFirst,
  }) async {
    final cubit = VoiceSettingsCubit(
      speechInput: speech,
      offline: offline,
      picker: picker,
    );
    addTearDown(cubit.close);
    await cubit.load();
    await tester.pumpApp(
      Scaffold(
        body: SingleChildScrollView(
          child: BlocProvider.value(
            value: cubit,
            child: VoiceInputSettingsView(
              privacyMode: privacyMode,
              speech: speech,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return cubit;
  }

  group(VoiceInputSettingsSection, () {
    testWidgets('renders nothing without voice input', (tester) async {
      await pumpSection(tester, withSpeech: false);
      expect(find.text(l10n.voiceSettingsTitle), findsNothing);

      speech = SpeechInputService(
        store: store,
        adapter: FakeSpeechRecognizer(),
        platformSupported: false,
      );
      await pumpSection(tester);
      expect(find.text(l10n.voiceSettingsTitle), findsNothing);
    });

    testWidgets('without Whisper only the on-device switch is offered', (
      tester,
    ) async {
      await pumpSection(tester, withOffline: false);
      expect(find.text(l10n.voiceSettingsTitle), findsOneWidget);
      expect(find.text(l10n.voicePreferOnDeviceTitle), findsOneWidget);
      expect(find.text(l10n.voiceEngineTitle), findsNothing);
      expect(find.text(l10n.voiceModelsTitle), findsNothing);
    });

    testWidgets('renders nothing with nothing to set', (tester) async {
      speech = SpeechInputService(
        store: store,
        adapter: FakeSpeechRecognizer(),
        platformSupported: true,
        onDeviceSupported: false,
      );
      await pumpSection(tester, withOffline: false);
      expect(find.text(l10n.voiceSettingsTitle), findsNothing);
    });

    testWidgets('lists the engine and the models', (tester) async {
      installed = {'tiny'};
      await pumpSection(tester);
      expect(find.text(l10n.voiceEngineTitle), findsOneWidget);
      expect(find.text(l10n.voiceEngineSystem), findsOneWidget);
      expect(find.text(l10n.voiceModelsTitle), findsOneWidget);
      expect(find.text(l10n.voiceModelsDescription), findsOneWidget);
      expect(find.text(l10n.voiceModelFast), findsOneWidget);
      expect(find.text(l10n.voiceModelBetter), findsOneWidget);
      final fastSize = formatStoredSize(l10n, _tiny.size);
      expect(
        find.text(
          '${l10n.voiceModelSubtitle(l10n.voiceModelFastDescription, fastSize)}'
          ' · ${l10n.voiceModelInUse}',
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          l10n.voiceModelSubtitle(
            l10n.voiceModelBetterDescription,
            formatStoredSize(l10n, _base.size),
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.byTooltip(l10n.voiceModelDeleteTooltip(l10n.voiceModelFast)),
        findsOneWidget,
      );
      expect(
        find.byTooltip(l10n.voiceModelDownloadTooltip(l10n.voiceModelBetter)),
        findsOneWidget,
      );
      expect(find.text(l10n.offlineImportAction), findsOneWidget);
      expect(find.text(l10n.voiceModelCopyLinks), findsOneWidget);
      expect(find.text(l10n.voicePreferOnDeviceTitle), findsOneWidget);
      expect(find.byKey(const Key('voice_offline_only_note')), findsNothing);
    });

    testWidgets('names and describes the quantized models', (tester) async {
      WhisperCatalogModel quantized(String id, int size) => WhisperCatalogModel(
        id: id,
        name: 'ggml-$id.bin',
        url: Uri.parse('https://models.example/ggml-$id.bin'),
        size: size,
        sha1: 'd' * 40,
      );
      final models = [
        quantized('base-q5_1', 60000000),
        quantized('small-q5_1', 190000000),
        quantized('large-v3-turbo-q5_0', 574000000),
      ];
      when(() => offline.models).thenReturn(models);
      await pumpSection(tester);
      final descriptions = {
        l10n.voiceModelBetterCompact: l10n.voiceModelBetterCompactDescription,
        l10n.voiceModelBest: l10n.voiceModelBestDescription,
        l10n.voiceModelLarge: l10n.voiceModelLargeDescription,
      };
      for (final (index, MapEntry(key: name, value: description))
          in descriptions.entries.indexed) {
        expect(find.text(name), findsOneWidget);
        expect(
          find.text(
            l10n.voiceModelSubtitle(
              description,
              formatStoredSize(l10n, models[index].size),
            ),
          ),
          findsOneWidget,
        );
      }
    });

    testWidgets('switches to the offline engine', (tester) async {
      await pumpSection(tester);
      await tester.tap(find.byKey(const Key('voice_engine')));
      await tester.pumpAndSettle();
      expect(find.text(l10n.voiceEngineDialogBody), findsOneWidget);
      expect(find.text(l10n.voiceEngineSystemSubtitle), findsOneWidget);
      expect(find.text(l10n.voiceEngineWhisperSubtitle), findsOneWidget);
      await tester.tap(find.text(l10n.voiceEngineWhisper));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.commonSave));
      await tester.pumpAndSettle();
      expect(store.values[SpeechInputService.engineKey], 'whisper');
      expect(speech.engine.value, VoiceInputEngine.whisper);
      // The on-device switch is about the system recogniser only.
      expect(find.text(l10n.voicePreferOnDeviceTitle), findsNothing);
      expect(find.text(l10n.voiceEngineWhisper), findsOneWidget);
    });

    testWidgets('says that Offline only uses Whisper only', (tester) async {
      await pumpSection(tester, privacyMode: PrivacyMode.offlineOnly);
      expect(find.text(l10n.voiceEngineOfflineOnlyNote), findsOneWidget);
      expect(find.text(l10n.voicePreferOnDeviceTitle), findsNothing);
    });

    testWidgets('says that Offline only has no voice input without '
        'Whisper', (tester) async {
      await pumpSection(
        tester,
        privacyMode: PrivacyMode.offlineOnly,
        withOffline: false,
      );
      expect(find.text(l10n.voiceEngineOfflineOnlyUnavailable), findsOneWidget);
    });
  });

  group(VoiceInputSettingsView, () {
    testWidgets('downloads a model', (tester) async {
      await pumpView(tester);
      await tester.tap(
        find.byTooltip(l10n.voiceModelDownloadTooltip(l10n.voiceModelFast)),
      );
      await tester.pumpAndSettle();
      verify(
        () => offline.download('tiny', onProgress: any(named: 'onProgress')),
      ).called(1);
      expect(
        find.text(l10n.voiceModelDownloadDone(l10n.voiceModelFast)),
        findsOneWidget,
      );
      expect(
        find.byTooltip(l10n.voiceModelDeleteTooltip(l10n.voiceModelFast)),
        findsOneWidget,
      );
    });

    testWidgets('shows download progress', (tester) async {
      final cubit = await pumpView(tester);
      cubit.emit(
        cubit.state.copyWith(
          pending: {'base': VoiceModelOperation.download},
          progress: {'base': 0.42},
        ),
      );
      await settle(tester);
      expect(find.text(l10n.voiceModelDownloading(42)), findsOneWidget);
      final indicator = tester.widget<CircularProgressIndicator>(
        find.byType(CircularProgressIndicator),
      );
      expect(indicator.value, 0.42);
      // Not tappable while busy.
      expect(
        find.byTooltip(l10n.voiceModelDownloadTooltip(l10n.voiceModelBetter)),
        findsNothing,
      );
    });

    testWidgets('asks before downloading over mobile data', (tester) async {
      var calls = 0;
      when(
        () => offline.download(
          any(),
          overMeteredNetwork: any(named: 'overMeteredNetwork'),
          onProgress: any(named: 'onProgress'),
        ),
      ).thenAnswer((invocation) async {
        calls++;
        if (invocation.namedArguments[#overMeteredNetwork] != true) {
          throw const VoiceModelMeteredException();
        }
        installed.add('base');
      });
      await pumpView(tester);
      await tester.tap(
        find.byTooltip(l10n.voiceModelDownloadTooltip(l10n.voiceModelBetter)),
      );
      await tester.pumpAndSettle();
      expect(find.text(l10n.offlineMeteredTitle), findsOneWidget);
      expect(
        find.text(
          l10n.voiceModelMeteredBody(
            l10n.voiceModelBetter,
            formatStoredSize(l10n, _base.size),
          ),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('voice_model_metered_confirm')));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(
        find.text(l10n.voiceModelDownloadDone(l10n.voiceModelBetter)),
        findsOneWidget,
      );
    });

    testWidgets('a declined metered download stays undone', (tester) async {
      when(
        () => offline.download(
          any(),
          overMeteredNetwork: any(named: 'overMeteredNetwork'),
          onProgress: any(named: 'onProgress'),
        ),
      ).thenThrow(const VoiceModelMeteredException());
      await pumpView(tester);
      await tester.tap(
        find.byTooltip(l10n.voiceModelDownloadTooltip(l10n.voiceModelFast)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.commonCancel));
      await tester.pumpAndSettle();
      verify(
        () => offline.download('tiny', onProgress: any(named: 'onProgress')),
      ).called(1);
    });

    final failures = <String, (Object, String Function(String))>{
      'checksum': (
        const WhisperChecksumException('tiny', 'bad'),
        l10n.voiceModelErrorChecksum,
      ),
      'server': (
        const WhisperDownloadException('tiny', 'x', statusCode: 503),
        (name) => l10n.voiceModelErrorServer(name, 503),
      ),
      'network': (
        const WhisperDownloadException('tiny', 'x'),
        l10n.voiceModelErrorNetwork,
      ),
      'storage': (
        const FileSystemException('full'),
        l10n.voiceModelErrorStorage,
      ),
    };
    for (final MapEntry(key: name, value: (error, message))
        in failures.entries) {
      testWidgets('explains a $name failure', (tester) async {
        when(
          () => offline.download(
            any(),
            overMeteredNetwork: any(named: 'overMeteredNetwork'),
            onProgress: any(named: 'onProgress'),
          ),
        ).thenThrow(error);
        await pumpView(tester);
        await tester.tap(
          find.byTooltip(l10n.voiceModelDownloadTooltip(l10n.voiceModelFast)),
        );
        await tester.pumpAndSettle();
        expect(find.text(message(l10n.voiceModelFast)), findsOneWidget);
      });
    }

    testWidgets('deletes a model after confirming', (tester) async {
      installed = {'tiny'};
      await pumpView(tester);
      await tester.tap(
        find.byTooltip(l10n.voiceModelDeleteTooltip(l10n.voiceModelFast)),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(l10n.voiceModelDeleteTitle(l10n.voiceModelFast)),
        findsOneWidget,
      );
      expect(find.text(l10n.voiceModelDeleteBody), findsOneWidget);
      await tester.tap(find.byKey(const Key('voice_model_delete_confirm')));
      await tester.pumpAndSettle();
      verify(() => offline.delete('tiny')).called(1);
      expect(
        find.text(l10n.voiceModelDeleteDone(l10n.voiceModelFast)),
        findsOneWidget,
      );
    });

    testWidgets('keeps a model when deleting is cancelled or fails', (
      tester,
    ) async {
      installed = {'tiny'};
      when(() => offline.delete(any()))
          .thenThrow(const FileSystemException('x'));
      await pumpView(tester);
      final delete = find.byTooltip(
        l10n.voiceModelDeleteTooltip(l10n.voiceModelFast),
      );
      await tester.tap(delete);
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.commonCancel));
      await tester.pumpAndSettle();
      verifyNever(() => offline.delete(any()));

      await tester.tap(delete);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('voice_model_delete_confirm')));
      await tester.pumpAndSettle();
      expect(
        find.text(l10n.voiceModelDeleteFailed(l10n.voiceModelFast)),
        findsOneWidget,
      );
    });

    testWidgets('tapping another installed model uses it', (tester) async {
      installed = {'tiny', 'base'};
      selected = 'base';
      await pumpView(tester);
      await tester.tap(find.byKey(const Key('voice_model_tiny')));
      await tester.pumpAndSettle();
      verify(() => offline.select('tiny')).called(1);
      final tile = tester.widget<ListTile>(
        find.byKey(const Key('voice_model_tiny')),
      );
      expect(tile.onTap, isNull);
    });

    testWidgets('imports models from files', (tester) async {
      when(() => picker.pick(onCopying: any(named: 'onCopying'))).thenAnswer(
        (_) async => [PickedModelFile.local('/picked/ggml-base.bin')],
      );
      when(() => offline.importFiles(any())).thenAnswer((_) async {
        installed.add('base');
        return WhisperImportResult(
          models: [
            WhisperImportOutcome(
              model: _base,
              status: WhisperImportStatus.installed,
            ),
            WhisperImportOutcome(
              model: _tiny,
              status: WhisperImportStatus.checksumMismatch,
            ),
          ],
        );
      });
      await pumpView(tester);
      await tester.tap(find.byKey(const Key('voice_model_import')));
      await tester.pumpAndSettle();
      expect(
        find.text(
          '${l10n.voiceModelImportInstalled(l10n.voiceModelBetter)}\n'
          '${l10n.voiceModelImportDamaged(l10n.voiceModelFast)}',
        ),
        findsOneWidget,
      );
    });

    testWidgets('explains imports that installed nothing', (tester) async {
      final cubit = await pumpView(tester);
      for (final (outcome, message) in [
        (const VoiceImportOutcome(), l10n.voiceModelImportNothing),
        (const VoiceImportOutcome(failed: true), l10n.voiceModelImportFailed),
        (
          const VoiceImportOutcome(
            models: {'tiny': WhisperImportStatus.alreadyInstalled},
          ),
          l10n.voiceModelImportAlreadyInstalled(l10n.voiceModelFast),
        ),
        (
          const VoiceImportOutcome(
            models: {'base': WhisperImportStatus.failed},
          ),
          l10n.voiceModelImportFailed,
        ),
      ]) {
        cubit.emit(cubit.state.copyWith(importOutcome: () => outcome));
        await settle(tester);
        await tester.pumpAndSettle();
        expect(find.text(message), findsOneWidget, reason: '$outcome');
        cubit.emit(cubit.state.copyWith(importOutcome: () => null));
        await tester.pumpAndSettle();
      }
    });

    testWidgets('shows a running import', (tester) async {
      final cubit = await pumpView(tester);
      cubit.emit(cubit.state.copyWith(importing: true));
      await settle(tester);
      expect(find.text(l10n.offlineImporting), findsOneWidget);
      final tile = tester.widget<ListTile>(
        find.byKey(const Key('voice_model_import')),
      );
      expect(tile.onTap, isNull);
    });

    testWidgets('copies the download links', (tester) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await pumpView(tester);
      await tester.tap(find.byKey(const Key('voice_model_copy_links')));
      await tester.pumpAndSettle();
      expect(copied, ['${_tiny.url}\n${_base.url}']);
      expect(find.text(l10n.commonCopied), findsOneWidget);
    });

    test('names the models', () {
      expect(voiceModelName(l10n, 'tiny'), l10n.voiceModelFast);
      expect(voiceModelName(l10n, 'base'), l10n.voiceModelBetter);
      expect(voiceModelName(l10n, 'silero-vad'), l10n.voiceModelVoiceDetection);
      expect(voiceModelName(l10n, 'base-q5_1'), l10n.voiceModelBetterCompact);
      expect(voiceModelName(l10n, 'small-q5_1'), l10n.voiceModelBest);
      expect(voiceModelName(l10n, 'large-v3-turbo-q5_0'), l10n.voiceModelLarge);
      expect(voiceModelName(l10n, 'small'), 'small');
    });

    final mirrorFailures = <String, (Object, String Function(String))>{
      'checksum': (
        WhisperChecksumException(
          'tiny',
          'bad',
          mirror: Uri.parse('https://mirror.example/models/'),
        ),
        (name) => l10n.voiceModelErrorChecksumMirror(name, 'mirror.example'),
      ),
      'server': (
        WhisperDownloadException(
          'tiny',
          'x',
          statusCode: 404,
          mirror: Uri.parse('https://mirror.example/models/'),
        ),
        (name) => l10n.voiceModelErrorServerMirror(name, 'mirror.example', 404),
      ),
      'network': (
        WhisperDownloadException(
          'tiny',
          'x',
          mirror: Uri.parse('https://mirror.example/models/'),
        ),
        (name) => l10n.voiceModelErrorNetworkMirror(name, 'mirror.example'),
      ),
    };
    for (final MapEntry(key: name, value: (error, message))
        in mirrorFailures.entries) {
      testWidgets('names the mirror of a $name failure', (tester) async {
        when(
          () => offline.download(
            any(),
            overMeteredNetwork: any(named: 'overMeteredNetwork'),
            onProgress: any(named: 'onProgress'),
          ),
        ).thenThrow(error);
        await pumpView(tester);
        await tester.tap(
          find.byTooltip(l10n.voiceModelDownloadTooltip(l10n.voiceModelFast)),
        );
        await tester.pumpAndSettle();
        expect(find.text(message(l10n.voiceModelFast)), findsOneWidget);
      });
    }
  });

  group('speech detection', () {
    late bool vadReady;

    setUp(() {
      vadReady = false;
      when(() => offline.vadModel).thenReturn(_vad);
      when(() => offline.isVadReady()).thenAnswer((_) async => vadReady);
      when(
        () => offline.downloadVoiceDetection(
          overMeteredNetwork: any(named: 'overMeteredNetwork'),
          onProgress: any(named: 'onProgress'),
        ),
      ).thenAnswer((_) async => vadReady = true);
    });

    testWidgets('is offered when speech models came without it', (
      tester,
    ) async {
      installed = {'tiny'};
      await pumpView(tester);
      expect(
        find.byKey(const Key('voice_model_voice_detection')),
        findsOneWidget,
      );
      expect(
        find.text(
          l10n.voiceModelVoiceDetectionSubtitle(
            formatStoredSize(l10n, _vad.size),
          ),
        ),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const Key('voice_model_download_voice_detection')),
      );
      await tester.pumpAndSettle();
      verify(
        () => offline.downloadVoiceDetection(
          onProgress: any(named: 'onProgress'),
        ),
      ).called(1);
      expect(
        find.text(l10n.voiceModelDownloadDone(l10n.voiceModelVoiceDetection)),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('voice_model_voice_detection')),
        findsNothing,
      );
    });

    testWidgets('is not offered without speech models', (tester) async {
      await pumpView(tester);
      expect(
        find.byKey(const Key('voice_model_voice_detection')),
        findsNothing,
      );
    });

    testWidgets('is not offered once installed', (tester) async {
      installed = {'tiny'};
      vadReady = true;
      await pumpView(tester);
      expect(
        find.byKey(const Key('voice_model_voice_detection')),
        findsNothing,
      );
    });

    testWidgets('asks before downloading it over mobile data', (tester) async {
      installed = {'tiny'};
      var calls = 0;
      when(
        () => offline.downloadVoiceDetection(
          overMeteredNetwork: any(named: 'overMeteredNetwork'),
          onProgress: any(named: 'onProgress'),
        ),
      ).thenAnswer((invocation) async {
        calls++;
        if (invocation.namedArguments[#overMeteredNetwork] != true) {
          throw const VoiceModelMeteredException();
        }
        vadReady = true;
      });
      await pumpView(tester);
      await tester.tap(
        find.byKey(const Key('voice_model_download_voice_detection')),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          l10n.voiceModelMeteredBody(
            l10n.voiceModelVoiceDetection,
            formatStoredSize(l10n, _vad.size),
          ),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('voice_model_metered_confirm')));
      await tester.pumpAndSettle();
      expect(calls, 2);
      verifyNever(
        () => offline.download(
          any(),
          overMeteredNetwork: any(named: 'overMeteredNetwork'),
          onProgress: any(named: 'onProgress'),
        ),
      );
    });

    testWidgets('copies its download link too', (tester) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await pumpView(tester);
      await tester.tap(find.byKey(const Key('voice_model_copy_links')));
      await tester.pumpAndSettle();
      expect(copied, ['${_tiny.url}\n${_base.url}\n${_vad.url}']);
    });
  });
}
