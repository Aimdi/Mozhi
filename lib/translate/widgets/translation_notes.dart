import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

/// What the checks after a finished translation have to say, as quiet
/// lines under it: the fallback note ([TranslateState.fallback]: "Google
/// returned the original text. Translated on this device.", "Google failed
/// on every server, so DuckDuckGo translated this."), how many items
/// of personal data stayed on the device
/// ([TranslationResult.maskedPersonalData]) and one line per warning
/// ([TranslationResult.warnings]: lost placeholders, links or numbers,
/// unused glossary terms, the wrong language, ...).
///
/// Nothing while the translation streams, or when there is nothing to say
/// ([hasNotes]). The lines are one labelled group for screen readers
/// ("Translation checks"); their icons are decorative.
class TranslationNotes extends StatelessWidget {
  const new({required this.state, super.key});

  final TranslateState state;

  /// Whether [state]'s finished result has anything to show.
  static bool hasNotes(TranslateState state) {
    final result = state.result;
    if (result == null || !result.isComplete) return false;
    return state.fallback != null ||
        result.maskedPersonalData > 0 ||
        result.warnings.isNotEmpty;
  }

  /// The line for [warning] of a translation into [target].
  static String warningText(
    AppLocalizations l10n,
    TranslationWarning warning, {
    required Language target,
  }) => switch (warning.kind) {
    TranslationWarningKind.placeholders => l10n.translateWarningPlaceholders,
    TranslationWarningKind.markup => l10n.translateWarningMarkup,
    TranslationWarningKind.links => l10n.translateWarningLinks,
    TranslationWarningKind.emails => l10n.translateWarningEmails,
    TranslationWarningKind.numbers => l10n.translateWarningNumbers,
    TranslationWarningKind.glossary => l10n.translateWarningGlossary(
      warning.items.join(', '),
    ),
    TranslationWarningKind.echo => l10n.translateWarningEcho,
    TranslationWarningKind.wrongLanguage => l10n.translateWarningWrongLanguage(
      languageDisplayName(target, l10n.localeName),
    ),
    TranslationWarningKind.length => l10n.translateWarningLength,
    TranslationWarningKind.notATranslation => l10n.translateWarningReply,
    TranslationWarningKind.personalDataLost =>
      l10n.translateWarningPersonalDataLost,
  };

  /// "Google returned the original text. Translated on this device.", or
  /// "Google failed on every server, so DuckDuckGo translated this."
  static String fallbackText(
    AppLocalizations l10n,
    TranslationFallback fallback,
  ) {
    final engine = fallback.fromEngineName;
    if (fallback.allServersFailed) {
      return l10n.translateFallbackAllServers(engine, fallback.engineName);
    }
    final reason = switch (fallback.reason) {
      TranslationWarningKind.wrongLanguage =>
        l10n.translateFallbackWrongLanguage(engine),
      TranslationWarningKind.length => l10n.translateFallbackLength(engine),
      TranslationWarningKind.notATranslation => l10n.translateFallbackReply(
        engine,
      ),
      _ => l10n.translateFallbackEcho(engine),
    };
    final translated = fallback.onDevice
        ? l10n.translateFallbackOnDevice
        : l10n.translateFallbackWith(fallback.engineName);
    return '$reason $translated';
  }

  @override
  Widget build(BuildContext context) {
    final result = state.result;
    if (result == null || !hasNotes(state)) return const SizedBox.shrink();
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final fallback = state.fallback;
    final lines = <Widget>[
      if (fallback != null)
        _NoteLine(
          key: const Key('translate_note_fallback'),
          icon: fallback.onDevice
              ? Icons.offline_bolt_outlined
              : fallback.allServersFailed
              ? Icons.alt_route
              : Icons.swap_horiz,
          text: fallbackText(l10n, fallback),
        ),
      if (result.maskedPersonalData > 0)
        _NoteLine(
          key: const Key('translate_note_personal_data'),
          icon: Icons.shield_outlined,
          text: l10n.translatePersonalDataKept(result.maskedPersonalData),
          hint: l10n.translatePersonalDataKeptHint,
        ),
      for (final (index, warning) in result.warnings.indexed)
        _NoteLine(
          key: Key('translate_note_warning_${warning.kind.name}_$index'),
          icon: Icons.warning_amber_rounded,
          iconColor: colors.error,
          text: warningText(l10n, warning, target: state.target),
        ),
    ];
    return Semantics(
      key: const Key('translate_notes'),
      container: true,
      explicitChildNodes: true,
      label: l10n.translateWarningsLabel,
      child: Padding(
        padding: const EdgeInsetsDirectional.only(top: 10, end: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: lines,
        ),
      ),
    );
  }
}

/// One note: a small icon and a line of muted text.
class _NoteLine extends StatelessWidget {
  const new({
    required this.icon,
    required this.text,
    this.iconColor,
    this.hint,
    super.key,
  });

  final IconData icon;
  final String text;
  final Color? iconColor;

  /// Read to screen readers after [text].
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = AppPalette.of(context).secondaryText;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: MergeSemantics(
        child: Semantics(
          hint: hint,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsetsDirectional.only(top: 1, end: 6),
                child: ExcludeSemantics(
                  child: Icon(icon, size: 16, color: iconColor ?? muted),
                ),
              ),
              Expanded(
                child: Text(
                  text,
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
