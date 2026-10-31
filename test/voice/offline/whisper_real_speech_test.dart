// Voice input on a phone without Google, end to end with the real engine:
// the system recogniser is missing, so SpeechInputService falls back to
// Whisper; the microphone (a fake PcmRecorder) delivers real English speech
// as 16 kHz PCM16 chunks, as `record` does, then silence; the recording
// stops on that silence by itself and Whisper's "Fast" model (the
// catalogue's ggml-tiny.bin, imported as on the phone) writes the words
// down. Without and with the speech detector (Silero VAD).
//
// Needs what CI builds and fetches (.github/workflows/main.yaml, "Analyze
// and test"): libmozhi_whisper.so (packages/whisper_speech/tool/
// build_native_linux.sh, or WHISPER_LIBRARY_PATH), the model and the
// sample (packages/whisper_speech/tool/fetch_test_model.py, or
// WHISPER_SPEECH_MODEL and WHISPER_SPEECH_SAMPLE) and, for the speech
// detector, whisper.cpp's copy of Silero VAD (tool/fetch_native_deps.sh).
// Skipped without them.
@Timeout(Duration(minutes: 4))
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/voice/voice.dart';
import 'package:path/path.dart' as p;
import 'package:whisper_speech/whisper_speech.dart';

import '../helpers/fake_speech_recognizer.dart';

const _package = 'packages/whisper_speech';

String? _existing(String variable, String fallback) {
  final fromEnvironment = Platform.environment[variable];
  if (fromEnvironment != null && File(fromEnvironment).existsSync()) {
    return p.absolute(fromEnvironment);
  }
  final path = p.absolute(fallback);
  return File(path).existsSync() ? path : null;
}

final String? _library = _existing(
  'WHISPER_LIBRARY_PATH',
  '$_package/build/native/linux/libmozhi_whisper.so',
);
final String? _model = _existing(
  'WHISPER_SPEECH_MODEL',
  '$_package/build/test_models/ggml-tiny.bin',
);
final String? _sample = _existing(
  'WHISPER_SPEECH_SAMPLE',
  '$_package/build/test_models/speech-en.wav',
);
final String? _vad = _existing(
  'WHISPER_VAD_MODEL',
  '$_package/native/third_party/whisper.cpp/models/'
      'for-tests-silero-v6.2.0-ggml.bin',
);

Object _skip({bool vad = false}) {
  if (_library == null) return 'libmozhi_whisper.so not built';
  if (_model == null || _sample == null) {
    return 'speech model or sample missing (tool/fetch_test_model.py)';
  }
  if (vad && _vad == null) return 'Silero VAD missing (fetch_native_deps.sh)';
  return false;
}

/// The `data` chunk of a 16 kHz mono 16-bit WAV file.
Uint8List _pcm(Uint8List wav) {
  final data = ByteData.sublistView(wav);
  var offset = 12;
  while (offset + 8 <= wav.length) {
    final id = String.fromCharCodes(wav, offset, offset + 4);
    final size = data.getUint32(offset + 4, Endian.little);
    if (id == 'fmt ') {
      expect(data.getUint16(offset + 10, Endian.little), 1, reason: 'mono');
      expect(data.getUint32(offset + 12, Endian.little), 16000);
    } else if (id == 'data') {
      return Uint8List.sublistView(wav, offset + 8, offset + 8 + size);
    }
    offset += 8 + size + (size.isOdd ? 1 : 0);
  }
  throw const FormatException('No data chunk');
}

/// A microphone that plays [pcm] in 100 ms chunks (3,200 bytes; one in
/// three is a byte longer, so chunks split samples as on a phone), then
/// silence until it is stopped.
class _PlayingRecorder implements PcmRecorder {
  new(this.pcm);

  final Uint8List pcm;
  StreamController<Uint8List>? _controller;
  int starts = 0;
  int stops = 0;

  @override
  Future<bool> hasPermission({bool request = true}) async => true;

  @override
  Future<Stream<Uint8List>> start() async {
    starts++;
    final controller = _controller = StreamController<Uint8List>();
    unawaited(_play(controller));
    return controller.stream;
  }

