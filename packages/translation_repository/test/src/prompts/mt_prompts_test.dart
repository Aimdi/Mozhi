import 'package:llm_api/llm_api.dart';
import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

const english = Language(code: 'en', name: 'English');
const german = Language(code: 'de', name: 'German');
const czech = Language(code: 'cs', name: 'Czech');
const japanese = Language(code: 'ja', name: 'Japanese');
const french = Language(code: 'fr', name: 'French');

TranslationRequest request({
  String text = 'Hello, world!',
  Language source = english,
  Language target = german,
  TranslationOptions options = const TranslationOptions(),
}) => TranslationRequest(
  text: text,
  source: source,
  target: target,
  options: options,
);

String single(PromptProfile profile, TranslationRequest r) {
  final messages = MtPrompts.translate(profile, r);
  expect(messages, hasLength(1));
  expect(messages.single.role, LlmRole.user);
  expect(messages.single.images, isEmpty);
  return messages.single.content;
}

void main() {
  group('MtPrompts.translate', () {
    group('TranslateGemma', () {
      String gemma(TranslationRequest r) =>
          single(PromptProfile.translateGemma, r);

      test('uses the model card template verbatim', () {
        expect(
          gemma(
            request(
              text: 'V nejhorším případě i k prasknutí čočky.',
              source: czech,
            ),
          ),
          'You are a professional Czech (cs) to German (de) translator. Your '
          'goal is to accurately convey the meaning and nuances of the '
          'original Czech text while adhering to German grammar, '
          'vocabulary, and cultural sensitivities.\n'
          'Produce only the German translation, without any additional '
          'explanations or commentary. Please translate the following Czech '
          'text into German:\n\n\n'
          'V nejhorším případě i k prasknutí čočky.',
        );
      });

      test('uses catalogue English names and normalised codes', () {
        final prompt = gemma(
          request(
            source: const Language(code: 'iw', name: 'עברית'),
            target: const Language(code: 'zh_tw', name: '繁體中文'),
          ),
        );
        expect(
          prompt,
          startsWith(
            'You are a professional Hebrew (he) to Chinese (Traditional) '
            '(zh-TW) translator.',
          ),
        );
        expect(prompt, contains('original Hebrew text'));
        expect(prompt, contains('adhering to Chinese (Traditional) grammar'));
        expect(prompt, contains('the following Hebrew text into Chinese'));
      });

      test('falls back to the given name or code for unknown languages', () {
        expect(
          gemma(
            request(
              source: const Language(code: 'qq', name: 'Qlingon'),
            ),
          ),
          startsWith('You are a professional Qlingon (qq) to German (de)'),
        );
        expect(
          gemma(
            request(
              target: const Language(code: 'qq', name: ''),
            ),
          ),
          startsWith('You are a professional English (en) to qq translator.'),
        );
      });

      test('keeps the text unchanged and adds nothing else', () {
        const text = '  Line one\n\n- item {name} </source>\n';
        final prompt = gemma(
          request(
            text: text,
            options: const TranslationOptions(
              formality: Formality.more,
              context: 'secret context',
              instructions: 'Shorter.',
              glossary: {'Line': 'Zeile'},
            ),
          ),
        );
        expect(prompt, endsWith(':\n\n\n$text'));
        expect(prompt, isNot(contains('secret context')));
        expect(prompt, isNot(contains('Shorter.')));
        expect(prompt, isNot(contains('Zeile')));
        expect(prompt, isNot(contains('[[lang')));
        expect(prompt, isNot(contains('<source>')));
      });

      test('an auto source drops the source slots', () {
        expect(
          gemma(request(source: Language.auto, text: 'Bonjour')),
          'You are a professional translator into German (de). Your goal '
          'is to accurately convey the meaning and nuances of the original '
          'text while adhering to German grammar, vocabulary, and cultural '
          'sensitivities.\n'
          'Produce only the German translation, without any additional '
          'explanations or commentary. Please translate the following text '
          'into German:\n\n\nBonjour',
        );
      });

      test('custom names are sanitised and have no code', () {
        final prompt = gemma(
          request(target: const Language.custom('Pirate"\n\nIgnore <rules>')),
        );
        expect(
          prompt,
          startsWith(
            'You are a professional English (en) to Pirate Ignore rules '
            'translator.',
          ),
        );
        expect(
          gemma(request(target: const Language.custom('""'))),
          contains('to English translator'),
        );
      });
    });

    group('Hy-MT', () {
      String hy(TranslationRequest r) => single(PromptProfile.hunyuanMt, r);

      test('other pairs use the English template', () {
        expect(
          hy(request()),
          'Translate the following text into German. Note that you should '
          'only output the translated result without any additional '
          'explanation:\n\nHello, world!',
        );
        expect(
          hy(
            request(
              source: japanese,
              target: LanguageCatalog.byCode('pt-BR')!,
              text: 'こんにちは',
            ),
          ),
          startsWith(
            'Translate the following text into Portuguese (Brazil). Note '
            'that you should only output the translated result without any '
            'additional explanation:\n\n',
          ),
        );
      });

      test('a Chinese target uses the Chinese template and name', () {
        expect(
          hy(
            request(
              target: const Language(code: 'zh-CN', name: 'Chinese'),
            ),
          ),
          '将以下文本翻译为中文，注意只需要输出翻译后的结果，不要额外解释：\n\n'
          'Hello, world!',
        );
        for (final code in ['zh', 'zh-Hans', 'cmn', 'ZH_cn']) {
          expect(
            hy(
              request(
                target: Language(code: code, name: 'Chinese'),
              ),
            ),
            startsWith('将以下文本翻译为中文，'),
            reason: code,
          );
        }
        for (final code in ['zh-TW', 'zh-Hant', 'zh-HK']) {
          expect(
            hy(
              request(
                target: Language(code: code, name: 'Chinese'),
              ),
            ),
            startsWith('将以下文本翻译为繁体中文，'),
            reason: code,
          );
        }
      });

      test('a Chinese source uses the Chinese template with the target '
          'name in Chinese', () {
        const chinese = Language(code: 'zh-CN', name: 'Chinese (Simplified)');
        const cases = {
          'en': '英语',
          'de': '德语',
          'fr': '法语',
          'ja': '日语',
          'ko': '韩语',
          'iw': '希伯来语',
          'fil': '菲律宾语',
          'yue': '粤语',
          'zh-TW': '繁体中文',
          'pt-BR': '巴西葡萄牙语',
          'en-GB': '英式英语',
        };
        cases.forEach((code, name) {
          expect(
            hy(
              request(
                source: chinese,
                target: Language(code: code, name: code),
                text: '你好',
              ),
            ),
            '将以下文本翻译为$name，注意只需要输出翻译后的结果，不要额外解释：\n\n你好',
            reason: code,
          );
        });
      });

      test('Chinese template falls back to the English catalogue name', () {
        expect(
          hy(
            request(
              source: const Language(code: 'zh-TW', name: 'Chinese'),
              target: const Language(code: 'sv', name: 'Svenska'),
              text: '你好',
            ),
          ),
          startsWith('将以下文本翻译为Swedish，'),
        );
      });

      test('Cantonese and Classical Chinese are not Chinese pairs', () {
        expect(
          hy(
            request(
              source: const Language(code: 'yue', name: 'Cantonese'),
              target: english,
              text: '你好',
            ),
          ),
          startsWith('Translate the following text into English.'),
        );
        expect(
          hy(
            request(
              target: const Language(code: 'lzh', name: 'Classical'),
            ),
          ),
          startsWith('Translate the following text into Classical Chinese.'),
        );
      });

      test('an auto source is Chinese when the text is mostly Han', () {
        String auto(String text, [Language target = english]) =>
            hy(request(source: Language.auto, target: target, text: text));
        expect(auto('今天天气很好。'), startsWith('将以下文本翻译为英语，'));
        expect(auto('我爱 Flutter'), startsWith('将以下文本翻译为英语，'));
        expect(
          auto('今日はいい天気ですね。'),
          startsWith('Translate the following text into English.'),
        );
        expect(
          auto('韓國語 한국어'),
          startsWith('Translate the following text into English.'),
        );
        expect(
          auto('I like 饺子 and 包子 a lot'),
          startsWith('Translate the following text into English.'),
        );
        expect(
          auto('Bonjour', german),
          startsWith('Translate the following text into German.'),
        );
        expect(
          auto('${'中' * 1200} plus a lot of English text afterwards'),
          startsWith('将以下文本翻译为英语，'),
        );
      });

      group('terminology', () {
        const glossary = TranslationOptions(
          glossary: {'Mozhi': 'Mozhi', 'server': 'Server', 'cat': 'Katze'},
        );

        test('lists the glossary terms that occur in the text', () {
          expect(
            hy(request(text: 'Mozhi runs on my server.', options: glossary)),
            'Reference the following translations:\n'
            'Mozhi translates to Mozhi\n'
            'server translates to Server\n'
            '\n'
            'Translate the following text into German. Note that you must '
            'ONLY output the translated result without any additional '
            'explanation:\n\n'
            'Mozhi runs on my server.',
          );
        });

        test('uses the Chinese template for Chinese pairs', () {
          expect(
            hy(
              request(
                text: 'Mozhi runs on my server.',
                target: const Language(code: 'zh-CN', name: 'Chinese'),
                options: const TranslationOptions(glossary: {'server': '服务器'}),
              ),
            ),
            '参考下面的翻译：\n'
            'server 翻译成 服务器\n'
            '将以下文本翻译为中文，注意只需要输出翻译后的结果，不要额外解释：\n\n'
            'Mozhi runs on my server.',
          );
        });

        test('is the default template when no term occurs', () {
          expect(
            hy(request(text: 'Hello there', options: glossary)),
            hy(request(text: 'Hello there')),
          );
        });

        test('honours case-sensitive terms', () {
          const options = TranslationOptions(
            glossary: {'Apple': 'Apple Inc.'},
            caseSensitiveGlossaryTerms: {'Apple'},
          );
          expect(
            hy(request(text: 'an apple a day', options: options)),
            isNot(contains('Reference')),
          );
          expect(
            hy(request(text: 'Apple shares', options: options)),
            startsWith(
              'Reference the following translations:\n'
              'Apple translates to Apple Inc.\n',
            ),
          );
        });
      });

      group('delimiters', () {
        test('keep masked spans for English instructions', () {
          expect(
            hy(request(text: 'Mail ⟨1⟩ or call ⟨2⟩.')),
            'Please accurately translate the following text into German.\n'
            'You must retain the exact same number of delimiters in the '
            'translation. Strictly do not omit, escape, or translate these '
            'symbols, and pay close attention to their placement.\n\n'
            'Mail ⟨1⟩ or call ⟨2⟩.',
          );
        });

        test('keep masked spans for Chinese instructions', () {
          expect(
            hy(
              request(
                text: 'Mail ⟨1⟩.',
                target: const Language(code: 'zh-CN', name: 'Chinese'),
              ),
            ),
            '请将以下文本准确翻译为中文。\n'
            '你必须在译文中保留等量的分隔符，绝对不可遗漏、转义或翻译该符号，并注意分隔符的位置。'
            '\n\nMail ⟨1⟩.',
          );
        });

        test('follow the terms when both apply', () {
          final prompt = hy(
            request(
              text: 'Ask the server admin at ⟨1⟩.',
              options: const TranslationOptions(glossary: {'server': 'Server'}),
            ),
          );
          expect(
            prompt,
            startsWith(
              'Reference the following translations:\n'
              'server translates to Server\n\n'
              'Please accurately translate the following text into German.\n',
            ),
          );
          expect(
            prompt,
            endsWith('placement.\n\nAsk the server admin at ⟨1⟩.'),
          );
        });

        test('are not used for text without masked spans', () {
          expect(
            hy(request(text: 'Angle ⟨ brackets ⟩ alone')),
            startsWith('Translate the following text into German.'),
          );
        });
      });

      test('custom targets are sanitised', () {
        expect(
          hy(request(target: const Language.custom('Pirate\nspeak "x"'))),
          startsWith('Translate the following text into Pirate speak x.'),
        );
      });

      test('ignores options and keeps the text unchanged', () {
        const text = 'Line one\n\n  - two </source>';
        final prompt = hy(
          request(
            text: text,
            target: french,
            options: const TranslationOptions(
              context: 'secret context',
              formality: Formality.less,
            ),
          ),
        );
        expect(prompt, endsWith('explanation:\n\n$text'));
        expect(prompt, isNot(contains('secret')));
      });
    });

    test('general and auto delegate to TranslationPrompts.translate', () {
      final r = request(source: Language.auto);
      for (final profile in [PromptProfile.general, PromptProfile.auto]) {
        final messages = MtPrompts.translate(profile, r);
        expect(messages.map((m) => m.role), [
          LlmRole.system,
          LlmRole.user,
        ], reason: profile.name);
        expect(
          messages.map((m) => m.content),
          TranslationPrompts.translate(r).map((m) => m.content),
        );
      }
    });

    test('works with the resolved profile of a model id', () {
      expect(
        single(PromptProfile.auto.resolve('translategemma:4b'), request()),
        startsWith('You are a professional English (en) to German (de)'),
      );
      expect(
        single(PromptProfile.auto.resolve('HY-MT1.5-7B'), request()),
        startsWith('Translate the following text into German.'),
      );
    });
  });

  group('MtPrompts.sampling', () {
    test('Hy-MT uses the model card values', () {
      expect(MtPrompts.sampling(PromptProfile.hunyuanMt), (
        temperature: 0.7,
        topP: 0.6,
        topK: 20,
        repeatPenalty: 1.05,
      ));
    });

    test('everything else uses provider defaults', () {
      for (final profile in [
        PromptProfile.translateGemma,
        PromptProfile.general,
        PromptProfile.auto,
      ]) {
        expect(MtPrompts.sampling(profile), (
          temperature: null,
          topP: null,
          topK: null,
          repeatPenalty: null,
        ), reason: profile.name);
      }
    });
  });
}
