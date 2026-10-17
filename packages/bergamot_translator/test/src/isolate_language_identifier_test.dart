import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:bergamot_translator/src/engine/engine_factory_stub.dart'
    as stub;
import 'package:bergamot_translator/src/engine/ffi/bindings.dart';
import 'package:bergamot_translator/src/engine/ffi/isolate_language_identifier.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/native_library.dart';

/// One call a fake `mozhi_bergamot_detect` received.
typedef _Call = ({String text, int length, String? hints, int flags});

void _setCode(Array<Uint8> field, String code) {
  for (var i = 0; i < BergamotBindings.codeLength; i++) {
    field[i] = i < code.length ? code.codeUnitAt(i) : 0;
  }
}

/// A fake `mozhi_bergamot_detect` answering [precise] for flags 0 and
/// [guess] for best effort, recording its calls in [calls].
DetectFunction _fakeDetect(
  List<_Call> calls, {
  List<(String, int, int)> precise = const [],
  List<(String, int, int)> guess = const [],
}) => (text, length, hints, flags, out) {
  calls.add((
    text: utf8.decode(text.asTypedList(length)),
    length: length,
    hints: hints == nullptr ? null : hints.toDartString(),
    flags: flags,
  ));
  expect(text[length], 0, reason: 'NUL-terminated');
  final languages = flags == 0 ? precise : guess;
  final detection = out.ref;
  _setCode(detection.language, languages.isEmpty ? 'un' : languages[0].$1);
  for (var i = 0; i < 3; i++) {
    final slot = detection.languages[i];
    final (code, percent, score) = i < languages.length
        ? languages[i]
        : ('un', 0, 0);
    _setCode(slot.code, code);
    slot
      ..percent = percent
      ..score = score;
  }
  detection
    ..textBytes = length
    ..reliable = languages.isEmpty ? 0 : 1;
  return 1;
};

