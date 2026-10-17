import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_models.dart';

void main() {
  final models = [
    for (final code in ['de', 'es', 'zh', 'zh_hant', 'nb', 'no'])
      for (final (source, target) in [('en', code), (code, 'en')])
        FakeModel(source, target),
    FakeModel('en', 'az'),
    FakeModel('hbs', 'en'),
    FakeModel('en', 'hr'),
    FakeModel('en', 'sr'),
  ];
  final router = ModelRouter(catalogOf(models));

  group('languages', () {
    test('both directions, reported as app codes', () {
      expect(router.languages, {
        'en',
        'de',
        'es',
        'zh',
        'zh-Hant',
        'no',
        'hr',
        'sr',
      });
      expect(router.sourceLanguages, isNot(contains('az')));
      expect(router.targetLanguages, contains('az'));
      expect(router.sourceLanguages, isNot(contains('hbs')));
    });
  });

  group('codes', () {
    test('map app codes onto model codes', () {
      expect(router.sourceCode('de'), 'de');
      expect(router.sourceCode('de-CH'), 'de');
      expect(router.sourceCode('ES_419'), 'es');
      expect(router.sourceCode('zh-CN'), 'zh');
      expect(router.sourceCode('zh-Hans'), 'zh');
      expect(router.sourceCode('zh-TW'), 'zh_hant');
      expect(router.sourceCode('zh-Hant-HK'), 'zh_hant');
      expect(router.targetCode('zh_hant'), 'zh_hant');
      expect(router.sourceCode('no'), 'nb');
      expect(router.sourceCode('nb'), 'nb');
      expect(router.targetCode('en-GB'), 'en');
    });

    test('Croatian and Serbian sources use Serbo-Croatian', () {
      expect(router.sourceCode('hr'), 'hbs');
      expect(router.sourceCode('sr-Latn'), 'hbs');
      expect(router.targetCode('hr'), 'hr');
    });

    test('unknown, auto and excluded codes are null', () {
      for (final code in ['', ' ', 'auto', 'und', 'fr', 'zh-yue', 'yue']) {
        expect(router.sourceCode(code), isNull, reason: code);
        expect(router.targetCode(code), isNull, reason: code);
      }
      expect(router.sourceCode('az'), isNull);
    });

    test('reportedCode', () {
      expect(ModelRouter.reportedCode('zh_hant'), 'zh-Hant');
      expect(ModelRouter.reportedCode('nb'), 'no');
      expect(ModelRouter.reportedCode('de'), 'de');
    });
  });

  group('route', () {
    List<String>? pairs(String source, String target) =>
        router.route(source, target)?.map((m) => m.pair).toList();

    test('uses the direct model to or from English', () {
      expect(pairs('en', 'de'), ['en-de']);
      expect(pairs('de', 'en'), ['de-en']);
      expect(pairs('hr', 'en'), ['hbs-en']);
    });

    test('pivots through English otherwise', () {
      expect(pairs('es', 'de'), ['es-en', 'en-de']);
      expect(pairs('zh-TW', 'zh-CN'), ['zh_hant-en', 'en-zh']);
      expect(pairs('sr', 'hr'), ['hbs-en', 'en-hr']);
      expect(pairs('de', 'az'), ['de-en', 'en-az']);
    });

    test('is empty for the same language', () {
      expect(pairs('de', 'de-AT'), isEmpty);
      expect(pairs('no', 'nb'), isEmpty);
    });

    test('is null for unsupported languages', () {
      expect(pairs('fr', 'de'), isNull);
      expect(pairs('de', 'fr'), isNull);
      expect(pairs('az', 'de'), isNull);
    });

    test('is null when a pivot leg is missing', () {
      final partial = ModelRouter(
        catalogOf([FakeModel('de', 'en'), FakeModel('es', 'en')]),
      );
      expect(partial.route('de', 'es'), isNull);
    });
  });

  group('modelsFor', () {
    test('lists both directions', () {
      expect(router.modelsFor('de').map((m) => m.pair), ['de-en', 'en-de']);
      expect(router.modelsFor('zh-TW').map((m) => m.pair), [
        'zh_hant-en',
        'en-zh_hant',
      ]);
      expect(router.modelsFor('hr').map((m) => m.pair), ['hbs-en', 'en-hr']);
      expect(router.modelsFor('az').map((m) => m.pair), ['en-az']);
    });

    test('is empty for English and unknown codes', () {
      expect(router.modelsFor('en'), isEmpty);
      expect(router.modelsFor('fr'), isEmpty);
      expect(router.modelsFor('auto'), isEmpty);
    });
  });
}
