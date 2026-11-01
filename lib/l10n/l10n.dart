import 'dart:async';
import 'dart:developer';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show GlobalMaterialLocalizations;
import 'package:mozhi/l10n/bundled_localizations_web.dart'
    if (dart.library.io) 'package:mozhi/l10n/bundled_localizations_io.dart'
    as bundled;
import 'package:mozhi/l10n/gen/app_localizations.dart'
    hide lookupAppLocalizations;
import 'package:mozhi/l10n/gen/app_localizations_en.dart';

export 'package:mozhi/l10n/gen/app_localizations.dart'
    hide lookupAppLocalizations;
export 'package:mozhi/l10n/language_names.dart';

/// Localization delegates for the app.
///
/// Use this instead of the generated
/// `AppLocalizations.localizationsDelegates`: those come from
/// `flutter_localizations` and provide `package:flutter/material.dart`'s
/// `MaterialLocalizations`, while the app's widgets come from
/// `package:material_ui`, which looks up its own `MaterialLocalizations`
/// (and `cupertino_ui`'s `CupertinoLocalizations`). Without these delegates
/// every non-English locale crashes in widgets such as `NavigationBar`.
///
/// The app's own texts load synchronously when they are at hand, so the
/// first frame does not wait: English always, every language on native
/// platforms, and on the web the languages [preloadAppLocalizations]
/// loaded. Any other language is loaded first (on the web, its deferred
/// part of the app); if that fails, the texts are English.
const List<LocalizationsDelegate<dynamic>> appLocalizationsDelegates = [
  _AppLocalizationsDelegate(),
  ...GlobalMaterialLocalizations.delegates,
];

extension AppLocalizationsX on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}

/// The languages built into the app: all on native platforms, none (but
/// English, which is always there) on the web. Tests replace it to act like
/// the web build.
@visibleForTesting
AppLocalizations? Function(String languageCode) bundledLocalizations =
    bundled.bundledAppLocalizations;

/// Localisations loaded on demand, by language code.
final Map<String, AppLocalizations> _loaded = {};

/// The localisations of [locale] (by its language code) if they need no
/// loading, else null.
AppLocalizations? _ready(Locale locale) {
  final code = locale.languageCode;
  return _loaded[code] ??
      bundledLocalizations(code) ??
      (code == 'en' ? AppLocalizationsEn() : null);
}

/// The app's texts in [locale] (by its language code), synchronously: in
/// English, in every language on native platforms, and on the web in the
/// languages [preloadAppLocalizations] loaded. Throws a [FlutterError] for
/// any other locale.
///
/// Replaces the generated function of the same name, which returns a
/// `Future` since the languages are deferred (l10n.yaml).
AppLocalizations lookupAppLocalizations(Locale locale) =>
    _ready(locale) ??
    (throw FlutterError(
      'The app texts for "$locale" are not loaded: '
      'await preloadAppLocalizations first.',
    ));

/// Loads the app's texts in [locales] ahead of time, so that the first
/// frame in them does not wait (on the web each language but English is a
/// separate part of the app, fetched once). Unsupported locales are
/// skipped; failures are logged, never thrown (the delegate then tries
/// again and falls back to English).
Future<void> preloadAppLocalizations(Iterable<Locale> locales) async {
  await Future.wait([
    for (final locale in locales)
      if (AppLocalizations.delegate.isSupported(locale) &&
          _ready(locale) == null)
        _load(locale).then<void>((_) {}, onError: (Object _) {}),
  ]);
}

/// Loads [locale] with the generated delegate (on the web: its deferred
/// part) and keeps it for [lookupAppLocalizations].
Future<AppLocalizations> _load(Locale locale) async {
  try {
    final localizations = await AppLocalizations.delegate.load(locale);
    return _loaded[locale.languageCode] = localizations;
  } on Object catch (error, stackTrace) {
    log(
      'The app texts for "$locale" could not be loaded',
      name: 'mozhi',
      error: error,
      stackTrace: stackTrace,
    );
    rethrow;
  }
}

/// Forgets what [preloadAppLocalizations] and the delegate loaded (tests).
@visibleForTesting
void resetLoadedAppLocalizations() => _loaded.clear();

/// [AppLocalizations.delegate], answering synchronously when the texts are
/// at hand (see [appLocalizationsDelegates]).
class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const new();

  @override
  bool isSupported(Locale locale) =>
      AppLocalizations.delegate.isSupported(locale);

  @override
  Future<AppLocalizations> load(Locale locale) {
    if (_ready(locale) case final localizations?) {
      return SynchronousFuture(localizations);
    }
    return _load(locale).catchError((Object _) => AppLocalizationsEn());
  }

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}
