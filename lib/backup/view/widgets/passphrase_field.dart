import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/backup/models/passphrase_strength.dart';
import 'package:mozhi/l10n/l10n.dart';

export 'package:mozhi/backup/models/passphrase_strength.dart';

/// A passphrase text field: hidden while typed (with a show/hide button),
/// no autocorrect, suggestions or keyboard learning, and the password
/// autofill hint ([newPassphrase]: a new one, so password managers can
/// offer to save it).
class PassphraseField extends StatefulWidget {
  const new({
    required this.controller,
    this.label,
    this.errorText,
    this.helperText,
    this.newPassphrase = false,
    this.autofocus = false,
    this.enabled = true,
    this.textInputAction,
    this.onChanged,
    this.onSubmitted,
    super.key,
  });

  final TextEditingController controller;

  /// The label (default: "Passphrase").
  final String? label;
  final String? errorText;
  final String? helperText;

  /// Whether this sets a new passphrase (rather than entering one).
  final bool newPassphrase;
  final bool autofocus;
  final bool enabled;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  State<PassphraseField> createState() => _PassphraseFieldState();
}

class _PassphraseFieldState extends State<PassphraseField> {
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
      autofillHints: [
        if (widget.newPassphrase)
          AutofillHints.newPassword
        else
          AutofillHints.password,
      ],
      inputFormatters: [
        // A passphrase is one line.
        FilteringTextInputFormatter.deny(RegExp('[\r\n]')),
      ],
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      decoration: InputDecoration(
        labelText: widget.label ?? l10n.backupPassphrase,
        errorText: widget.errorText,
        errorMaxLines: 3,
        helperText: widget.helperText,
        helperMaxLines: 4,
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(
          tooltip: _visible
              ? l10n.backupPassphraseHide
              : l10n.backupPassphraseShow,
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

/// How strong [passphrase] is ([PassphraseStrength]): a three-step meter
/// and a sentence (not colour alone), read by screen readers as it
/// changes. Shows nothing for an empty passphrase.
class PassphraseStrengthHint extends StatelessWidget {
  const new({required this.passphrase, super.key});

  final String passphrase;

  @override
  Widget build(BuildContext context) {
    if (passphrase.isEmpty) return const SizedBox.shrink();
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final strength = PassphraseStrength.of(passphrase);
    final (text, color, steps) = switch (strength) {
      PassphraseStrength.tooShort => (
        l10n.backupPassphraseTooShort(PassphraseStrength.minLength),
        colors.error,
        0,
      ),
      PassphraseStrength.weak => (l10n.backupStrengthWeak, colors.error, 1),
      PassphraseStrength.fair => (l10n.backupStrengthFair, colors.tertiary, 2),
      PassphraseStrength.strong => (
        l10n.backupStrengthStrong,
        colors.primary,
        3,
      ),
    };
    return Semantics(
      container: true,
      liveRegion: true,
      label: l10n.backupStrengthSemantics(text),
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.only(top: AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                for (var i = 0; i < 3; i++) ...[
                  if (i > 0) const SizedBox(width: AppSpacing.xs),
                  Expanded(
                    child: Container(
                      height: 4,
                      decoration: BoxDecoration(
                        color: i < steps
                            ? color
                            : colors.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(
                          AppLook.of(context).controlRadius(2),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: steps <= 1 ? colors.error : colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
