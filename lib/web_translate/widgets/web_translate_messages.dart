import 'package:mozhi/core/network/network.dart'
    show describeNetworkPolicyError;
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/widgets/translate_error.dart';
import 'package:mozhi/web_translate/data/web_page_fetcher.dart';

/// A readable message for a page loading ([WebPageException]) or
/// translation error. A download the app's network policy refused (plain
/// http to a public host, a missing proxy) says so first.
String describeWebTranslateError(AppLocalizations l10n, Object? error) {
  if (describeNetworkPolicyError(l10n, error) case final message?) {
    return message;
  }
  if (error is! WebPageException) {
    return describeTranslateError(l10n, error).message;
  }
  return switch (error.error) {
    WebPageError.invalidUrl => l10n.webTranslateErrorInvalidUrl,
    WebPageError.network => l10n.webTranslateErrorNetwork,
    WebPageError.httpStatus => l10n.webTranslateErrorStatus(
      '${error.statusCode ?? '?'}',
    ),
    WebPageError.unsupportedContent => l10n.webTranslateErrorUnsupported(
      error.contentType ?? '?',
    ),
    WebPageError.timeout => l10n.webTranslateErrorTimeout,
    WebPageError.blockedByBrowser => l10n.webTranslateErrorBlocked,
    WebPageError.tooManyRedirects => l10n.webTranslateErrorRedirects,
    WebPageError.blockedRedirect => l10n.webTranslateErrorBlockedRedirect,
    WebPageError.noContent => l10n.webTranslateErrorNoContent,
  };
}

/// Whether text in the language [code] is written right to left.
bool isRtlLanguage(String? code) {
  if (code == null || code.isEmpty) return false;
  final primary = code.toLowerCase().split(RegExp('[-_]')).first;
  return _rtlLanguages.contains(primary);
}

const _rtlLanguages = {
  'ar',
  'arc',
  'ckb',
  'dv',
  'fa',
  'he',
  'iw',
  'ks',
  'ku',
  'ps',
  'sd',
  'ug',
  'ur',
  'yi',
};
