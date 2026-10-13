import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/usage/models/models.dart';

/// Locale-aware formatting of usage numbers for the current [BuildContext].
extension UsageFormat on BuildContext {
  String get _numberLocale => Intl.verifiedLocale(
    Localizations.localeOf(this).toString(),
    NumberFormat.localeExists,
    onFailure: (_) => 'en',
  )!;

  /// [value] with digit grouping, e.g. `12,345`.
  String usageNumber(int value) =>
      NumberFormat.decimalPattern(_numberLocale).format(value);

  /// [fraction] as a whole percentage, e.g. `80%`.
  String usagePercent(double fraction) =>
      NumberFormat.percentPattern(_numberLocale).format(fraction);

  /// "12 requests".
  String usageRequests(int count) =>
      l10n.usageRequestCount(count, usageNumber(count));

  /// "1,234 characters".
  String usageCharacters(int count) =>
      l10n.usageCharacterCount(count, usageNumber(count));

  /// "≈ 310 tokens".
  String usageTokens(int count) =>
      l10n.usageTokenEstimate(count, usageNumber(count));

  /// Short month name, e.g. `Oct`.
  String usageMonthShort(UsageMonth month) {
    final locale = Intl.verifiedLocale(
      Localizations.localeOf(this).toString(),
      DateFormat.localeExists,
      onFailure: (_) => 'en',
    );
    return DateFormat.MMM(locale).format(month.start);
  }

  /// Month and year, e.g. `October 2026`.
  String usageMonthYear(UsageMonth month) =>
      MaterialLocalizations.of(this).formatMonthYear(month.start);

  /// Colour for a budget [level].
  Color usageLevelColor(UsageBudgetLevel level) {
    final scheme = Theme.of(this).colorScheme;
    return switch (level) {
      UsageBudgetLevel.ok => scheme.primary,
      UsageBudgetLevel.nearLimit =>
        scheme.brightness == Brightness.dark
            ? const Color(0xFFFFC870)
            : const Color(0xFF8A5A00),
      UsageBudgetLevel.limitReached => scheme.error,
    };
  }
}
