import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/privacy/ime_learning.dart';
import 'package:mozhi/l10n/l10n.dart';

/// Address field with paste and clear buttons. Submitting (keyboard "go")
/// calls [onSubmitted].
class WebUrlField extends StatelessWidget {
  const new({
    required this.controller,
    required this.onChanged,
    required this.onSubmitted,
    this.invalid = false,
    this.enabled = true,
    super.key,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onSubmitted;
  final bool invalid;
  final bool enabled;

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) return;
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    onChanged(text);
    onSubmitted();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        return TextField(
          key: const Key('web_translate_url_field'),
          controller: controller,
          enableIMEPersonalizedLearning: imeLearningAllowed(context),
          enabled: enabled,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.go,
          autocorrect: false,
          enableSuggestions: false,
          autofillHints: const [AutofillHints.url],
          onChanged: onChanged,
          onSubmitted: (_) => onSubmitted(),
          decoration: InputDecoration(
            labelText: l10n.webTranslateUrlLabel,
            hintText: l10n.webTranslateUrlHint,
            errorText: invalid ? l10n.webTranslateInvalidUrl : null,
            prefixIcon: const Icon(Icons.link),
            suffixIcon: value.text.isEmpty
                ? IconButton(
                    key: const Key('web_translate_paste_button'),
                    tooltip: l10n.webTranslatePaste,
                    icon: const Icon(Icons.content_paste),
                    onPressed: enabled ? () => unawaited(_paste()) : null,
                  )
                : IconButton(
                    key: const Key('web_translate_clear_button'),
                    tooltip: l10n.commonClear,
                    icon: const Icon(Icons.close),
                    onPressed: enabled
                        ? () {
                            controller.clear();
                            onChanged('');
                          }
                        : null,
                  ),
          ),
        );
      },
    );
  }
}
