# mt_api

[![style: very good analysis][very_good_analysis_badge]][very_good_analysis_link]
[![License: MIT][license_badge]][license_link]

Pure Dart (web-safe, no `dart:io`) clients for classic machine translation
APIs that Mozhi users can connect directly with their own key or server:

- **`DeeplClient`**: DeepL API v2 (Free and Pro).
- **`LibreTranslateClient`**: any LibreTranslate server (self-hosted or
  libretranslate.com).

It also has helpers that convert the app's language codes (`en`, `pt-BR`,
`zh-CN`, `zh-TW`, `no`, `es-419`, ...) to each service's codes and back.

## DeepL

```dart
final deepl = DeeplClient(authKey: 'xxxxxxxx-xxxx-...:fx'); // :fx -> api-free.deepl.com

final targets = await deepl.languages(); // DeeplLanguageType.target
final [result] = await deepl.translate(
  texts: ['How are you?'],
  sourceLang: deeplSourceCode('auto'), // null -> detect
  targetLang: deeplTargetCode('pt', supported: targets.map((l) => l.code)),
  formality: DeeplFormality.preferLess,
  context: 'A chat between friends',
  modelType: DeeplModelType.preferQualityOptimized,
);
print('${result.text} (from ${appCodeFromDeepl(result.detectedSourceLanguage)})');

final usage = await deepl.usage(); // characterCount / characterLimit
final glossary = await deepl.createGlossary(
  name: 'Product terms',
  sourceLang: 'en',
  targetLang: 'de',
  entries: {'Mozhi': 'Mozhi'},
);
```

- The base URL is chosen from the key (`:fx` keys use `api-free.deepl.com`)
  unless `baseUrl` is given (for example a proxy).
- `translate` sends `Authorization: DeepL-Auth-Key <key>` and a JSON body,
  and splits lists of more than 50 texts into several requests.
- Glossaries: `createGlossary` (TSV entries, validated), `listGlossaries`,
  `getGlossary`, `glossaryEntries`, `deleteGlossary`,
  `glossaryLanguagePairs`.
- **Web:** the DeepL API rejects cross-origin browser requests, so on the
  web DeepL only works through a CORS-enabled proxy `baseUrl`.

Code helpers: `deeplTargetCode` (`en` -> `EN-US`, `en-AU` -> `EN-GB`,
`pt` -> `PT-BR`, `zh-TW` -> `ZH-HANT`, `es-MX` -> `ES-419`, `no` -> `NB`),
`deeplSourceCode` (`zh-TW` -> `ZH`, `auto` -> `null`) and `appCodeFromDeepl`.

## LibreTranslate

```dart
final libre = LibreTranslateClient(
  baseUrl: LibreTranslateClient.normalizeBaseUrl('translate.example.org'),
  apiKey: null, // only if the server needs one
);

final settings = await libre.settings(); // keyRequired, charLimit
final languages = await libre.languages();
final result = await libre.translate(
  text: 'Bonjour',
  source: 'auto',
  target: libreLanguageCode('zh-TW', supported: languages.map((l) => l.code)),
  alternatives: 2,
);
print(result.text);
print(result.detectedLanguage); // code + confidence (0-100), for `auto`
print(result.alternatives);
```

Also `translateBatch` (list `q`) and `detect`. Code helpers:
`libreLanguageCode` (`zh-CN` -> `zh`/`zh-Hans`, `zh-TW` -> `zt`/`zh-Hant`,
`pt-BR` -> `pb`/`pt-BR`, depending on what the server lists) and
`appCodeFromLibre`.

## Errors

Every failure is an `MtApiException` (`DeeplApiException` or
`LibreTranslateException`) with:

- `message`: a short English sentence a user can read,
- `kind`: an `MtErrorKind` (`unauthorized`, `quotaExceeded`, `rateLimited`,
  `payloadTooLarge`, `badRequest`, `notFound`, `server`, `network`,
  `timeout`, `cancelled`, `invalidResponse`, `unknown`) so apps can show
  localised text,
- `statusCode`, `detail` (the server's own message), `uri`, `isRetryable`.

Requests can be cancelled by completing the `abortTrigger` future that
`translate`, `translateText` and `translateBatch` accept.

## Running tests

Shell `dart test` is blocked in this repository. Use the Very Good CLI MCP
helper instead:

```sh
python3 /home/user/.tools/vgmcp.py call test '{"directory":"/home/user/Mozhi/packages/mt_api","dart":true,"optimization":false,"coverage":true}'
```

[license_badge]: https://img.shields.io/badge/license-MIT-blue.svg
[license_link]: https://opensource.org/licenses/MIT
[very_good_analysis_badge]: https://img.shields.io/badge/style-very_good_analysis-B22C89.svg
[very_good_analysis_link]: https://pub.dev/packages/very_good_analysis
