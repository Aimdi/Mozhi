import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:flutter_test/flutter_test.dart';

Cld2Result _result(
  String language, {
  int score = 1200,
  int percent = 90,
  bool reliable = true,
}) => Cld2Result(
  language: language,
  languages: [
    if (language != 'un')
      Cld2Language(language, percent: percent, score: score),
  ],
  textBytes: 20,
  reliable: reliable,
);

/// CLD2 declined (`un`) and guessed [guess].
Cld2Detection _guess(String guess, {int score = 1200, bool reliable = true}) =>
    Cld2Detection(
      precise: const Cld2Result(),
      bestEffort: _result(guess, score: score, reliable: reliable),
    );

void main() {
  group('Cld2Language, Cld2Result and Cld2Detection', () {
    test('have value equality and readable toString', () {
      const a = Cld2Language('de', percent: 92, score: 1102);
      expect(a, const Cld2Language('de', percent: 92, score: 1102));
      expect(
        a.hashCode,
        const Cld2Language('de', percent: 92, score: 1102).hashCode,
      );
      expect(a, isNot(const Cld2Language('de', percent: 92, score: 1)));
      expect(a, isNot(const Cld2Language('de', percent: 1, score: 1102)));
      expect(a, isNot(const Cld2Language('nl', percent: 92, score: 1102)));
      expect(a.toString(), 'Cld2Language(de, 92%, 1102)');

      final result = _result('de');
      expect(result, _result('de'));
      expect(result.hashCode, _result('de').hashCode);
      expect(result, isNot(_result('de', reliable: false)));
      expect(result, isNot(_result('nl')));
      expect(
        result,
        isNot(
          const Cld2Result(
            language: 'de',
            languages: [Cld2Language('de', percent: 90, score: 1200)],
          ),
        ),
      );
      expect(
        result,
        isNot(
          Cld2Result(
            language: 'de',
            languages: const [
              Cld2Language('de', percent: 90, score: 1200),
              Cld2Language('en', percent: 5, score: 100),
            ],
            textBytes: result.textBytes,
            reliable: true,
          ),
        ),
      );
      expect(result, isNot(_result('de', score: 1)));
      expect(result.toString(), contains('Cld2Result(de, ['));
      expect(_result('de', reliable: false).toString(), contains('(de?,'));

      final detection = _guess('de');
      expect(detection, _guess('de'));
      expect(detection.hashCode, _guess('de').hashCode);
      expect(detection, isNot(_guess('nl')));
      expect(
        detection,
        isNot(Cld2Detection(precise: _result('de'), bestEffort: _result('de'))),
      );
      expect(detection.toString(), startsWith('Cld2Detection(Cld2Result(un'));
    });

    test("score is the answer's score, or 0", () {
      expect(_result('de', score: 777).score, 777);
      expect(const Cld2Result().score, 0);
      expect(
        const Cld2Result(
          language: 'fr',
          languages: [
            Cld2Language('en', percent: 60, score: 900),
            Cld2Language('fr', percent: 40, score: 1500),
          ],
        ).score,
        1500,
      );
    });
  });

  group('Cld2Decision.appCode', () {
    test("maps CLD2 codes to the app's codes", () {
      expect(Cld2Decision.appCode('en'), 'en');
      expect(Cld2Decision.appCode(' de '), 'de');
      expect(Cld2Decision.appCode('iw'), 'he');
      expect(Cld2Decision.appCode('jw'), 'jv');
      expect(Cld2Decision.appCode('tw'), 'ak');
      expect(Cld2Decision.appCode('sr-ME'), 'sr');
      expect(Cld2Decision.appCode('zh'), 'zh');
      expect(Cld2Decision.appCode('zh-Hant'), 'zh-Hant');
      expect(Cld2Decision.appCode('no'), 'no');
      expect(Cld2Decision.appCode('tl'), 'tl');
      expect(Cld2Decision.appCode('haw'), 'haw');
    });

    test('is null for "no language"', () {
      for (final code in [
        '',
        ' ',
        'un',
        'xxx',
        'xx-Latn',
        'zzb',
        'zzp',
        '81',
      ]) {
        expect(Cld2Decision.appCode(code), isNull, reason: code);
      }
    });
  });

  group('Cld2Decision.choose', () {
    String? choose(
      Cld2Detection detection, {
      String? heuristic,
      Set<String> preferred = const {'de', 'es', 'fr', 'zh', 'zh-Hant', 'ja'},
    }) => Cld2Decision.choose(
      detection,
      heuristic: heuristic,
      preferred: preferred,
    );

    test("takes CLD2's reliable answer, for any language", () {
      final reliable = Cld2Detection(
        precise: _result('sw'),
        bestEffort: _result('sw'),
      );
      expect(choose(reliable), 'sw');
      // Over a disagreeing heuristic, keeping Traditional Chinese.
      expect(
        choose(
          Cld2Detection(
            precise: _result('zh-Hant'),
            bestEffort: _result('zh-Hant'),
          ),
          heuristic: 'zh',
        ),
        'zh-Hant',
      );
      expect(
        choose(
          Cld2Detection(precise: _result('iw'), bestEffort: _result('iw')),
        ),
        'he',
      );
    });

    test('ignores an unreliable or empty answer', () {
      expect(
        choose(
          Cld2Detection(
            precise: _result('sw', reliable: false),
            bestEffort: _result('sw', reliable: false),
          ),
        ),
        isNull,
      );
      expect(
        choose(
          Cld2Detection(
            precise: _result('xx-Latn'),
            bestEffort: _result('xx-Latn'),
          ),
        ),
        isNull,
      );
    });

    test('answers Uyghur from the heuristic (CLD2 has no Uyghur)', () {
      expect(
        choose(
          Cld2Detection(precise: _result('ar'), bestEffort: _result('ar')),
          heuristic: 'ug',
        ),
        'ug',
      );
    });

    test('lets a single-language script decide over a guess', () {
      // Han without kana: "中国" is guessed Japanese, "你好" Traditional.
      expect(choose(_guess('ja'), heuristic: 'zh'), 'zh');
      expect(choose(_guess('zh-Hant'), heuristic: 'zh'), 'zh');
      expect(choose(_guess('xx-Hang', reliable: false), heuristic: 'ko'), 'ko');
      expect(Cld2Decision.scriptLanguages, containsAll(['ko', 'el', 'th']));
    });

    test('takes a guess the heuristic confirms, whatever its score', () {
      expect(
        choose(_guess('ar', score: 48), heuristic: 'ar', preferred: {}),
        'ar',
      );
      expect(choose(_guess('iw', score: 113), heuristic: 'he'), 'he');
    });

    test('takes a strong guess for a preferred language', () {
      expect(choose(_guess('de', score: 2389)), 'de');
      expect(choose(_guess('es', score: Cld2Decision.minGuessScore)), 'es');
      // Shared Han characters only say "Chinese".
      expect(choose(_guess('zh-Hant')), 'zh');
      // Every language when nothing is preferred.
      expect(choose(_guess('ga', score: 1536), preferred: {}), 'ga');
    });

    test('rejects weak, unreliable and unpreferred guesses', () {
      expect(
        choose(_guess('de', score: Cld2Decision.minGuessScore - 1)),
        isNull,
      );
      expect(choose(_guess('de', reliable: false)), isNull);
      // "Sí" is guessed Irish, which the engine cannot translate from.
      expect(choose(_guess('ga', score: 1536)), isNull);
      expect(choose(_guess('un')), isNull);
      expect(choose(_guess('fr', score: 100), heuristic: 'es'), isNull);
    });
  });
}
