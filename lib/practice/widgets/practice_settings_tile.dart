import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/practice/practice_routes.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';

/// The settings row that opens practice, for a settings category (with a
/// `SettingsAnchor` of [anchor] so the settings search finds it; its title
/// is [AppLocalizations.practiceTitle], its subtitle
/// [AppLocalizations.practiceSettingsTileSubtitle] and its search keywords
/// [AppLocalizations.practiceSearchKeywords]).
class PracticeSettingsTile extends StatelessWidget {
  const new({super.key});

  /// The anchor id the settings search jumps to.
  static const anchor = 'practice';

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ListTile(
      key: const Key('settings_practice'),
      leading: const SettingsIcon(Icons.school_outlined),
      title: Text(l10n.practiceTitle),
      subtitle: Text(l10n.practiceSettingsTileSubtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: () =>
          GoRouter.maybeOf(context)?.push<void>(PracticeRoutes.location),
    );
  }
}
