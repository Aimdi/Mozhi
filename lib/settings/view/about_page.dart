import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/view/widgets/link_launcher.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// App name, version, links and the privacy statement.
class AboutPage extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) => const AboutView();
}

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
    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsAboutTitle)),
      body: FutureBuilder<PackageInfo>(
        future: _info,
        builder: (context, snapshot) {
          final info = snapshot.data;
          final version = info == null
              ? null
              : info.buildNumber.isEmpty
              ? info.version
              : '${info.version} (${info.buildNumber})';
          return LayoutBuilder(
            builder: (context, constraints) => ListView(
              padding: centeredPadding(constraints.maxWidth, maxWidth: 640),
              children: [
                const SizedBox(height: 16),
                Center(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.primaryContainer,
                      borderRadius: BorderRadius.circular(28),
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
                const SizedBox(height: 32),
                SettingsSection(
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
                SettingsSection(
                  title: l10n.settingsSectionAbout,
                  children: [
                    ListTile(
                      leading: const Icon(Icons.code),
                      title: Text(l10n.settingsAboutSource),
                      subtitle: Text(AboutView.sourceCodeUrl.host),
                      trailing: const Icon(Icons.open_in_new),
                      onTap: () =>
                          LinkLauncher.open(context, AboutView.sourceCodeUrl),
                    ),
                    ListTile(
                      leading: const Icon(Icons.public),
                      title: Text(l10n.settingsAboutMozhiProject),
                      subtitle: Text(l10n.settingsAboutMozhiProjectSubtitle),
                      trailing: const Icon(Icons.open_in_new),
                      onTap: () =>
                          LinkLauncher.open(context, AboutView.mozhiProjectUrl),
                    ),
                    ListTile(
                      leading: const Icon(Icons.description_outlined),
                      title: Text(l10n.settingsAboutLicenses),
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
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _PrivacyRow extends StatelessWidget {
  const new({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
      title: Text(text),
    );
  }
}
