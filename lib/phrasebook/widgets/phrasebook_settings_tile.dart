import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';

/// The settings row that opens the phrasebook, for a settings category
/// (with a `SettingsAnchor` so the settings search finds it, its title
/// [AppLocalizations.settingsPhrasebook] and subtitle
/// [AppLocalizations.settingsPhrasebookSubtitle]).
class PhrasebookSettingsTile extends StatelessWidget {
  const new({super.key});

  /// The anchor id the settings search jumps to.
  static const anchor = 'phrasebook';

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ListTile(
      key: const Key('settings_phrasebook'),
      leading: const SettingsIcon(Icons.collections_bookmark_outlined),
      title: Text(l10n.settingsPhrasebook),
      subtitle: Text(l10n.settingsPhrasebookSubtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => GoRouter.maybeOf(context)?.push<void>(AppRoutes.phrasebook),
    );
  }
}