void main() {
  group('identifyWith', () {
    test('runs both passes over the UTF-8 text and reads the results', () {
      final calls = <_Call>[];
      final detection = identifyWith(
        _fakeDetect(calls, guess: [('es', 94, 1820), ('pt', 4, 300)]),
        () => nullptr,
        'Hola, ¿cómo estás?',
      );

      expect(calls, hasLength(2));
      expect(calls.map((c) => c.flags), [0, BergamotBindings.detectBestEffort]);
      expect(calls.first.text, 'Hola, ¿cómo estás?');
      expect(calls.first.length, utf8.encode('Hola, ¿cómo estás?').length);
      expect(calls.first.hints, isNull);
      expect(
        detection,
        Cld2Detection(
          precise: Cld2Result(textBytes: calls.first.length),
          bestEffort: Cld2Result(
            language: 'es',
            languages: const [
              Cld2Language('es', percent: 94, score: 1820),
              Cld2Language('pt', percent: 4, score: 300),
            ],
            textBytes: calls.first.length,
            reliable: true,
          ),
        ),
      );
    });

    test('passes hints and handles empty text', () {
      final calls = <_Call>[];
      final detection = identifyWith(
        _fakeDetect(calls, precise: [('de', 92, 1102)]),
        () => nullptr,
        '',
        hints: 'de,en',
      );
      expect(calls.map((c) => c.hints), ['de,en', 'de,en']);
      expect(calls.first.length, 0);
      expect(detection.precise.language, 'de');
      expect(detection.precise.reliable, isTrue);
      expect(detection.bestEffort.language, 'un');
    });

    test('reports native failures with the last error', () {
      int failing(
        Pointer<Uint8> text,
        int length,
        Pointer<Utf8> hints,
        int flags,
        Pointer<NativeDetection> out,
      ) => 0;
      final message = 'text and out are required'.toNativeUtf8();
      addTearDown(() => malloc.free(message));

      expect(
        () => identifyWith(failing, () => message, 'x'),
        throwsA(
          isA<BergamotEngineException>().having(
            (e) => e.message,
            'message',
            'detect: text and out are required',
          ),
        ),
      );
      expect(
        () => identifyWith(failing, () => nullptr, 'x'),
        throwsA(
          isA<BergamotEngineException>().having(
            (e) => e.message,
            'message',
            'detect: unknown error',
          ),
        ),
      );
    });
  });

  group('identifyWithLibrary', () {
    test('is null when the library cannot be loaded', () {
      expect(
        identifyWithLibrary('/nonexistent/libmozhi_bergamot.so', 'Hi'),
        isNull,
      );
    });
  });

  group('IsolateLanguageIdentifier', () {
    test('is null, and stays null, without a library', () async {
      final identifier = IsolateLanguageIdentifier(
        libraryPath: '/nonexistent/libmozhi_bergamot.so',
      );
      expect(await identifier.identify('Guten Morgen'), isNull);
      expect(await identifier.identify('Guten Morgen'), isNull);
    });

    test('is what createNativeLanguageIdentifier makes', () {
      expect(
        createNativeLanguageIdentifier(),
        isA<IsolateLanguageIdentifier>(),
      );
      expect(
        (createNativeLanguageIdentifier(
          libraryPath: '/x.so',
        ) as IsolateLanguageIdentifier).libraryPath,
        '/x.so',
      );
    });
  });

  group('web stub', () {
    test('has no native identifier', () async {
      final identifier = stub.createNativeLanguageIdentifier();
      expect(identifier, isA<stub.UnsupportedNativeLanguageIdentifier>());
      expect(await identifier.identify('Guten Morgen'), isNull);
    });
  });

  group('with the native library', () {
    final skip = nativeLibrarySkip();
    late IsolateLanguageIdentifier identifier;

    setUp(() {
      identifier = IsolateLanguageIdentifier(libraryPath: nativeLibraryPath());
    });

    Future<String?> identify(String text) async {
      final detection = await identifier.identify(text);
      expect(detection, isNotNull, reason: 'the library has the identifier');
      return Cld2Decision.choose(
        detection!,
        heuristic: LanguageIdentifier.identify(text),
      );
    }

    test('identifies short greetings', () async {
      const samples = {
        'Hola, ¿cómo estás?': 'es',
        'Guten Morgen': 'de',
        'Добрый день': 'ru',
        'こんにちは': 'ja',
        'مرحبا': 'ar',
        'Bonjour tout le monde': 'fr',
        'Hello, how are you?': 'en',
        'Dziękuję bardzo': 'pl',
        '我們今天去吃飯吧': 'zh-Hant',
        '我们今天去吃饭吧': 'zh',
        'שלום': 'he',
        'Привіт, як справи?': 'uk',
        'ياخشىمۇسىز': 'ug',
      };
      for (final MapEntry(key: text, value: language) in samples.entries) {
        expect(await identify(text), language, reason: text);
      }
    }, skip: skip);

    test('declines text without letters, and finds the main language of '
        'mixed text', () async {
      expect(await identify('1234 !!! ...'), isNull);
      expect(
        await identify(
          'Das ist ein langer deutscher Satz über das Wetter von heute, '
          'and a few English words.',
        ),
        'de',
      );
    }, skip: skip);

    test("reads CLD2's details", () async {
      final detection = (await identifier.identify('Guten Morgen'))!;
      expect(detection.precise.language, 'de');
      expect(detection.precise.reliable, isTrue);
      expect(detection.precise.languages.first.code, 'de');
      expect(
        detection.precise.languages.first.percent,
        inInclusiveRange(1, 100),
      );
      expect(detection.precise.score, greaterThan(0));
      expect(detection.precise.textBytes, greaterThan(0));
      // "Danke" alone: CLD2 declines, its guess is German.
      final short = (await identifier.identify('Danke'))!;
      expect(short.precise.language, 'un');
      expect(short.bestEffort.language, 'de');
    }, skip: skip);

    test('hints bias the result', () async {
      // Czech and Slovak share these words; CLD2 says Czech.
      final plain = (await identifier.identify('Dobré ráno'))!;
      final hinted = (await identifier.identify('Dobré ráno', hints: ['sk']))!;
      expect(plain.precise.language, 'cs');
      expect(hinted.precise.language, 'sk');
      final guess = (await identifier.identify('Godmorgon', hints: ['sv']))!;
      expect(guess.bestEffort.language, 'sv');
    }, skip: skip);

    test('runs on many threads at once', () async {
      final results = await Future.wait([
        for (var i = 0; i < 8; i++)
          identifier.identify(i.isEven ? 'Guten Morgen' : 'Добрый день'),
      ]);
      expect(
        results.map((d) => d!.precise.language),
        List.generate(8, (i) => i.isEven ? 'de' : 'ru'),
      );
    }, skip: skip);

    test('measures latency', () async {
      final path = nativeLibraryPath();
      const sentence = 'Hola, ¿cómo estás? Me gusta mucho este libro.';
      final page = List.filled(90, sentence).join(' ').substring(0, 4096);
      // In this isolate: both CLD2 passes, no isolate.
      identifyWithLibrary(path, sentence);
      for (final (name, text) in [('sentence', sentence), ('4 KB', page)]) {
        const runs = 200;
        final watch = Stopwatch()..start();
        for (var i = 0; i < runs; i++) {
          identifyWithLibrary(path, text);
        }
        debugPrint(
          'timing: CLD2 both passes, $name, in-process: '
          '${(watch.elapsedMicroseconds / runs).toStringAsFixed(0)} us '
          '(includes opening the loaded library)',
        );
      }
      // Through Isolate.run, as the app calls it.
      await identifier.identify(sentence);
      const runs = 20;
      final watch = Stopwatch()..start();
      for (var i = 0; i < runs; i++) {
        await identifier.identify(sentence);
      }
      debugPrint(
        'timing: IsolateLanguageIdentifier.identify, sentence: '
        '${(watch.elapsedMicroseconds / runs / 1000).toStringAsFixed(2)} ms',
      );
    }, skip: skip);

    test('decides well on short phrases (test/fixtures)', () async {
      final rows = [
        for (final line in File(
          'test/fixtures/language_id_phrases.tsv',
        ).readAsLinesSync())
          if (line.isNotEmpty && !line.startsWith('#')) line.split('\t'),
      ];
      var right = 0;
      var wrong = 0;
      var none = 0;
      var cld2Right = 0;
      var cld2Wrong = 0;
      var heuristicRight = 0;
      var heuristicWrong = 0;
      final mistakes = <String>[];
      for (final [expected, text] in rows) {
        final accepted = expected.split('|');
        final detection = (await identifier.identify(text))!;
        final heuristic = LanguageIdentifier.identify(text);
        final chosen = Cld2Decision.choose(
          detection,
          heuristic: heuristic,
          preferred: _offlineSources,
        );
        if (chosen == null) {
          none++;
        } else if (accepted.contains(chosen)) {
          right++;
        } else {
          wrong++;
          mistakes.add('$text -> $chosen ($expected)');
        }
        final cld2 = detection.precise.reliable
            ? Cld2Decision.appCode(detection.precise.language)
            : null;
        if (cld2 != null) {
          accepted.contains(cld2) ? cld2Right++ : cld2Wrong++;
        }
        if (heuristic != null) {
          accepted.contains(heuristic) ? heuristicRight++ : heuristicWrong++;
        }
      }
      String share(int n) => '${(100 * n / rows.length).round()}%';
      debugPrint(
        'language id on ${rows.length} phrases: right ${share(right)}, '
        'wrong ${share(wrong)}, undetermined ${share(none)}; CLD2 alone: '
        'right ${share(cld2Right)}, wrong ${share(cld2Wrong)}; heuristic '
        'alone: right ${share(heuristicRight)}, wrong '
        '${share(heuristicWrong)}\n'
        '  mistakes: ${mistakes.join('; ')}',
      );
      expect(right / rows.length, greaterThan(0.75));
      expect(wrong / rows.length, lessThan(0.12));
    }, skip: skip);
  });
}

/// The source languages of the bundled catalog.
final Set<String> _offlineSources = ModelRouter(
  ModelCatalog.parse(File('assets/catalog.json').readAsStringSync()),
).sourceLanguages;
