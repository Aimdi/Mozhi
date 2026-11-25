import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Sets `document.documentElement.lang` to [languageTag]. Never throws.
// coverage:ignore-start
void setDocumentLang(String languageTag) {
  try {
    final document = globalContext.getProperty<JSObject?>('document'.toJS);
    final root = document?.getProperty<JSObject?>('documentElement'.toJS);
    if (root == null) return;
    root.setProperty('lang'.toJS, languageTag.toJS);
  } on Object {
    // Keep the existing document language.
  }
}

// coverage:ignore-end
