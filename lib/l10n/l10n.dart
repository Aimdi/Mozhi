import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show GlobalMaterialLocalizations;
import 'package:mozhi/l10n/gen/app_localizations.dart';

export 'package:mozhi/l10n/gen/app_localizations.dart';

/// Localization delegates for the app.
///
/// Use this instead of the generated
/// `AppLocalizations.localizationsDelegates`: those come from
/// `flutter_localizations` and provide `package:flutter/material.dart`'s
/// `MaterialLocalizations`, while the app's widgets come from
/// `package:material_ui`, which looks up its own `MaterialLocalizations`
/// (and `cupertino_ui`'s `CupertinoLocalizations`). Without these delegates
/// every non-English locale crashes in widgets such as `NavigationBar`.
const List<LocalizationsDelegate<dynamic>> appLocalizationsDelegates = [
  AppLocalizations.delegate,
  ...GlobalMaterialLocalizations.delegates,
];

extension AppLocalizationsX on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}
