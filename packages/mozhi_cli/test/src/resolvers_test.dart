import 'package:mozhi_cli/src/errors.dart';
import 'package:mozhi_cli/src/resolvers.dart';
import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers.dart';

Matcher _usage(String text) => throwsA(
  isA<CliException>().having((e) => e.message, 'message', contains(text)),
);

void main() {
  group('resolveEngine', () {
    const providers = [ollamaProvider, claudeProvider];

    test('resolves Mozhi engines', () {
      expect(resolveEngine('google', providers).id, 'mozhi:google');
      expect(resolveEngine('mozhi:DeepL', providers).name, 'DeepL');
      expect(resolveEngine('LibreTranslate', []).id, 'mozhi:libre');
      expect(resolveEngine('bing', []).id, 'mozhi:duckduckgo');
      expect(resolveEngine('custom', []).name, 'custom');
    });

    test('resolves AI providers', () {
      expect(resolveEngine('ai', providers).id, 'ai:local');
      expect(resolveEngine('ai:Claude', providers).providerId, 'claude');
      final engine = resolveEngine('local', providers);
      expect(engine.isAi, isTrue);
      expect(engine.isLocal, isTrue);
      expect(engine.subtitle, 'gemma3');
      expect(
        resolveEngine('ai', [
          ollamaProvider.copyWith(enabled: false),
          claudeProvider,
        ]).id,
        'ai:claude',
      );
    });

    test('reports invalid specs', () {
      expect(() => resolveEngine(' ', providers), _usage('must not be empty'));
      expect(() => resolveEngine('mozhi:a b', []), _usage('Invalid Mozhi'));
      expect(() => resolveEngine('ai', []), _usage('No AI provider'));
      expect(() => resolveEngine('ai:x', []), _usage('No AI provider'));
      expect(
        () => resolveEngine('ai:x', providers),
        _usage('Unknown AI provider "x"'),
      );
    });
  });

  group('resolveLanguage', () {
    test('accepts codes and names', () {
      expect(resolveLanguage('FR').code, 'fr');
      expect(resolveLanguage('japanese').code, 'ja');
      expect(resolveLanguage('iw').code, 'he');
      expect(resolveLanguage('auto', allowAuto: true), Language.auto);
    });

    test('handles unknown input', () {
      expect(
        resolveLanguage('Pirate speak', allowCustom: true),
        const Language.custom('Pirate speak'),
      );
      final raw = resolveLanguage('xx-YY');
      expect(raw.code, 'xx-YY');
      expect(raw.isCustom, isFalse);
    });

    test('reports invalid input', () {
      expect(() => resolveLanguage(''), _usage('must not be empty'));
      expect(() => resolveLanguage('auto'), _usage('source language'));
    });
  });

  test('parseGlossary accepts several separators', () {
    expect(parseGlossary(['a=b', 'c => d', 'e: f', 'g:h=i']), {
      'a': 'b',
      'c': 'd',
      'e': 'f',
      'g:h': 'i',
    });
    expect(() => parseGlossary(['=x']), _usage('Invalid glossary'));
    expect(() => parseGlossary(['x']), _usage('Invalid glossary'));
  });

  test('parseChoice matches loosely', () {
    expect(
      parseChoice('formality', 'PREFER_more', Formality.values),
      Formality.preferMore,
    );
    expect(
      parseChoice(
        'formality',
        'formal',
        Formality.values,
        aliases: {'formal': Formality.more},
      ),
      Formality.more,
    );
    expect(
      () => parseChoice('formality', 'x', Formality.values),
      _usage('Invalid value "x" for --formality'),
    );
  });

  test('kebabCase', () {
    expect(kebabCase('preferMore'), 'prefer-more');
    expect(kebabCase('a1'), 'a1');
  });
}