  Future<void> _play(StreamController<Uint8List> controller) async {
    var offset = 0;
    var chunk = 0;
    // At most a minute: the recording must end on the silence by itself.
    for (var sent = 0; sent < 600 && !controller.isClosed; sent++) {
      final Uint8List bytes;
      if (offset < pcm.length) {
        final size = 3200 + (chunk++ % 3 == 0 ? 1 : 0);
        final end = offset + size > pcm.length ? pcm.length : offset + size;
        bytes = Uint8List.sublistView(pcm, offset, end);
        offset = end;
      } else {
        bytes = Uint8List(3200);
      }
      controller.add(bytes);
      // Let the adapter (and the speech detector's isolate) keep up.
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  @override
  Future<void> stop() async {
    stops++;
    unawaited(_controller?.close());
  }

  @override
  Future<void> dispose() async {}
}

String _words(String text) => text
    .toLowerCase()
    .replaceAll(RegExp("[^a-z' ]+"), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late WhisperSpeech whisper;
  late OfflineSpeech offline;

  Future<void> install({required bool vad}) async {
    root = Directory.systemTemp.createTempSync('mozhi_voice_real_');
    addTearDown(() => root.deleteSync(recursive: true));
    final catalog = WhisperModelCatalog.parse(
      File('$_package/assets/models.json').readAsStringSync(),
    );
    whisper = WhisperSpeech(
      catalog: catalog,
      root: root,
      engine: createWhisperEngine(libraryPath: _library),
      vadEngine: createWhisperVadEngine(libraryPath: _library),
      isAvailable: true,
    );
    addTearDown(whisper.dispose);
    offline = OfflineSpeech(whisper: whisper, store: MemoryStore());
    // "Import from files": checked against the catalogue as on the phone.
    final result = await offline.importFiles([_model!, if (vad) _vad!]);
    expect(
      result.installed.map((model) => model.id),
      unorderedEquals(['tiny', if (vad) 'silero-vad']),
    );
    expect(await offline.isReady(), isTrue);
    expect(await offline.isVadReady(), vad);
  }

  /// [phrases]: transcribed phrase by phrase (cut at pauses), where a
  /// short phrase can come out a little differently: the words are
  /// checked, not whole sentences.
  Future<void> speakAndCheck({bool phrases = false}) async {
    final recorder = _PlayingRecorder(_pcm(File(_sample!).readAsBytesSync()));
    // A phone without Google: no speech recognition service.
    final system = FakeSpeechRecognizer()..initResult = false;
    final service = SpeechInputService(
      store: MemoryStore(),
      adapter: system,
      offlineAdapter: WhisperSpeechRecognizerAdapter(
        speech: offline,
        recorder: recorder,
      ),
      platformSupported: true,
      onDeviceSupported: true,
    );
    addTearDown(service.dispose);
    final states = <SpeechInputState>[];
    final partials = <String>[];
    final finished = Completer<SpeechInputResult>();
    service.states.listen(states.add);
    service.results.listen((result) {
      if (!result.isFinal) {
        partials.add(result.text);
      } else if (!finished.isCompleted) {
        finished.complete(result);
      }
    });

    expect(await service.listen('en'), isTrue);
    final result = await finished.future.timeout(const Duration(minutes: 3));
    // The states that follow the result.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // The system recogniser was tried first, then Whisper took over.
    expect(system.initCalls, 1);
    expect(system.requests, isEmpty);
    // Recording ended on the silence after the speech, not at a limit.
    expect(recorder.stops, 1);
    expect(states.whereType<SpeechInputListening>(), isNotEmpty);
    expect(states.whereType<SpeechInputError>(), isEmpty);
    expect(states.last, const SpeechInputIdle());
    final heard = _words(result.text);
    if (phrases) {
      for (final word in ['fellow', 'americans', 'ask', 'country']) {
        expect(heard.split(' '), contains(word), reason: heard);
      }
    } else {
      expect(heard, contains('ask not what your country'));
      expect(heard, contains('what you can do for your country'));
    }
    // Whisper heard English; "en" was asked for.
    expect(result.language, 'en');
    // What was heard, in the CI log.
    // ignore: avoid_print
    print('Heard: ${result.text} (partial results: ${partials.length})');
  }

  test('without the speech detector: one pass after the pause', () async {
    await install(vad: false);
    await speakAndCheck();
  }, skip: _skip());

  test('with the speech detector: phrase by phrase', () async {
    await install(vad: true);
    await speakAndCheck(phrases: true);
  }, skip: _skip(vad: true));
}
