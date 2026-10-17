// End-to-end proof with Mozilla's real models and the native engine.
//
// Skipped unless BERGAMOT_TEST_MODELS=1. Needs network access to
// storage.googleapis.com (~75 MB: en-de, de-en, es-en, en-es) and the
// native library (tool/build_native_linux.sh, or BERGAMOT_LIBRARY_PATH).
// Models are cached in BERGAMOT_TEST_CACHE (default build/test_models).
//
//   BERGAMOT_TEST_MODELS=1 flutter test test/src/bergamot_integration_test.dart
import 'dart:io';

import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:bergamot_translator/src/engine/ffi/isolate_engine.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../helpers/native_library.dart';

void main() {
  final enabled = Platform.environment['BERGAMOT_TEST_MODELS'] == '1';
  final skip = enabled
      ? nativeLibrarySkip()
      : 'Set BERGAMOT_TEST_MODELS=1 to download and run the real models';

  late ModelCatalog catalog;
  late IsolateBergamotEngine engine;
  late BergamotTranslator translator;
  late http.Client client;

  setUpAll(() async {
    if (skip != false) return;
    catalog = ModelCatalog.parse(
      File('assets/catalog.json').readAsStringSync(),
    );
    client = http.Client();
    engine = IsolateBergamotEngine(libraryPath: nativeLibraryPath());
    translator = BergamotTranslator(
      catalog: catalog,
      root: Directory(
        Platform.environment['BERGAMOT_TEST_CACHE'] ?? 'build/test_models',
      ),
      httpClient: client,
      engine: engine,
      isAvailable: true,
      isMeteredConnection: () async => false,
    );
    final stopwatch = Stopwatch()..start();
    await translator.downloadLanguage('de');
    await translator.downloadLanguage('es');
    _report('download+verify+install (or cache hit)', stopwatch.elapsed);
  });

  tearDownAll(() async {
    if (skip != false) return;
    await translator.dispose();
    client.close();
  });

  test('installed files match the catalog checksums', () async {
    final installed = await translator.models.installed();
    expect(
      installed.map((m) => m.pair),
      containsAll(['de-en', 'en-de', 'en-es', 'es-en']),
    );
    for (final model in installed) {
      final entry = catalog.model(model.source, model.target)!;
      for (final MapEntry(key: kind, value: path) in model.files.entries) {
        final digest = await sha256.bind(File(path).openRead()).first;
        expect(
          digest.toString(),
          entry.files[kind]!.uncompressedSha256,
          reason: path,
        );
      }
      debugPrint(
        'model ${model.pair} (${entry.architecture}): download '
        '${_mb(entry.downloadSize)}, installed ${_mb(model.sizeBytes)}',
      );
    }
  }, skip: skip);

  test('en -> de', () async {
    await engine.dispose(); // Measure a cold start.
    final stopwatch = Stopwatch()..start();
    final german = await translator.translate(
      'Hello, how are you?',
      source: 'en',
      target: 'de',
    );
    _report(
      'cold en->de (isolate + model load + 1 sentence)',
      stopwatch.elapsed,
    );
    debugPrint('en->de: "Hello, how are you?" -> "$german"');
    expect(german.toLowerCase(), anyOf(contains('hallo'), contains('wie')));
  }, skip: skip);

  test('de -> en', () async {
    final english = await translator.translate(
      'Wie geht es dir? Das Wetter ist heute schön.',
      source: 'de',
      target: 'en',
    );
    debugPrint('de->en: "$english"');
    expect(english.toLowerCase(), contains('how'));
  }, skip: skip);

  test('es -> de pivots through English', () async {
    final german = await translator.translate(
      'Hola, ¿cómo estás? Me gusta mucho este libro.',
      source: 'es',
      target: 'de',
    );
    debugPrint('es->en->de: "$german"');
    expect(german.toLowerCase(), anyOf(contains('buch'), contains('wie')));
  }, skip: skip);

  test('auto source and long text keep paragraphs', () async {
    final german = await translator.translate(
      'This is the first paragraph. It has two sentences.\n\n'
      'And this is the second paragraph!',
      source: 'auto',
      target: 'de',
    );
    debugPrint('auto->de: "$german"');
    expect(german.split('\n\n'), hasLength(2));
  }, skip: skip);

  test(
    '~500 words en -> de (warm)',
    () async {
      final words = _longText.split(RegExp(r'\s+')).length;
      // Warm up (model already loaded by the earlier tests).
      await translator.translate('Warm up.', source: 'en', target: 'de');
      final stopwatch = Stopwatch()..start();
      final german = await translator.translate(
        _longText,
        source: 'en',
        target: 'de',
      );
      final elapsed = stopwatch.elapsed;
      _report('$words words en->de', elapsed);
      debugPrint(
        '  ${(words / (elapsed.inMilliseconds / 1000)).toStringAsFixed(0)} '
        'words/s; output ${german.split(RegExp(r'\s+')).length} words; '
        'starts "${german.substring(0, 120)}..."',
      );
      expect(german.length, greaterThan(_longText.length ~/ 2));

      final pivot = Stopwatch()..start();
      await translator.translate(_longText, source: 'en', target: 'es');
      _report(
        '$words words en->es (second model, includes its load)',
        pivot.elapsed,
      );
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

void _report(String what, Duration elapsed) {
  debugPrint('timing: $what: ${elapsed.inMilliseconds} ms');
}

String _mb(int bytes) => '${(bytes / 1e6).toStringAsFixed(1)} MB';

// About 500 words of varied, non-repeating sentences (repeats would hit the
// engine's sentence cache).
const _longText = '''
Machine translation has changed a great deal over the last decade. Early systems relied on hand-written rules and large dictionaries, and their output often sounded stiff and unnatural. Statistical methods improved the situation by learning from millions of sentence pairs, but they still struggled with long sentences and rare words.

Neural networks brought the next big step. Instead of translating phrase by phrase, a neural model reads the whole sentence and produces a new one in the target language. The results are usually more fluent, and the models keep getting smaller and faster.

Small models matter because they can run on a phone without sending any text to a server. When translation happens on the device, private messages, medical letters and business documents never leave the user's hands. This is especially important for journalists, lawyers and anyone who travels to places with poor network coverage.

Running a model on a phone is not free, of course. The model has to be downloaded once, it needs some storage, and translating a long document uses the processor for a few seconds. Engineers therefore compress the weights to eight-bit integers and prune the vocabulary that the decoder considers for each sentence.

Our application lets people choose between several engines. Some of them are remote servers that the user controls, others are commercial services, and one runs entirely offline. The offline engine is the slowest to set up but the most private, because nothing is ever transmitted.

To make the experience pleasant, the app downloads language packs only when the user asks for them, preferably over a wireless connection. Each pack contains two models, one for each direction, so that a language can be both the source and the target. When neither side of a pair is English, the text is translated into English first and then into the target language.

Quality is measured with automatic metrics and with human reviewers. Automatic scores are cheap and repeatable, while people notice problems that numbers miss, such as the wrong level of politeness or a joke that falls flat. Both kinds of evaluation are needed before a new model is released to everyone.

There are still many open problems. Names, numbers and units must be preserved exactly. Formatting such as lists and paragraphs should survive the round trip. Some languages have very little training data, and their speakers deserve the same quality as everyone else.

Despite these challenges, offline translation is already useful today. A traveller can read a menu, a student can understand a scientific abstract, and a volunteer can help a refugee fill in a form, all without an internet connection. That is a remarkable achievement for software that fits in the pocket.

The next improvements will probably come from better training data, smarter compression and hardware that is designed for this kind of arithmetic. Whatever happens, the goal remains the same: clear, faithful translation that respects the privacy of the people who rely on it.
''';
