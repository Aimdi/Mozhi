import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/semantics.dart'
    show AttributedString, LocaleStringAttribute;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/app/view/app_shell.dart' show AppDestination;
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/screen_translate/view/screen_translate_settings.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_languages.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/widgets/choice_dialog.dart';
import 'package:mozhi/settings/view/widgets/offline_app_shell_tile.dart';
import 'package:mozhi/settings/view/widgets/settings_search.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';

/// Anchors ([SettingsAnchor.id]) of the General settings.
abstract final class GeneralAnchors {
  static const appLanguage = 'app_language';
  static const tabOrder = 'tab_order';
  static const hapticFeedback = 'haptic_feedback';
  static const multilineInput = 'multiline_input';
  static const offlineAppShell = 'offline_app_shell';
}

/// The General settings: app language, tab order, haptic feedback (not in
/// browsers, which cannot vibrate), multiline input and, in the web app,
/// "Keep the web app for offline use" ([OfflineAppShellTile]), then
/// **Android integration** (Translate screen and its bubble,
/// [ScreenTranslateSettingsSection]).
class GeneralSettings extends StatelessWidget {
  const new({required this.settings, super.key});

  final AppSettings settings;

  /// Whether the haptic feedback switch is shown.
  static bool get hapticFeedbackSupported => !kIsWeb;

  /// Whether "Keep the web app for offline use" is shown (the web app).
  static bool get offlineAppShellSupported => kIsWeb;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<SettingsCubit>();
    final home = AppDestination.of(settings.tabOrder.first).label(l10n);
    final general = SettingsSection(
      children: [
        SettingsAnchor(
          id: GeneralAnchors.appLanguage,
          child: _AppLanguageTile(appLocale: settings.appLocale),
        ),
        SettingsAnchor(
          id: GeneralAnchors.tabOrder,
          child: ListTile(
            key: const Key('settings_tab_order'),
            leading: const SettingsIcon(Icons.swap_vert),
            title: Text(l10n.settingsTabOrder),
            subtitle: Text(l10n.settingsTabOrderSubtitle(home)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push(AppRoutes.tabOrder),
          ),
        ),
        if (hapticFeedbackSupported)
          SettingsAnchor(
            id: GeneralAnchors.hapticFeedback,
            child: SwitchListTile(
              key: const Key('settings_haptic_feedback'),
              secondary: const SettingsIcon(Icons.vibration),
              title: Text(l10n.settingsHapticFeedback),
              subtitle: Text(l10n.settingsHapticFeedbackSubtitle),
              value: settings.hapticFeedback,
              onChanged: (value) => cubit.setHapticFeedback(enabled: value),
            ),
          ),
        SettingsAnchor(
          id: GeneralAnchors.multilineInput,
          child: SwitchListTile(
            key: const Key('settings_multiline_input'),
            secondary: const SettingsIcon(Icons.keyboard_return),
            title: Text(l10n.settingsMultilineInput),
            subtitle: Text(l10n.settingsMultilineInputSubtitle),
            value: settings.multilineInput,
            onChanged: (value) => cubit.setMultilineInput(enabled: value),
          ),
        ),
        if (offlineAppShellSupported)
          SettingsAnchor(
            id: GeneralAnchors.offlineAppShell,
            child: OfflineAppShellTile(enabled: settings.offlineAppShell),
          ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [general, const ScreenTranslateSettingsSection()],
    );
  }
}

/// The language of the app's texts: "System default" or one of
/// [AppLanguages.supported], each named in itself.
class _AppLanguageTile extends StatelessWidget {
  const new({required this.appLocale});

  final String? appLocale;

  /// The choice value of "System default".
  static const _system = '';

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final locale = AppLanguages.resolve(appLocale);
    return ListTile(
      key: const Key('settings_app_language'),
      leading: const SettingsIcon(Icons.language),
      title: Text(l10n.settingsAppLanguage),
      subtitle: locale == null
          ? Text(l10n.settingsAppLanguageSystem)
          : _NativeLanguageName(locale),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _pick(context, locale),
    );
  }

  Future<void> _pick(BuildContext context, Locale? current) async {
    final l10n = context.l10n;
    final cubit = context.read<SettingsCubit>();
    final initial = current?.toLanguageTag() ?? _system;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => ChoiceDialog<String>(
        title: l10n.settingsAppLanguage,
        body: l10n.settingsAppLanguageDialogBody,
        initialValue: initial,
        options: [
          ChoiceDialogOption(
            value: _system,
            title: Text(l10n.settingsAppLanguageSystem),
          ),
          for (final locale in AppLanguages.byName)
            ChoiceDialogOption(
              value: locale.toLanguageTag(),
              title: _NativeLanguageName(locale),
            ),
        ],
      ),
    );
    if (choice == null || choice == initial) return;
    cubit.setAppLocale(choice == _system ? null : choice);
  }
}

/// The name of [locale]'s language in itself ("Deutsch", "日本語"), drawn
/// with that language's glyphs and read by screen readers in it.
class _NativeLanguageName extends StatelessWidget {
  const new(this.locale);

  final Locale locale;

  @override
  Widget build(BuildContext context) {
    final name = AppLanguages.nativeName(locale);
    return Semantics(
      attributedLabel: AttributedString(
        name,
        attributes: [
          LocaleStringAttribute(
            range: TextRange(start: 0, end: name.length),
            locale: locale,
          ),
        ],
      ),
      excludeSemantics: true,
      child: Text(name, locale: locale),
    );
  }
}
