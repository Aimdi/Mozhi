import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper_speech/whisper_speech.dart';

void main() {
  Map<String, Object?> entry(String id, {Object? kind}) => {
    'id': id,
    'name': 'ggml-$id.bin',
    'url': 'https://models.example/ggml-$id.bin',
    'size': 10,
    'sha1': 'a' * 40,
    'kind': ?kind,
  };

  String catalog(List<Object?> models) =>
      jsonEncode({'schemaVersion': 1, 'models': models});

  group('the VAD model', () {
    test('the bundled catalog has Silero next to the speech models', () {
      final parsed = WhisperModelCatalog.parse(
        File('assets/models.json').readAsStringSync(),
      );
      expect(parsed.models.map((m) => m.id), [
        'tiny',
        'base-q5_1',
        'base',
        'small-q5_1',
        'large-v3-turbo-q5_0',
      ]);
      final vad = parsed.vad!;
      expect(vad.id, 'silero-vad');
      expect(vad.name, 'ggml-silero-v6.2.0.bin');
      expect(vad.size, 885098);
      // The same host as the speech models (a model source mirrors both).
      expect(vad.url.host, parsed.models.first.url.host);
      expect(
        vad.url,
        Uri.parse(
          'https://huggingface.co/ggml-org/whisper-vad/resolve/main/'
          'ggml-silero-v6.2.0.bin',
        ),
      );
      // Not a speech model.
      expect(parsed.model('silero-vad'), isNull);
    });

    test("the checksums are those of whisper.cpp's copy", () {
      final copy = File(
        'native/third_party/whisper.cpp/models/'
        'for-tests-silero-v6.2.0-ggml.bin',
      );
      if (!copy.existsSync()) {
        markTestSkipped('whisper.cpp is not checked out');
        return;
      }
      final bytes = copy.readAsBytesSync();
      final json =
          (jsonDecode(File('assets/models.json').readAsStringSync())
                  as Map<String, Object?>)['models']!
              as List<Object?>;
      final vad = json.cast<Map<String, Object?>>().singleWhere(
        (model) => model['kind'] == 'vad',
      );
      expect(vad['size'], bytes.length);
      expect(vad['sha1'], sha1.convert(bytes).toString());
      expect(vad['sha256'], sha256.convert(bytes).toString());
    });

    test('entries without a kind are speech models', () {
      final parsed = WhisperModelCatalog.parse(
        catalog([
          entry('tiny'),
          entry('vad', kind: 'vad'),
          entry('base', kind: 'speech'),
        ]),
      );
      expect(parsed.models.map((m) => m.id), ['tiny', 'base']);
      expect(parsed.vad?.id, 'vad');
      expect(WhisperModelCatalog.parse(catalog([entry('tiny')])).vad, isNull);
    });

    for (final (reason, models) in [
      ('an unknown kind', [entry('tiny'), entry('x', kind: 'tts')]),
      (
        'two VAD models',
        [entry('tiny'), entry('a', kind: 'vad'), entry('b', kind: 'vad')],
      ),
      ('no speech model', [entry('vad', kind: 'vad')]),
      (
        "a VAD model with a speech model's id",
        [entry('tiny'), entry('tiny', kind: 'vad')],
      ),
    ]) {
      test('rejects $reason', () {
        expect(
          () => WhisperModelCatalog.parse(catalog(models)),
          throwsFormatException,
        );
      });
    }
  });
}
