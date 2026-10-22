import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/backup/view/backup_section_labels.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/sync/models/sync_config.dart';

/// The app password field: hidden while typed (with a show/hide button),
/// no autocorrect, suggestions or keyboard learning, the password autofill
/// hint.
class SyncPasswordField extends StatefulWidget {
  const new({
    required this.controller,
    this.enabled = true,
    this.autofocus = false,
    this.helperText,
    this.errorText,
    this.textInputAction,
    this.onChanged,
    this.onSubmitted,
    super.key,
  });

  final TextEditingController controller;
  final bool enabled;
  final bool autofocus;
  final String? helperText;
  final String? errorText;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  State<SyncPasswordField> createState() => _SyncPasswordFieldState();
}

class _SyncPasswordFieldState extends State<SyncPasswordField> {
  bool _visible = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return TextField(
      controller: widget.controller,
      enabled: widget.enabled,
      autofocus: widget.autofocus,
      obscureText: !_visible,
      autocorrect: false,
      enableSuggestions: false,
      enableIMEPersonalizedLearning: false,
      keyboardType: TextInputType.visiblePassword,
      textInputAction: widget.textInputAction,
      autofillHints: const [AutofillHints.password],
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      decoration: InputDecoration(
        labelText: l10n.syncPasswordLabel,
        helperText: widget.helperText,
        helperMaxLines: 4,
        errorText: widget.errorText,
        errorMaxLines: 3,
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(
          tooltip: _visible ? l10n.syncHidePassword : l10n.syncShowPassword,
          icon: Icon(
            _visible
                ? Icons.visibility_off_outlined
                : Icons.visibility_outlined,
          ),
          onPressed: widget.enabled
              ? () => setState(() => _visible = !_visible)
              : null,
        ),
      ),
    );
  }
}

/// What to sync: a checkbox per section ([sectionIds], named like the
/// backup's), and, while the settings are synced, whether their secrets
/// go along (with the warning).
class SyncSectionsPicker extends StatelessWidget {
  const new({
    required this.sectionIds,
    required this.excluded,
    required this.includeSecrets,
    required this.onExcludedChanged,
    required this.onIncludeSecretsChanged,
    this.enabled = true,
    super.key,
  });

  final List<String> sectionIds;
  final Set<String> excluded;
  final bool includeSecrets;
  final ValueChanged<Set<String>> onExcludedChanged;
  final ValueChanged<bool> onIncludeSecretsChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final settingsSynced =
        sectionIds.contains(SyncConfig.settingsSection) &&
        !excluded.contains(SyncConfig.settingsSection);
    final synced = sectionIds.where((id) => !excluded.contains(id)).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final id in sectionIds)
          CheckboxListTile(
            key: Key('sync_section_$id'),
            contentPadding: EdgeInsets.zero,
            secondary: ExcludeSemantics(
              child: Icon(BackupSectionLabels.icon(id)),
            ),
            title: Text(BackupSectionLabels.name(l10n, id)),
            value: !excluded.contains(id),
            // The last one stays: syncing nothing is turning sync off.
            onChanged: !enabled || (synced == 1 && !excluded.contains(id))
                ? null
                : (value) => onExcludedChanged(
                    value ?? false
                        ? ({...excluded}..remove(id))
                        : {...excluded, id},
                  ),
          ),
        if (synced == 1)
          Text(
            l10n.syncSectionsNone,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        if (sectionIds.contains(SyncConfig.settingsSection) && !settingsSynced)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: Text(
              l10n.syncSettingsNote,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        if (settingsSynced) ...[
          SwitchListTile(
            key: const Key('sync_include_secrets'),
            contentPadding: EdgeInsets.zero,
            secondary: const ExcludeSemantics(child: Icon(Icons.key_outlined)),
            title: Text(l10n.syncSecretsInclude),
            value: includeSecrets,
            onChanged: enabled ? onIncludeSecretsChanged : null,
          ),
          if (includeSecrets)
            Text(
              l10n.syncSecretsWarning,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
        ],
      ],
    );
  }
}

/// A small spinner for buttons and rows while sync works: an hourglass
/// when animations are off.
class SyncSpinner extends StatelessWidget {
  const new({this.size = 18, super.key});

  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: MediaQuery.disableAnimationsOf(context)
        ? Icon(Icons.hourglass_top, size: size)
        : const CircularProgressIndicator(strokeWidth: 2),
  );
}
