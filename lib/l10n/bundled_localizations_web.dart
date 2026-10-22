import 'package:mozhi/l10n/gen/app_localizations.dart';

/// On the web each language but English is a deferred part of the app
/// (`use-deferred-loading` in l10n.yaml), loaded by
/// `preloadAppLocalizations` or the localisations delegate: none is
/// bundled.
AppLocalizations? bundledAppLocalizations(String languageCode) => null;
