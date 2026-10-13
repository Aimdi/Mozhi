# mlkit_translator

Offline on-device translation for Mozhi using Google ML Kit (Android and
iOS). `MlKitOfflineTranslator` implements `OfflineTranslator` from
`translation_repository`.

```dart
final offline = MlKitOfflineTranslator();
if (offline.isAvailable) {
  await offline.downloadLanguage('de', wifiOnly: true); // ~30 MB
  try {
    final text = await offline.translate(
      'Good morning',
      source: 'en-GB', // app codes are mapped: en-GB -> en
      target: 'de',
    );
  } on OfflineModelMissingException catch (e) {
    // e.languages lists the ML Kit codes that must be downloaded first.
  }
}
await offline.dispose();
```

## Behaviour

- `isAvailable` is true on Android and iOS only (never on web/desktop).
  Elsewhere `downloadedLanguages()` is empty, `identifyLanguage()` returns
  null and the other operations throw `UnsupportedError`.
- `supportedLanguages` are the 59 ML Kit model codes (`af` ... `zh`, `cy`).
  Every method accepts app/catalogue codes and maps them with
  `MlKitLanguageCodes.toMlKit` (`zh-CN`/`zh-TW`/`zh-Hans`/`zh-Hant` -> `zh`,
  `nb`/`nn` -> `no`, `iw` -> `he`, `fil` -> `tl`, `in` -> `id`,
  `pt-BR` -> `pt`, `en-US` -> `en`, case and `_` insensitive). Unsupported
  codes throw `OfflineLanguageUnsupportedException`.
- `translate()` never downloads: ML Kit's `translateText` silently fetches
  missing models on Android, so both models are checked first and
  `OfflineModelMissingException` is thrown instead. `source: 'auto'`
  identifies the language first. Native translators are cached per pair
  (LRU of 3) and closed by `dispose()` or when a model is deleted.
- `identifyLanguage()` maps `und` to null and normalises codes
  (`iw` -> `he`); romanised text keeps its script (`ja-Latn`).
- Plugin access goes through `MlKitBindings` (`GoogleMlKitBindings` by
  default), so the class can be tested with fakes.

## Platform setup

- **iOS:** ML Kit needs iOS 15.5+ (set `platform :ios, '15.5'` in the
  Podfile and `IPHONEOS_DEPLOYMENT_TARGET = 15.5` in the Runner project) and
  64-bit devices only (exclude `armv7`).
- **Android:** minSdk 21; no extra permissions beyond `INTERNET` for
  downloads. The ML Kit translate and language-id libraries add an
  estimated 3–5 MB per ABI (native code plus the bundled ~1 MB
  language-identification model; check with
  `flutter build apk --analyze-size`). Translation models (~30 MB each)
  are downloaded at runtime, never bundled.

## Tests

```sh
python3 /home/user/.tools/vgmcp.py call test \
  '{"directory":"/home/user/Mozhi/packages/mlkit_translator","optimization":false}'
```
