import 'package:flutter/widgets.dart' show Locale;
import 'package:mozhi/conversation/share/data/share_room.dart';
import 'package:mozhi/conversation/share/data/share_server_stub.dart'
    if (dart.library.io) 'package:mozhi/conversation/share/data/share_server_io.dart'
    as impl;
import 'package:mozhi/l10n/l10n.dart';

/// The texts of the guest page for a guest asking in [languageCodes]
/// (their chosen language, then the browser's `Accept-Language`, best
/// first): the app's language that matches first, else English.
typedef ShareStrings = AppLocalizations Function(List<String> languageCodes);

/// A running local network server of a [ShareRoom] (see
/// `share_server_io.dart`).
abstract interface class ShareServer {
  /// The guests' link: `http://<address>:<port>/s/<token>`.
  Uri get url;

  /// Ends the update streams (guests see "The conversation ended") and
  /// stops listening.
  Future<void> close();
}

/// Starts a [ShareServer] for [room] on the private IPv4 [address], on a
/// random free port. Android (any `dart:io` platform) only: elsewhere it
/// throws an [UnsupportedError].
typedef ShareServerFactory = Future<ShareServer> Function({
  required String address,
  required ShareRoom room,
  required ShareStrings strings,
});

/// The platform's [ShareServerFactory].
Future<ShareServer> startShareServer({
  required String address,
  required ShareRoom room,
  required ShareStrings strings,
}) => impl.startShareServer(address: address, room: room, strings: strings);

/// Whether this platform can host a shared conversation (`dart:io`).
bool get shareServerSupported => impl.shareServerSupported;

/// The default [ShareStrings]: the app's texts in the first of
/// [languageCodes] the app speaks (by primary language: `pt-BR` gets
/// Portuguese), else in English.
AppLocalizations shareStrings(List<String> languageCodes) {
  for (final code in languageCodes) {
    final primary = code.trim().split(RegExp('[-_]')).first.toLowerCase();
    if (primary.isEmpty) continue;
    final locale = Locale(primary);
    if (!AppLocalizations.delegate.isSupported(locale)) continue;
    // Every language is built into the Android app (the web app, which
    // loads them on demand, cannot host).
    return lookupAppLocalizations(locale);
  }
  return lookupAppLocalizations(const Locale('en'));
}
