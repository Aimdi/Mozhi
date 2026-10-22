import 'package:equatable/equatable.dart';
import 'package:mozhi/sync/data/webdav_client.dart';

/// Why a sync (or the connection test) failed.
enum SyncFailure {
  /// The server refused the user name or app password (401).
  authFailed,

  /// The account may not use that folder (403).
  forbidden,

  /// The server address or the folder's parent does not exist.
  notFound,

  /// The folder's address is a file.
  notAFolder,

  /// The address does not answer WebDAV.
  notWebDav,

  /// The sync file is locked on the server (423).
  locked,

  /// The account's storage is full (507).
  insufficientStorage,

  /// The sync file or an answer is too large.
  tooLarge,

  /// The server refuses requests for a while (429).
  tooManyRequests,

  /// The address redirects elsewhere.
  redirected,

  /// Another server error.
  server,

  /// No connection.
  offline,

  /// The server took too long.
  timeout,

  /// The secure connection failed (certificate).
  tls,

  /// In the web app: the server is unreachable or does not allow requests
  /// from the app (CORS); a browser can't tell which.
  blockedByBrowser,

  /// Refused by the network policy (plain http to a public server, `.onion`
  /// without a proxy); [SyncException.cause] says which.
  policy,

  /// Other devices kept changing the file while this one tried to write
  /// it, even after a few retries.
  conflict,

  /// The passphrase does not open the sync file (setup, unlock).
  wrongPassphrase,

  /// The sync file was encrypted with another passphrase since this device
  /// last synced: it was changed on another device.
  passphraseChanged,

  /// The sync file does not decrypt with this device's key although it
  /// was written with it: damaged or changed on the server.
  damaged,

  /// The sync file is not a Mozhi backup.
  notSyncFile,

  /// The sync file was written by a newer version of Mozhi.
  newerVersion,

  /// This device's data could not be read or updated.
  localData,

  /// The app password or the key is not on this device (the web app forgets
  /// them when the tab closes; secure storage failed): enter them again.
  needsUnlock,

  /// Offline only is on: nothing is synced.
  offlineOnly;

  /// The failure of a WebDAV request.
  static SyncFailure ofWebDav(WebDavFailure failure) => switch (failure) {
    WebDavFailure.authFailed => authFailed,
    WebDavFailure.forbidden => forbidden,
    WebDavFailure.notFound => notFound,
    WebDavFailure.notAFolder => notAFolder,
    WebDavFailure.notWebDav => notWebDav,
    WebDavFailure.conflict => conflict,
    WebDavFailure.locked => locked,
    WebDavFailure.insufficientStorage => insufficientStorage,
    WebDavFailure.tooLarge => tooLarge,
    WebDavFailure.tooManyRequests => tooManyRequests,
    WebDavFailure.redirected => redirected,
    WebDavFailure.server => server,
    WebDavFailure.offline => offline,
    WebDavFailure.timeout => timeout,
    WebDavFailure.tls => tls,
    WebDavFailure.blockedByBrowser => blockedByBrowser,
    WebDavFailure.policy => policy,
  };

  /// Whether only the user can fix it (a new app password or passphrase,
  /// an update, a damaged file to delete): automatic syncs after a change
  /// wait for that instead of failing again, and against Nextcloud's
  /// password-guessing protection. A sync at app start still tries once.
  bool get needsUser => switch (this) {
    authFailed ||
    wrongPassphrase ||
    passphraseChanged ||
    damaged ||
    notSyncFile ||
    newerVersion ||
    needsUnlock => true,
    _ => false,
  };
}

/// A failed sync: [failure], the HTTP [statusCode] when a server answered,
/// and the error behind it (for [SyncFailure.policy], the network policy's
/// exception). Its [toString] never holds an address, a credential or the
/// user's data.
class SyncException implements Exception {
  const new(this.failure, {this.statusCode, this.cause});

  /// The sync failure of a WebDAV failure.
  factory fromWebDav(WebDavException error) => SyncException(
    SyncFailure.ofWebDav(error.failure),
    statusCode: error.statusCode,
    cause: error.cause,
  );

  final SyncFailure failure;
  final int? statusCode;
  final Object? cause;

  @override
  String toString() =>
      'SyncException(${failure.name}'
      '${statusCode == null ? '' : ', $statusCode'})';
}

/// What a successful sync did.
enum SyncResult {
  /// Nothing had changed on either side.
  unchanged,

  /// Changes from the server were merged into this device's data.
  received,

  /// This device's changes were written to the server.
  sent,

  /// Both: changes merged in, and the merged data written back.
  exchanged,
}

/// The outcome of the last sync, kept between starts: when it last
/// succeeded ([lastSyncAt], with its [lastResult]) and, when the last
/// attempt failed, when and why ([lastFailureAt], [lastFailure]).
class SyncStatus extends Equatable {
  const new({
    this.lastSyncAt,
    this.lastResult,
    this.lastFailureAt,
    this.lastFailure,
  });

  factory fromJson(Object? json) {
    if (json is! Map) return const SyncStatus();
    DateTime? time(Object? value) =>
        value is String ? DateTime.tryParse(value)?.toLocal() : null;
    T? pick<T extends Enum>(List<T> values, Object? name) =>
        values.where((value) => value.name == name).firstOrNull;
    return SyncStatus(
      lastSyncAt: time(json['lastSyncAt']),
      lastResult: pick(SyncResult.values, json['lastResult']),
      lastFailureAt: time(json['lastFailureAt']),
      lastFailure: pick(SyncFailure.values, json['lastFailure']),
    );
  }

  final DateTime? lastSyncAt;
  final SyncResult? lastResult;

  /// Set when the last attempt failed (cleared by the next success).
  final DateTime? lastFailureAt;
  final SyncFailure? lastFailure;

  /// After a successful sync at [at].
  SyncStatus succeeded(DateTime at, SyncResult result) =>
      SyncStatus(lastSyncAt: at, lastResult: result);

  /// After a failed attempt at [at].
  SyncStatus failed(DateTime at, SyncFailure failure) => SyncStatus(
    lastSyncAt: lastSyncAt,
    lastResult: lastResult,
    lastFailureAt: at,
    lastFailure: failure,
  );

  Map<String, Object?> toJson() => {
    'lastSyncAt': lastSyncAt?.toUtc().toIso8601String(),
    'lastResult': lastResult?.name,
    'lastFailureAt': lastFailureAt?.toUtc().toIso8601String(),
    'lastFailure': lastFailure?.name,
  };

  @override
  List<Object?> get props => [
    lastSyncAt,
    lastResult,
    lastFailureAt,
    lastFailure,
  ];
}
