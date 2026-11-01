import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/view/widgets/link_launcher.dart';
import 'package:translation_repository/translation_repository.dart';

/// The credit of Wiktionary's data in general (before a pack is open).
const wiktionaryAttribution = DictionaryAttribution(
  source: 'Wiktionary',
  sourceUrl: 'https://www.wiktionary.org/',
  license: 'CC BY-SA 4.0',
  licenseUrl: 'https://creativecommons.org/licenses/by-sa/4.0/',
);

/// Shows [attribution] in a [DictionaryAttributionDialog], with [text]
/// instead of its own credit when given.
Future<void> showDictionaryAttribution(
  BuildContext context,
  DictionaryAttribution attribution, {
  String? text,
}) => showDialog<void>(
  context: context,
  builder: (_) =>
      DictionaryAttributionDialog(attribution: attribution, text: text),
);

/// Where an offline dictionary's data comes from: the credit its licence
/// requires (who wrote it, where, what was changed; in English, as the
/// pack has it), the date of the data, and links to the licence and the
/// source, opened in the browser.
class DictionaryAttributionDialog extends StatelessWidget {
  const new({required this.attribution, this.text, super.key});

  final DictionaryAttribution attribution;

  /// Shown instead of [DictionaryAttribution.text].
  final String? text;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final muted = AppPalette.of(context).secondaryText;
    final credit = (text ?? attribution.text).trim();
    final license = Uri.tryParse(attribution.licenseUrl);
    final source = Uri.tryParse(attribution.sourceUrl);
    bool linkable(Uri? uri) =>
        uri != null && (uri.isScheme('https') || uri.isScheme('http'));
    return AlertDialog(
      key: const Key('dictionary_attribution'),
      icon: const Icon(Icons.menu_book_outlined),
      title: Text(
        l10n.dictionaryAttributionTitle,
        style: theme.textTheme.titleLarge,
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            Text(
              l10n.dictionaryOfflineSource(
                attribution.source,
                attribution.license,
              ),
              style: theme.textTheme.titleSmall,
            ),
            if (credit.isNotEmpty)
              SelectableText(
                credit,
                style: theme.textTheme.bodyMedium?.copyWith(color: muted),
              ),
            if (attribution.snapshot.trim().isNotEmpty)
              Text(
                l10n.dictionaryAttributionSnapshot(attribution.snapshot.trim()),
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
          ],
        ),
      ),
      actionsOverflowButtonSpacing: 8,
      actions: [
        if (linkable(source))
          TextButton(
            key: const Key('dictionary_attribution_source'),
            onPressed: () => unawaited(LinkLauncher.open(context, source!)),
            child: Text(l10n.dictionaryAttributionSource),
          ),
        if (linkable(license))
          TextButton(
            key: const Key('dictionary_attribution_license'),
            onPressed: () => unawaited(LinkLauncher.open(context, license!)),
            child: Text(l10n.dictionaryAttributionLicense),
          ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonClose),
        ),
      ],
    );
  }
}

/// "From Wiktionary · CC BY-SA 4.0", small and muted, opening the
/// [DictionaryAttributionDialog]: the label of entries from an offline
/// dictionary (instead of "AI-generated"). With [glossLanguage], it adds
/// the language of the definitions ("· Definitions in English").
class DictionaryAttributionLink extends StatelessWidget {
  const new({required this.attribution, super.key, this.glossLanguage});

  final DictionaryAttribution attribution;

  /// The language code the definitions are written in, e.g. `en`.
  final String? glossLanguage;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final muted = AppPalette.of(context).secondaryText;
    return Tooltip(
      message: l10n.dictionaryOfflineSourceHint,
      child: TextButton.icon(
        key: const Key('dictionary_offline_source'),
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          foregroundColor: muted,
          textStyle: theme.textTheme.labelSmall,
        ),
        onPressed: () =>
            unawaited(showDictionaryAttribution(context, attribution)),
        icon: const Icon(Icons.menu_book_outlined, size: 14),
        label: Text(
          [
            l10n.dictionaryOfflineSource(
              attribution.source,
              attribution.license,
            ),
            if (glossLanguage case final code?)
              l10n.dictionaryDefinitionsIn(context.languageNameOf(code)),
          ].join(' · '),
        ),
      ),
    );
  }
}
