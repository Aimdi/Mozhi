import 'package:intl/intl.dart';
import 'package:mozhi/l10n/l10n.dart';

/// "2.6 GB" from 1 GiB on, else "640.0 MB", in the locale of [l10n]: the
/// size of an on-device AI model (hundreds of MB to a few GB).
String formatModelSize(AppLocalizations l10n, int bytes) {
  const mebibyte = 1024 * 1024;
  const gibibyte = 1024 * mebibyte;
  final number = NumberFormat('0.0', l10n.localeName);
  if (bytes >= gibibyte) {
    return l10n.onDeviceAiSizeGigabytes(number.format(bytes / gibibyte));
  }
  return l10n.commonSizeMegabytes(number.format(bytes / mebibyte));
}
