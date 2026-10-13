/// Response bodies modelled on real Mozhi instances (Go `encoding/json`
/// output: nil slices/maps are `null`, struct field order preserved).
library;

/// `GET /api/engines` on an instance with every engine enabled.
const enginesJson = '''
{"all":"All Engines","duckduckgo":"DuckDuckGo","google":"Google",
"deepl":"DeepL","libre":"LibreTranslate","mymemory":"MyMemory",
"reverso":"Reverso","some":"Some Engines","yandex":"Yandex"}''';

/// `GET /api/source_languages?engine=google` (truncated).
const googleSourceLanguagesJson = '''
[{"Name":"Detect Language","Id":"auto"},{"Name":"Afrikaans","Id":"af"},
{"Name":"Chinese (Simplified)","Id":"zh-CN"},{"Name":"Japanese","Id":"ja"},
{"Name":"Tamil","Id":"ta"}]''';

/// `GET /api/target_languages?engine=deepl` (truncated).
const deeplTargetLanguagesJson = '''
[{"Name":"English (American)","Id":"en-US"},{"Name":"German","Id":"de"},
{"Name":"Portuguese (Brazilian)","Id":"pt-BR"}]''';

/// `POST /api/translate` engine=google from=auto to=en text=猫: dictionary
/// data, a transliteration, synonyms and equivalents.
const googleTranslationJson = '''
{
  "engine": "google",
  "detected": "ja",
  "translated-text": "cat",
  "source_language": "auto",
  "target_language": "en",
  "word_choices": [
    {
      "word": "cat",
      "definition": "a small domesticated carnivorous mammal with soft fur, a short snout, and retractable claws.",
      "example": "the cat sat on the windowsill and purred",
      "examples_source": null,
      "examples_target": null
    },
    {
      "word": "cat",
      "definition": "a jazz enthusiast.",
      "example": ""
    }
  ],
  "source_transliteration": "Neko",
  "target_transliteration": "",
  "source_synonyms": null,
  "target_synonyms": ["kitty", "puss", "pussycat", "feline", "moggy"],
  "source_antonyms": null,
  "target_antonyms": [],
  "source_equivalent_target_lang": {"猫": ["cat", "puss"]},
  "target_equivalent_source_lang": {"cat": ["猫", "ネコ", "にゃんこ"]}
}''';

/// `POST /api/translate` engine=deepl: no extras, every slice/map is nil and
/// the transliteration keys are missing entirely.
const deeplTranslationJson = '''
{
  "engine": "deepl",
  "detected": "",
  "translated-text": "Good morning, how are you?",
  "source_language": "de",
  "target_language": "en-US",
  "word_choices": null,
  "source_synonyms": null,
  "target_synonyms": null,
  "source_antonyms": null,
  "target_antonyms": null,
  "source_equivalent_target_lang": null,
  "target_equivalent_source_lang": null
}''';

/// `POST /api/translate` engine=reverso: word choices with example pairs.
const reversoTranslationJson = '''
{
  "engine": "reverso",
  "detected": "",
  "translated-text": "house",
  "source_language": "fr",
  "target_language": "en",
  "word_choices": [
    {
      "word": "house",
      "definition": "",
      "example": "",
      "examples_source": ["Il habite dans une grande maison.", "La maison est à vendre."],
      "examples_target": ["He lives in a big house.", "The house is for sale."]
    },
    {
      "word": "home",
      "examples_source": ["Je rentre à la maison."],
      "examples_target": ["I'm going home."]
    }
  ],
  "source_transliteration": "",
  "target_transliteration": "",
  "source_synonyms": null,
  "target_synonyms": null,
  "source_antonyms": null,
  "target_antonyms": null,
  "source_equivalent_target_lang": null,
  "target_equivalent_source_lang": null
}''';

/// `POST /api/translate` engine=all: one object per engine that succeeded,
/// in completion order; LibreTranslate only fills the basics.
const allEnginesTranslationJson =
    '''
[
  $deeplTranslationJson,
  {"engine":"libre","translated-text":"Good morning, how are you?"},
  {
    "engine": "google",
    "detected": "de",
    "translated-text": "Good morning, how are you?",
    "source_language": "auto",
    "target_language": "en",
    "word_choices": null,
    "source_transliteration": "",
    "target_transliteration": "",
    "source_synonyms": null,
    "target_synonyms": null,
    "source_antonyms": null,
    "target_antonyms": null,
    "source_equivalent_target_lang": {},
    "target_equivalent_source_lang": {}
  }
]''';

/// `POST /api/image` (Go `ImgOut`, no JSON tags).
const imageTranslationJson = '''
{"SourceB64":"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
"TranslatedImgB64":"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
"SourceLang":"fr","TargetLang":"en","SourceTextParsed":"Sortie de secours",
"TranslatedTextParsed":"Emergency exit"}''';

/// `GET /api/version`.
const versionJson = '{"fiberversion":"v2.52.5","goversion":"go1.23.1"}';
