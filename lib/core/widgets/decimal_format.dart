import 'package:intl/intl.dart';

/// [value] with [fractionDigits] decimals, in the number format of
/// [locale] (`AppLocalizations.localeName`): "0.8" in English, "0,8" in
/// German. Locales intl has no number format for fall back to English.
///
/// With [trimZero], whole numbers go without decimals ("2", not "2.0").
String formatDecimal(
  num value,
  String locale, {
  int fractionDigits = 1,
  bool trimZero = false,
}) {
  final verified = Intl.verifiedLocale(
    locale,
    NumberFormat.localeExists,
    onFailure: (_) => 'en',
  );
  final format = NumberFormat.decimalPattern(verified)
    ..minimumFractionDigits = trimZero ? 0 : fractionDigits
    ..maximumFractionDigits = fractionDigits;
  return format.format(value);
}
