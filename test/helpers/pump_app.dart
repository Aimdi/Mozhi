import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';

extension PumpApp on WidgetTester {
  /// Pumps [widget] inside a localized [MaterialApp] (Material 3).
  /// Wrap [widget] in your own Bloc/RepositoryProviders as needed.
  Future<void> pumpApp(Widget widget, {ThemeData? theme}) {
    return pumpWidget(
      MaterialApp(
        theme: theme ?? ThemeData(useMaterial3: true),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: widget,
      ),
    );
  }
}
