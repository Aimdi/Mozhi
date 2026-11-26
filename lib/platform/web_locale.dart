// Keeps the browser's `<html lang="...">` attribute in sync with the active
// app locale (WCAG 3.1.1). `dart:js_interop` exists only on the web.
import 'package:mozhi/platform/web_locale_stub.dart'
    if (dart.library.js_interop) 'package:mozhi/platform/web_locale_web.dart'
    as platform;

/// Updates `document.documentElement.lang` on the web to [languageTag]
/// (BCP 47, e.g. `en`, `de`, `zh-Hans`). No-op outside the browser or when
/// [languageTag] is blank.
void setWebDocumentLocale(
  String languageTag, {
  void Function(String tag)? update,
}) {
  final trimmed = languageTag.trim();
  if (trimmed.isEmpty) return;
  (update ?? platform.setDocumentLang)(trimmed);
}
