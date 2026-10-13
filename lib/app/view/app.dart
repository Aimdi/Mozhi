import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';

/// Placeholder; replaced by the app-shell implementation.
class App extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(useMaterial3: true),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const Scaffold(),
    );
  }
}
