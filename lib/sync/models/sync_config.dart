import 'package:equatable/equatable.dart';
import 'package:mozhi/sync/data/webdav_client.dart';

/// Where and what this device syncs: the WebDAV [server] and [folder], the
/// account's [username] (its app password is kept in secure storage, see
/// `SyncStore`) and the choices of what to sync. Kept in the plain
/// preferences: none of it is secret.
class SyncConfig extends Equatable {
  const new({
    required this.server,
    required this.username,
    this.folder = defaultFolder,
    this.excludedSections = defaultExcludedSections,
    this.includeSecrets = false,
    this.wifiOnly = false,
  });

  /// Parses [toJson] output; null when [json] is not a valid config.
  static SyncConfig? tryParse(Object? json) {
    if (json case {
      'server': final String server,
      'username': final String username,
    }) {
      final uri = Uri.tryParse(server);
      if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
      return SyncConfig(
        server: uri,
        username: username,
        folder: switch (json['folder']) {
          final String folder => folder,
          _ => defaultFolder,
        },
        excludedSections: switch (json['excludedSections']) {
          final List<Object?> ids => {...ids.whereType<String>()},
          _ => defaultExcludedSections,
        },
        includeSecrets: json['includeSecrets'] == true,
        wifiOnly: json['wifiOnly'] == true,
      );
    }
    return null;
  }

  /// The folder new setups suggest.
  static const defaultFolder = 'Mozhi';

  /// The file in [folder] that holds the encrypted snapshot.
  static const fileName = 'mozhi-sync.mozhibackup';

  /// The settings are left out unless chosen: some are about one device
  /// (privacy mode, proxy, theme) and they change after every
  /// translation (the last language pair).
  static const defaultExcludedSections = {'settings'};

  /// The id of the settings section, the only one with secrets.
  static const settingsSection = 'settings';

  /// The WebDAV address (Nextcloud:
  /// `https://cloud.example.org/remote.php/dav/files/alice/`), without
  /// user info.
  final Uri server;
  final String username;

  /// The folder below [server] (`Mozhi`, `Apps/Mozhi`; empty: [server]
  /// itself).
  final String folder;

  /// Backup sections this device does not sync. Sections are synced unless
  /// listed here, so ones a later version adds are synced too.
  final Set<String> excludedSections;

  /// Whether the settings carry their secrets (API keys, instance
  /// passwords) when they are synced.
  final bool includeSecrets;

  /// Whether automatic syncs wait for an unmetered network (Wi-Fi);
  /// **Sync now** always runs.
  final bool wifiOnly;

  /// The folder's URL.
  Uri get folderUrl => WebDavClient.folderUrl(server, folder);

  /// Whether the section [id] is synced.
  bool syncs(String id) => !excludedSections.contains(id);

  /// The ids of [all] that are synced.
  Set<String> syncedOf(Iterable<String> all) => {...all.where(syncs)};

  /// Whether the synced data includes secrets.
  bool get syncsSecrets => includeSecrets && syncs(settingsSection);

  SyncConfig copyWith({
    Uri? server,
    String? username,
    String? folder,
    Set<String>? excludedSections,
    bool? includeSecrets,
    bool? wifiOnly,
  }) => SyncConfig(
    server: server ?? this.server,
    username: username ?? this.username,
    folder: folder ?? this.folder,
    excludedSections: excludedSections ?? this.excludedSections,
    includeSecrets: includeSecrets ?? this.includeSecrets,
    wifiOnly: wifiOnly ?? this.wifiOnly,
  );

  Map<String, Object?> toJson() => {
    'server': server.toString(),
    'username': username,
    'folder': folder,
    'excludedSections': [...excludedSections]..sort(),
    'includeSecrets': includeSecrets,
    'wifiOnly': wifiOnly,
  };

  @override
  List<Object?> get props => [
    server,
    username,
    folder,
    excludedSections,
    includeSecrets,
    wifiOnly,
  ];
}

/// What the last successful sync left: the ETag of the file it read or
/// wrote (null when the server sent none) and the fingerprint of this
/// device's synced data afterwards. With both unchanged, a sync costs one
/// `GET` answered `304 Not Modified`, and a change elsewhere in the app
/// that didn't touch synced data costs no request at all.
///
/// [remoteFingerprint] is the fingerprint of the synced parts of the file
/// as it was left, when that differs from this device's data (the file
/// keeps history this device's "Delete history automatically" dropped,
/// see `BackupSyncSection`); null when they are the same, and in cursors
/// stored by earlier versions.
class SyncCursor extends Equatable {
  const new({required this.fingerprint, this.etag, this.remoteFingerprint});

  static SyncCursor? tryParse(Object? json) {
    if (json case {'fingerprint': final String fingerprint}) {
      return SyncCursor(
        fingerprint: fingerprint,
        etag: switch (json['etag']) {
          final String etag => etag,
          _ => null,
        },
        remoteFingerprint: switch (json['remote']) {
          final String remote => remote,
          _ => null,
        },
      );
    }
    return null;
  }

  final String fingerprint;
  final String? etag;
  final String? remoteFingerprint;

  /// The fingerprint of the file's synced parts as this sync left them.
  String get fileFingerprint => remoteFingerprint ?? fingerprint;

  Map<String, Object?> toJson() => {
    'fingerprint': fingerprint,
    'etag': etag,
    if (remoteFingerprint != null) 'remote': remoteFingerprint,
  };

  @override
  List<Object?> get props => [fingerprint, etag, remoteFingerprint];
}
