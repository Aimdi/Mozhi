import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LanguageIdentifier.identify', () {
    final samples = {
      '안녕하세요, 잘 지내세요?': 'ko',
      'こんにちは、お元気ですか？': 'ja',
      '東京は日本の首都です。': 'ja',
      '今天天气很好，我们去公园吧。': 'zh',
      'Καλημέρα, τι κάνεις;': 'el',
      'שלום, מה שלומך?': 'he',
      'สวัสดีครับ คุณสบายดีไหม': 'th',
      'আপনি কেমন আছেন?': 'bn',
      'તમે કેમ છો?': 'gu',
      'ನೀವು ಹೇಗಿದ್ದೀರಿ?': 'kn',
      'സുഖമാണോ?': 'ml',
      'நீங்கள் எப்படி இருக்கிறீர்கள்?': 'ta',
      'మీరు ఎలా ఉన్నారు?': 'te',
      'مرحبا، كيف حالك؟': 'ar',
      'سلام، حال شما چطور است؟ من خوبم و پدرم هم خوب است': 'fa',
      'آپ کیسے ہیں؟ میں ٹھیک ہوں': 'ur',
      'ياخشىمۇسىز؟ مەن ياخشى': 'ug',
      'Привет, как дела? Мы были здесь.': 'ru',
      'Привіт, як справи? Я їду додому.': 'uk',
      'Прывітанне, як справы? Ўсё добра.': 'be',
      'Здраво, како си? Ја сам добро, љубав.': 'sr',
      'Здравей, как си? Аз съм добре, благодаря.': 'bg',
      'Как дела у вас?': 'ru',
      'Hello, how are you? I think that this is the best way to do it.': 'en',
      'Ich weiß nicht, ob das eine gute Idee ist, aber wir sind hier.': 'de',
      'Je ne sais pas si c’est une bonne idée, mais nous sommes là.': 'fr',
      '¿Dónde está la biblioteca? No sé si es una buena idea.': 'es',
      'Non so se è una buona idea, ma questo è il punto.': 'it',
      'Eu não sei se isso é uma boa ideia, mas você está aqui.': 'pt',
      'Ik weet niet of het een goed idee is, maar dat is het.': 'nl',
      'Nie wiem, czy to jest dobry pomysł, ale tak się stało.': 'pl',
      'Bunun iyi bir fikir olup olmadığını bilmiyorum ama çok güzel.': 'tr',
      'Tôi không biết đây có phải là một ý tưởng tốt hay không.': 'vi',
    };
    for (final MapEntry(key: text, value: language) in samples.entries) {
      test('$language: $text', () {
        expect(LanguageIdentifier.identify(text), language);
      });
    }

    test('returns null when it cannot tell', () {
      for (final text in [
        '',
        '1234 !!! ...',
        'OK',
        'Hi',
        // Devanagari: Hindi or Marathi.
        'आप कैसे हैं?',
        // Cyrillic with і only: Belarusian or Ukrainian.
        'Він тут',
        // Mixed scripts without a majority.
        'Hello Привет שלום',
      ]) {
        expect(LanguageIdentifier.identify(text), isNull, reason: text);
      }
    });
  });
}
