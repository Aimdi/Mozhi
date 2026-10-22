import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/widgets/accent_color_picker.dart';
import 'package:mozhi/settings/view/widgets/settings_search.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';

/// Anchors ([SettingsAnchor.id]) of the Appearance settings.
abstract final class AppearanceAnchors {
  static const theme = 'theme';
  static const dynamicColor = 'dynamic_color';
  static const darkLook = 'dark_look';
  static const transliteration = 'show_transliteration';
  static const accentColor = 'accent_color';
}

/// The Appearance settings: theme mode, Material You colours (Android),
/// the dark look (Dim or Lights out), romanization and, without Material
/// You colours, the accent colour.
class AppearanceSettings extends StatelessWidget {
  const new({required this.settings, super.key});

  final AppSettings settings;

  /// Whether the platform has Material You colours ([platform]: the
  /// theme's).
  static bool dynamicColorAvailable(TargetPlatform platform) =>
      !kIsWeb && platform != TargetPlatform.iOS;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<SettingsCubit>();
    final dynamicColor = dynamicColorAvailable(Theme.of(context).platform);
    final showAccent = !dynamicColor || !settings.dynamicColor;
    return SettingsSection(
      divider: false,
      children: [
        SettingsAnchor(
          id: AppearanceAnchors.theme,
          child: _ThemeModePicker(
            value: settings.themeMode,
            onChanged: cubit.setThemeMode,
          ),
        ),
        if (dynamicColor)
          SettingsAnchor(
            id: AppearanceAnchors.dynamicColor,
            child: SwitchListTile(
              key: const Key('settings_dynamic_color'),
              secondary: const SettingsIcon(Icons.wallpaper_outlined),
              title: Text(l10n.settingsDynamicColor),
              subtitle: Text(l10n.settingsDynamicColorSubtitle),
              value: settings.dynamicColor,
              onChanged: (value) => cubit.setDynamicColor(enabled: value),
            ),
          ),
        SettingsAnchor(
          id: AppearanceAnchors.darkLook,
          child: _DarkLookPicker(
            lightsOut: settings.pureBlack,
            enabled: settings.themeMode != ThemeMode.light,
            onChanged: (value) => cubit.setPureBlack(enabled: value),
          ),
        ),
        SettingsAnchor(
          id: AppearanceAnchors.transliteration,
          child: SwitchListTile(
            key: const Key('settings_show_transliteration'),
            secondary: const SettingsIcon(Icons.abc),
            title: Text(l10n.settingsShowTransliteration),
            subtitle: Text(l10n.settingsShowTransliterationSubtitle),
            value: settings.showTransliteration,
            onChanged: (value) => cubit.setShowTransliteration(enabled: value),
          ),
        ),
        if (showAccent)
          SettingsAnchor(
            id: AppearanceAnchors.accentColor,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ExcludeSemantics(
                    child: Text(
                      l10n.settingsAccentColor,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Semantics(
                    container: true,
                    explicitChildNodes: true,
                    label: l10n.settingsAccentColor,
                    child: AccentColorPicker(
                      selected: settings.seedColor,
                      onSelected: cubit.setSeedColor,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Theme mode choice: a segmented button, or radio rows when large text
/// would truncate the segment labels (WCAG 1.4.4).
class _ThemeModePicker extends StatelessWidget {
  const new({required this.value, required this.onChanged});

  /// Text scale above which the three segments no longer fit.
  static const largeTextScale = 1.3;

  final ThemeMode value;
  final ValueChanged<ThemeMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final options = [
      (
        ThemeMode.system,
        Icons.brightness_auto_outlined,
        l10n.settingsThemeSystem,
      ),
      (ThemeMode.light, Icons.light_mode_outlined, l10n.settingsThemeLight),
      (ThemeMode.dark, Icons.dark_mode_outlined, l10n.settingsThemeDark),
    ];
    // The visible title names the group below (WCAG 1.3.1, 4.1.2), so it
    // is read once, as the group's label.
    final title = ExcludeSemantics(
      child: Text(
        l10n.settingsTheme,
        style: Theme.of(context).textTheme.bodyLarge,
      ),
    );
    final largeText =
        MediaQuery.textScalerOf(context).scale(1) > largeTextScale;
    if (largeText) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: title,
            ),
            Semantics(
              container: true,
              explicitChildNodes: true,
              label: l10n.settingsTheme,
              child: RadioGroup<ThemeMode>(
                groupValue: value,
                onChanged: (mode) {
                  if (mode != null) onChanged(mode);
                },
                child: Column(
                  children: [
                    for (final (mode, icon, label) in options)
                      RadioListTile<ThemeMode>(
                        value: mode,
                        title: Text(label),
                        secondary: Icon(icon),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          title,
          const SizedBox(height: 12),
          Semantics(
            container: true,
            explicitChildNodes: true,
            label: l10n.settingsTheme,
            child: SegmentedButton<ThemeMode>(
              segments: [
                for (final (mode, icon, label) in options)
                  ButtonSegment(
                    value: mode,
                    icon: Icon(icon),
                    label: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              selected: {value},
              onSelectionChanged: (selection) => onChanged(selection.first),
            ),
          ),
        ],
      ),
    );
  }
}

/// The dark look: "Dim" (dark blue-grey) or "Lights out" (true black, the
/// default), stored as [AppSettings.pureBlack]. Disabled while the light
/// theme is forced.
class _DarkLookPicker extends StatelessWidget {
  const new({
    required this.lightsOut,
    required this.enabled,
    required this.onChanged,
  });

  final bool lightsOut;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final options = [
      (false, const Color(0xFF15202B), l10n.settingsDarkLookDim),
      (true, const Color(0xFF000000), l10n.settingsDarkLookLightsOut),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ExcludeSemantics(
              child: Text(
                l10n.settingsDarkLook,
                style: theme.textTheme.bodyLarge,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
            child: Text(
              l10n.settingsDarkLookSubtitle,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppPalette.of(context).secondaryText,
              ),
            ),
          ),
          Semantics(
            container: true,
            explicitChildNodes: true,
            label: l10n.settingsDarkLook,
            child: RadioGroup<bool>(
              groupValue: lightsOut,
              onChanged: (value) {
                if (value != null && value != lightsOut) onChanged(value);
              },
              child: Column(
                children: [
                  for (final (value, swatch, label) in options)
                    RadioListTile<bool>(
                      key: Key('settings_dark_look_$value'),
                      value: value,
                      enabled: enabled,
                      title: Text(label),
                      secondary: _LookSwatch(color: swatch),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A small round preview of a dark look's background (decorative).
class _LookSwatch extends StatelessWidget {
  const new({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Theme.of(context).colorScheme.outline),
      ),
    ),
  );
}
