import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/platform/model_file_picker.dart';
import 'package:mozhi/voice/voice.dart';
import 'package:whisper_speech/whisper_speech.dart';

class _MockSpeechInput extends Mock implements SpeechInputService;

class _MockOfflineSpeech extends Mock implements OfflineSpeech;

class _MockPicker extends Mock implements ModelFilePicker;

final _tiny = WhisperCatalogModel(
  id: 'tiny',
  name: 'ggml-tiny.bin',
  url: Uri.parse('https://models.example/ggml-tiny.bin'),
  size: 100,
  sha1: 'a' * 40,
);
final _vad = WhisperCatalogModel(
  id: 'silero-vad',
  name: 'ggml-silero-v6.2.0.bin',
  url: Uri.parse('https://models.example/ggml-silero-v6.2.0.bin'),
  size: 10,
  sha1: 'c' * 40,
);
final _vadModel = VoiceModel(id: 'silero-vad', sizeBytes: 10, url: _vad.url);

void main() {
  late _MockSpeechInput speechInput;
  late _MockOfflineSpeech offline;
  late _MockPicker picker;
  late Set<String> installed;
  late bool vadInstalled;

  setUp(() {
    speechInput = _MockSpeechInput();
    offline = _MockOfflineSpeech();
    picker = _MockPicker();
    installed = {'tiny'};
    vadInstalled = false;
    when(speechInput.loadSettings).thenAnswer((_) async {});
    when(() => speechInput.isOfflineSupported).thenReturn(true);
    when(() => speechInput.engine)
        .thenReturn(ValueNotifier(VoiceInputEngine.whisper));
    when(speechInput.offlineModelsChanged).thenAnswer((_) async {});
    when(() => offline.isAvailable).thenReturn(true);
    when(() => offline.models).thenReturn([_tiny]);
    when(() => offline.vadModel).thenReturn(_vad);
    when(offline.isVadReady).thenAnswer((_) async => vadInstalled);
    when(offline.installed).thenAnswer((_) async => {...installed});
    when(offline.selected).thenAnswer((_) async => 'tiny');
    when(
      () => offline.downloadVoiceDetection(
        overMeteredNetwork: any(named: 'overMeteredNetwork'),
        onProgress: any(named: 'onProgress'),
      ),
    ).thenAnswer((invocation) async {
      (invocation.namedArguments[#onProgress] as void Function(double)?)?.call(
        0.5,
      );
      vadInstalled = true;
    });
    when(picker.clearCopies).thenAnswer((_) async {});
  });

  VoiceSettingsCubit build() => VoiceSettingsCubit(
    speechInput: speechInput,
    offline: offline,
    picker: picker,
  );

  test('lists the voice activity model and whether it is missing', () async {
    final cubit = build();
    await cubit.load();
    expect(cubit.state.voiceDetection, _vadModel);
    expect(cubit.state.voiceDetectionInstalled, isFalse);
    expect(cubit.state.voiceDetectionMissing, isTrue);
    // It is no speech model.
    expect(cubit.state.model('silero-vad'), isNull);
    await cubit.close();
  });

  test('nothing is missing without a speech model', () async {
    installed = {};
    final cubit = build();
    await cubit.load();
    expect(cubit.state.voiceDetectionMissing, isFalse);
    await cubit.close();
  });

  blocTest<VoiceSettingsCubit, VoiceSettingsState>(
    'downloads it on its own',
    build: build,
    act: (cubit) async {
      await cubit.load();
      await cubit.downloadVoiceDetection();
    },
    skip: 2,
    expect: () => [
      isA<VoiceSettingsState>().having((state) => state.pending, 'pending', {
        'silero-vad': VoiceModelOperation.download,
      }),
      isA<VoiceSettingsState>().having((state) => state.progress, 'progress', {
        'silero-vad': 0.5,
      }),
      isA<VoiceSettingsState>()
          .having((state) => state.voiceDetectionInstalled, 'installed', true)
          .having((state) => state.voiceDetectionMissing, 'missing', false),
      isA<VoiceSettingsState>().having(
        (state) => state.outcome,
        'outcome',
        const VoiceModelOutcome(
          model: 'silero-vad',
          operation: VoiceModelOperation.download,
          succeeded: true,
        ),
      ),
    ],
    verify: (_) {
      verify(
        () => offline.downloadVoiceDetection(
          onProgress: any(named: 'onProgress'),
        ),
      ).called(1);
      verify(speechInput.offlineModelsChanged).called(1);
    },
  );

  test('a metered network asks first', () async {
    when(
      () => offline.downloadVoiceDetection(
        overMeteredNetwork: any(named: 'overMeteredNetwork'),
        onProgress: any(named: 'onProgress'),
      ),
    ).thenThrow(const VoiceModelMeteredException());
    final cubit = build();
    await cubit.load();
    await cubit.downloadVoiceDetection();
    expect(cubit.state.outcome?.needsMeteredConsent, isTrue);
    expect(cubit.state.outcome?.model, 'silero-vad');
    await cubit.close();
  });

  test('without one there is nothing to download', () async {
    when(() => offline.vadModel).thenReturn(null);
    final cubit = build();
    await cubit.load();
    expect(cubit.state.voiceDetection, isNull);
    await cubit.downloadVoiceDetection();
    verifyNever(
      () => offline.downloadVoiceDetection(
        overMeteredNetwork: any(named: 'overMeteredNetwork'),
        onProgress: any(named: 'onProgress'),
      ),
    );
    await cubit.close();
  });

  group('import', () {
    WhisperImportResult result(List<WhisperCatalogModel> models) =>
        WhisperImportResult(
          models: [
            for (final model in models)
              WhisperImportOutcome(
                model: model,
                status: WhisperImportStatus.installed,
              ),
          ],
        );

    setUp(() {
      when(() => picker.pick(onCopying: any(named: 'onCopying'))).thenAnswer(
        (_) async => [
          PickedModelFile.local('/picked/a'),
          PickedModelFile.local('/picked/b'),
        ],
      );
    });

    test('reports the speech models, not the voice activity model', () async {
      when(() => offline.importFiles(any()))
          .thenAnswer((_) async => result([_tiny, _vad]));
      final cubit = build();
      await cubit.load();
      await cubit.importFromFiles();
      expect(cubit.state.importOutcome?.models, {
        'tiny': WhisperImportStatus.installed,
      });
      await cubit.close();
    });

    test('reports the voice activity model when it came alone', () async {
      when(() => offline.importFiles(any()))
          .thenAnswer((_) async => result([_vad]));
      final cubit = build();
      await cubit.load();
      await cubit.importFromFiles();
      expect(cubit.state.importOutcome?.models, {
        'silero-vad': WhisperImportStatus.installed,
      });
      await cubit.close();
    });
  });

  test('download errors name the mirror they came from', () {
    final mirror = Uri.parse('https://models.example.org/models/');
    expect(
      VoiceModelError.of(
        WhisperChecksumException('tiny', 'bad', mirror: mirror),
      ),
      const VoiceModelError(
        VoiceModelErrorKind.checksum,
        mirror: 'models.example.org',
      ),
    );
    expect(
      VoiceModelError.of(
        WhisperDownloadException(
          'tiny',
          'gone',
          statusCode: 404,
          mirror: mirror,
        ),
      ),
      const VoiceModelError(
        VoiceModelErrorKind.server,
        statusCode: 404,
        mirror: 'models.example.org',
      ),
    );
    expect(
      VoiceModelError.of(
        WhisperDownloadException('tiny', 'off', mirror: mirror),
      ).mirror,
      'models.example.org',
    );
    expect(
      VoiceModelError.of(const WhisperDownloadException('tiny', 'off')).mirror,
      isNull,
    );
  });
}
