import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/voice/voice.dart';
import 'package:whisper_speech/whisper_speech.dart';

class _MockSpeechInput extends Mock implements SpeechInputService;

class _MockOfflineSpeech extends Mock implements OfflineSpeech;

final _tiny = WhisperCatalogModel(
  id: 'tiny',
  name: 'ggml-tiny.bin',
  url: Uri.parse('https://models.example/ggml-tiny.bin'),
  size: 100,
  sha1: 'a' * 40,
);

/// Cancelling a speech model download ([VoiceSettingsCubit.cancel]).
void main() {
  late _MockSpeechInput speechInput;
  late _MockOfflineSpeech offline;

  /// The running download (made in the test's zone: errors do not cross
  /// zones).
  Completer<void>? download;
  late List<String> cancelled;

  setUp(() {
    speechInput = _MockSpeechInput();
    offline = _MockOfflineSpeech();
    download = null;
    cancelled = [];
    when(() => speechInput.loadSettings()).thenAnswer((_) async {});
    when(() => speechInput.isOfflineSupported).thenReturn(true);
    when(() => speechInput.engine)
        .thenReturn(ValueNotifier(VoiceInputEngine.system));
    when(() => speechInput.offlineModelsChanged()).thenAnswer((_) async {});
    when(() => offline.isAvailable).thenReturn(true);
    when(() => offline.models).thenReturn([_tiny]);
    when(() => offline.memory).thenReturn(null);
    when(() => offline.vadModel).thenReturn(null);
    when(() => offline.engineBuild).thenReturn(null);
    when(offline.isVadReady).thenAnswer((_) async => false);
    when(() => offline.installed()).thenAnswer((_) async => <String>{});
    when(() => offline.selected()).thenAnswer((_) async => null);
    when(
      () => offline.download(
        any(),
        overMeteredNetwork: any(named: 'overMeteredNetwork'),
        onProgress: any(named: 'onProgress'),
      ),
    ).thenAnswer((invocation) async {
      final progress =
          invocation.namedArguments[#onProgress] as void Function(double)?;
      progress?.call(0.3);
      await (download = Completer<void>()).future;
    });
    when(() => offline.cancelDownload(any())).thenAnswer((invocation) {
      cancelled.add(invocation.positionalArguments.single as String);
      final running = download;
      if (running != null && !running.isCompleted) {
        running.completeError(const WhisperDownloadCancelledException('tiny'));
      }
    });
  });

  VoiceSettingsCubit build() =>
      VoiceSettingsCubit(speechInput: speechInput, offline: offline);

  blocTest<VoiceSettingsCubit, VoiceSettingsState>(
    'stops the download without an outcome or an error',
    build: build,
    act: (cubit) async {
      await cubit.load();
      final running = cubit.download('tiny');
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.pending, {'tiny': VoiceModelOperation.download});
      expect(cubit.state.progress, {'tiny': 0.3});
      cubit.cancel('tiny');
      await running;
    },
    errors: () => isEmpty,
    verify: (cubit) {
      expect(cancelled, ['tiny']);
      expect(cubit.state.pending, isEmpty);
      expect(cubit.state.progress, isEmpty);
      expect(cubit.state.outcome, isNull);
      expect(cubit.state.installed, isEmpty);
    },
  );

  blocTest<VoiceSettingsCubit, VoiceSettingsState>(
    'does nothing when the model is not downloading',
    build: build,
    act: (cubit) async {
      await cubit.load();
      cubit.cancel('tiny');
    },
    verify: (_) => expect(cancelled, isEmpty),
  );

  test('a cancelled download is classified as cancelled', () {
    expect(
      VoiceModelError.of(const WhisperDownloadCancelledException('tiny')).kind,
      VoiceModelErrorKind.cancelled,
    );
  });
}
