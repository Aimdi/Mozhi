import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/view/settings_page.dart';
import 'package:mozhi/settings/view/widgets/link_launcher.dart';
import 'package:mozhi/settings/view/widgets/settings_search.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Anchors ([SettingsAnchor.id]) of the About page.
abstract final class AboutAnchors {
  static const version = 'version';
  static const privacy = 'about_privacy';
  static const sourceCode = 'source_code';
  static const mozhiProject = 'mozhi_project';
  static const licenses = 'licenses';
  static const runSetup = 'run_setup';
}

/// The About category of the settings (`/settings/about`): app name,
/// version, the privacy statement, links, the licences and "Run setup
/// again" ([AboutView]). Like the other categories, a master | detail
/// page on wide screens ([SettingsView]); [highlight] names a row to jump
/// to ([SettingsAnchor]).
class AboutPage extends StatelessWidget {
  const new({this.highlight, super.key});

  /// The [SettingsAnchor] to scroll to and highlight.
  final String? highlight;

  @override
  Widget build(BuildContext context) =>
      SettingsView(category: SettingsCategory.about, highlight: highlight);
}

/// The content of the About page: name, version, description, privacy
/// promises, links, licences and "Run setup again".
class AboutView extends StatefulWidget {
  const new({super.key});

  static final Uri sourceCodeUrl = Uri.parse('https://github.com/Aimdi/Mozhi');
  static final Uri mozhiProjectUrl = Uri.parse(
    'https://codeberg.org/aryak/mozhi',
  );

  @override
  State<AboutView> createState() => _AboutViewState();
}

class _AboutViewState extends State<AboutView> {
  late final Future<PackageInfo> _info = PackageInfo.fromPlatform();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return FutureBuilder<PackageInfo>(
      future: _info,
      builder: (context, snapshot) {
        final info = snapshot.data;
        final version = info == null
            ? null
            : info.buildNumber.isEmpty
            ? info.version
            : '${info.version} (${info.buildNumber})';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SettingsAnchor(
              id: AboutAnchors.version,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 16),
                  Center(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: colors.primaryContainer,
                        shape: BoxShape.circle,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Icon(
                          Icons.translate,
                          size: 48,
                          color: colors.onPrimaryContainer,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    l10n.appTitle,
                    style: theme.textTheme.headlineMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 4),
                  // A minimum (not fixed) height reserves the line while the
                  // version loads without clipping it at large text sizes.
                  ConstrainedBox(
                    key: const Key('settings_version'),
                    constraints: const BoxConstraints(minHeight: 24),
                    child: version == null
                        ? null
                        : Text(
                            l10n.settingsAboutVersion(version),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                            textAlign: TextAlign.center,
                          ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    l10n.settingsAboutDescription,
                    style: theme.textTheme.bodyLarge,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
            SettingsAnchor(
              id: AboutAnchors.privacy,
              child: SettingsSection(
                title: l10n.settingsAboutPrivacyTitle,
                children: [
                  _PrivacyRow(
                    icon: Icons.visibility_off_outlined,
                    text: l10n.settingsAboutPrivacyTelemetry,
                  ),
                  _PrivacyRow(
                    icon: Icons.phone_android_outlined,
                    text: l10n.settingsAboutPrivacyHistory,
                  ),
                  _PrivacyRow(
                    icon: Icons.alt_route_outlined,
                    text: l10n.settingsAboutPrivacyServices,
                  ),
                ],
              ),
            ),
            SettingsSection(
              title: l10n.settingsSectionAbout,
              divider: false,
              children: [
                SettingsAnchor(
                  id: AboutAnchors.sourceCode,
                  child: ListTile(
                    key: const Key('settings_source_code'),
                    leading: const SettingsIcon(Icons.code),
                    title: Text(l10n.settingsAboutSource),
                    subtitle: Text(AboutView.sourceCodeUrl.host),
                    trailing: const Icon(Icons.open_in_new),
                    onTap: () =>
                        LinkLauncher.open(context, AboutView.sourceCodeUrl),
                  ),
                ),
                SettingsAnchor(
                  id: AboutAnchors.mozhiProject,
                  child: ListTile(
                    leading: const SettingsIcon(Icons.public),
                    title: Text(l10n.settingsAboutMozhiProject),
                    subtitle: Text(l10n.settingsAboutMozhiProjectSubtitle),
                    trailing: const Icon(Icons.open_in_new),
                    onTap: () =>
                        LinkLauncher.open(context, AboutView.mozhiProjectUrl),
                  ),
                ),
                SettingsAnchor(
                  id: AboutAnchors.licenses,
                  child: ListTile(
                    key: const Key('settings_licenses'),
                    leading: const SettingsIcon(Icons.description_outlined),
                    title: Text(l10n.settingsAboutLicenses),
                    subtitle: Text(l10n.settingsAboutLicensesSubtitle),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => showLicensePage(
                      context: context,
                      applicationName: l10n.appTitle,
                      applicationVersion: version,
                      applicationIcon: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Icon(
                          Icons.translate,
                          size: 40,
                          color: colors.primary,
                        ),
                      ),
                    ),
                  ),
                ),
                SettingsAnchor(
                  id: AboutAnchors.runSetup,
                  child: ListTile(
                    key: const Key('settings_run_setup'),
                    leading: const SettingsIcon(Icons.restart_alt),
                    title: Text(l10n.settingsRunSetup),
                    subtitle: Text(l10n.settingsRunSetupSteps),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => context.push(AppRoutes.onboarding),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _PrivacyRow extends StatelessWidget {
  const new({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return ListTile(leading: SettingsIcon(icon), title: Text(text));
  }
}
