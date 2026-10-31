import 'dart:async';
import 'dart:typed_data';

import 'package:equatable/equatable.dart';
import 'package:http/http.dart' as http;
import 'package:mozhi/backup/data/backup_codec.dart';
import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/core/network/network_session.dart';
import 'package:mozhi/core/privacy/egress/egress.dart';
import 'package:mozhi/platform/metered_network.dart';
import 'package:mozhi/sync/data/sync_engine.dart';
import 'package:mozhi/sync/data/sync_store.dart';
import 'package:mozhi/sync/data/webdav_client.dart';
import 'package:mozhi/sync/models/sync_config.dart';
import 'package:mozhi/sync/models/sync_status.dart';
import 'package:translation_repository/translation_repository.dart'
    show PrivacyMode;

/// The account a sync folder is reached with: the WebDAV [server], the
/// [username] and its (app) [password], and the [folder] below [server].
class SyncConnection extends Equatable {
  const new({
    required this.server,
    required this.username,
    required this.password,
    this.folder = SyncConfig.defaultFolder,
  });

  final Uri server;
  final String username;
  final String password;
  final String folder;

  @override
  List<Object?> get props => [server, username, password, folder];

  // The password is left out.
  @override
  String toString() => 'SyncConnection($username)';
}

/// What the connection test found ([SyncService.probe]).
class SyncProbe extends Equatable {
  const new({
    required this.server,
    required this.folderExists,
    required this.file,
  });

  /// The WebDAV address that answered: the one given, or the Nextcloud and
  /// ownCloud address below it (`remote.php/dav/files/<user>/`) when only
  /// the server's address was given.
  final Uri server;

  /// Whether the folder exists already (it is created when sync is turned
  /// on).
  final bool folderExists;

  /// The sync file: [WebDavFile] when another device synced there
  /// already (setup then asks for that passphrase), [WebDavMissing]
  /// otherwise.
  final WebDavDownload file;

  /// Whether another device synced to this folder already.
  bool get hasSyncFile => file is WebDavFile;

  @override
  List<Object?> get props => [server, folderExists, file];
}

/// Sync as the app sees it: whether it is set up ([config]) and unlocked
/// (app password and key on this device), whether it runs now, and how
/// the last sync went ([status]).
class SyncState extends Equatable {
  const new({
    this.loaded = false,
    this.config,
    this.unlocked = false,
    this.running = false,
    this.status = const SyncStatus(),
  });

  /// Whether the stored setup has been read ([SyncService.load]).
  final bool loaded;

  /// Null: sync is off.
  final SyncConfig? config;

  /// Whether the app password and the key are on this device. The web app
  /// forgets both when its tab closes (secure storage there is the tab's
  /// session storage).
  final bool unlocked;
  final bool running;
  final SyncStatus status;

  bool get isSetUp => config != null;

  SyncState copyWith({
    bool? loaded,
    SyncConfig? Function()? config,
    bool? unlocked,
    bool? running,
    SyncStatus? status,
  }) => SyncState(
    loaded: loaded ?? this.loaded,
    config: config != null ? config() : this.config,
    unlocked: unlocked ?? this.unlocked,
    running: running ?? this.running,
    status: status ?? this.status,
  );

  @override
  List<Object?> get props => [loaded, config, unlocked, running, status];
}

/// End-to-end-encrypted sync of this device's data with the user's own
/// WebDAV folder (see [SyncEngine] for the protocol and docs/sync.md).
///
/// It runs
/// * on demand ([syncNow]),
/// * at app start ([start]), and
/// * [debounce] after a change in the app ([notifyChanged]; it asks the
///   server nothing when the synced data did not change), or sooner when
///   the app goes to the background with a change pending ([flush]),
///
/// and only while sync is set up and unlocked (after a change, not while
/// the last failure needs the user: [SyncFailure.needsUser]), never in
/// Offline only
/// (`privacyMode`), and automatically not over a metered network when the
/// user chose Wi-Fi only ([SyncConfig.wifiOnly]; `isMetered`, default
/// [MeteredNetwork.isMetered]). There is no background service: nothing
/// runs while the app is closed.
///
/// Every request goes through the session's client, listed as
/// [EgressPurpose.sync] in the network activity (`httpClient` replaces it
/// in tests), so the proxy and the network policy apply.
///
/// What it keeps: [SyncStore]. The passphrase is never stored: the key
/// derived from it is, in secure storage.
class SyncService {
  new({
    required BackupRegistry registry,
    required KeyValueStore prefs,
    required KeyValueStore secrets,
    BackupCodec codec = const BackupCodec(),
    http.Client Function()? httpClient,
    this._privacyMode,
    Future<bool> Function()? isMetered,
    DateTime Function()? clock,
    this.debounce = defaultDebounce,
  }) : _registry = registry,
       _codec = codec,
       _engine = SyncEngine(registry: registry, codec: codec),
       _store = SyncStore(prefs: prefs, secrets: secrets),
       _httpClient = httpClient ?? _sessionClient,
       _isMetered = isMetered ?? MeteredNetwork.instance.isMetered,
       _clock = clock ?? DateTime.now;

  /// How long after the last change an automatic sync waits.
  static const defaultDebounce = Duration(minutes: 1);

  final Duration debounce;
  final BackupRegistry _registry;
  final BackupCodec _codec;
  final SyncEngine _engine;
  final SyncStore _store;
  final http.Client Function() _httpClient;
  final PrivacyMode Function()? _privacyMode;
  final Future<bool> Function() _isMetered;
  final DateTime Function() _clock;

  final _states = StreamController<SyncState>.broadcast();
  SyncState _state = const SyncState();
  String? _password;
  BackupKey? _key;
  SyncCursor? _cursor;
  Timer? _timer;
  Future<void>? _loading;
  Future<void> _queue = Future.value();
  bool _closed = false;

  /// Bumped by [forget] and [turnOff]: runs that started before stop
  /// writing anything back.
  int _generation = 0;

  static http.Client _sessionClient() => EgressPurposeClient(
    NetworkSession.current.client,
    purpose: EgressPurpose.sync,
  );

  SyncState get state => _state;

  /// The ids of the sections this app can sync (the registry's), in order.
  List<String> get sectionIds => [
    for (final section in _registry.sections) section.id,
  ];
  Stream<SyncState> get states => _states.stream;

  /// Whether Offline only is on (nothing is synced then).
  bool get _offlineOnly => _privacyMode?.call() == PrivacyMode.offlineOnly;

  /// Reads the stored setup (once; later calls wait for the first).
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    final config = await _store.readConfig();
    final (status, cursor) = await _store.readState();
    if (config != null) {
      final (password, key) = await (
        _store.readPassword(),
        _store.readKey(),
      ).wait;
      _password = password;
      _key = key;
      _cursor = cursor;
    }
    _emit(
      SyncState(
        loaded: true,
        config: config,
        unlocked: config != null && _password != null && _key != null,
        status: status,
      ),
    );
  }

  /// At app start: loads the setup and syncs when sync may run by itself.
  Future<void> start() async {
    await load();
    await _automatic();
  }

  /// Something in the app changed: an automatic sync [debounce] later
  /// (restarted by every change), which asks the server nothing unless the
  /// synced data changed.
  void notifyChanged() {
    if (_closed || !_state.isSetUp) return;
    _timer?.cancel();
    _timer = Timer(debounce, () {
      _timer = null;
      unawaited(_automatic(onlyIfChanged: true));
    });
  }

  /// Whether a sync after a change is waiting for its [debounce].
  bool get hasPendingChange => _timer != null;

  /// Runs the sync waiting for its [debounce] now (the app goes to the
  /// background).
  Future<void> flush() async {
    if (_timer == null) return;
    _timer?.cancel();
    _timer = null;
    await _automatic(onlyIfChanged: true);
  }

  /// Syncs now, whatever the network (the user asked). Returns the failure,
  /// or null when it synced; [SyncFailure.offlineOnly] and
  /// [SyncFailure.needsUnlock] without a request.
  Future<SyncFailure?> syncNow() async {
    await load();
    if (!_state.isSetUp) return null;
    if (_offlineOnly) return SyncFailure.offlineOnly;
    if (!_state.unlocked) return SyncFailure.needsUnlock;
    _timer?.cancel();
    _timer = null;
    return await _serialized(_run);
  }

  Future<void> _automatic({bool onlyIfChanged = false}) async {
    if (_closed || !_state.isSetUp || !_state.unlocked || _offlineOnly) {
      return;
    }
    if (onlyIfChanged && (_state.status.lastFailure?.needsUser ?? false)) {
      return;
    }
    if (_state.config!.wifiOnly && await _isMetered()) return;
    await _serialized(() => _run(onlyIfChanged: onlyIfChanged));
  }

  /// One sync with the stored setup; records its outcome.
  Future<SyncFailure?> _run({bool onlyIfChanged = false}) async {
    final config = _state.config;
    final password = _password;
    final key = _key;
    if (config == null || password == null || key == null) {
      return config == null ? null : SyncFailure.needsUnlock;
    }
    final generation = _generation;
    _emit(_state.copyWith(running: true));
    final failure = await _attempt(
      () => _engine.run(
        dav: _dav(config.server, config.username, password, config.folder),
        key: key,
        config: config,
        cursor: _cursor,
        onlyIfChanged: onlyIfChanged,
        cancelled: () => generation != _generation,
      ),
      generation,
    );
    if (generation == _generation) _emit(_state.copyWith(running: false));
    return failure;
  }

  /// Runs [sync] and records its outcome (unless [forget] came in
  /// between: [generation]); returns its failure, or null.
  Future<SyncFailure?> _attempt(
    Future<SyncRun> Function() sync,
    int generation,
  ) async {
    final SyncRun run;
    try {
      run = await sync();
    } on Object catch (error) {
      // Anything but a SyncException is a bug in a section: this device's
      // data could not be read or written.
      final failure = error is SyncException
          ? error.failure
          : SyncFailure.localData;
      if (generation == _generation) await _record(failure: failure);
      return failure;
    }
    if (generation == _generation && !run.skipped) {
      _cursor = run.cursor;
      await _record(result: run.result);
    }
    return null;
  }

  Future<void> _record({SyncResult? result, SyncFailure? failure}) async {
    final now = _clock();
    final status = failure != null
        ? _state.status.failed(now, failure)
        : _state.status.succeeded(now, result ?? SyncResult.unchanged);
    _emit(_state.copyWith(status: status));
    try {
      await _store.writeState(status, _cursor);
    } on Object {
      // Kept in memory; written with the next sync.
    }
  }

  /// The connection test: whether [connection] reaches a WebDAV folder
  /// (or the place to create it) and whether another device synced there
  /// already. Nothing is created or stored. Throws a [SyncException].
  Future<SyncProbe> probe(SyncConnection connection) async {
    if (_offlineOnly) throw const SyncException(SyncFailure.offlineOnly);
    try {
      return await _probe(connection, connection.server);
    } on WebDavException catch (error) {
      final discovered = _nextcloudAddress(connection);
      // The server's own page answered (a web page, a redirect to the
      // login, a refusal): try where Nextcloud and ownCloud keep WebDAV.
      // Not when the server could not be reached at all.
      final reached = !const {
        WebDavFailure.offline,
        WebDavFailure.timeout,
        WebDavFailure.tls,
        WebDavFailure.blockedByBrowser,
        WebDavFailure.policy,
      }.contains(error.failure);
      if (discovered == null || !reached) {
        throw SyncException.fromWebDav(error);
      }
      try {
        return await _probe(connection, discovered);
      } on WebDavException {
        // The first answer explains more than the guess's.
        throw SyncException.fromWebDav(error);
      }
    }
  }

  Future<SyncProbe> _probe(SyncConnection connection, Uri server) async {
    final dav = _dav(
      server,
      connection.username,
      connection.password,
      connection.folder,
    );
    final folder = await dav.stat(dav.folder);
    if (folder == null) {
      // The folder will be created below the server's address, which must
      // exist.
      if (await dav.stat(WebDavClient.folderUrl(server, '')) == null) {
        throw const WebDavException(WebDavFailure.notFound, statusCode: 404);
      }
      return SyncProbe(
        server: server,
        folderExists: false,
        file: const WebDavMissing(),
      );
    }
    if (!folder.isCollection && folder.hasResourceType) {
      throw const WebDavException(WebDavFailure.notAFolder);
    }
    return SyncProbe(
      server: server,
      folderExists: true,
      file: await dav.download(SyncConfig.fileName),
    );
  }

  /// Nextcloud's and ownCloud's WebDAV address below [connection]'s server
  /// when it was given without a path (`https://cloud.example.org`), or
  /// null.
  static Uri? _nextcloudAddress(SyncConnection connection) {
    final server = connection.server;
    if (server.pathSegments.any((segment) => segment.isNotEmpty) ||
        connection.username.isEmpty) {
      return null;
    }
    return WebDavClient.folderUrl(server, '').replace(
      pathSegments: ['remote.php', 'dav', 'files', connection.username, ''],
    );
  }

  /// Turns sync on with [connection] (as [probe] found it: [probed]) and
  /// [passphrase], and syncs for the first time. With a sync file there
  /// already, [passphrase] must be the one it was made with
  /// ([SyncFailure.wrongPassphrase] otherwise); this device's data is then
  /// merged with it. Without one, it creates the file with a key derived
  /// from [passphrase]. Nothing is stored unless this first sync succeeds.
  /// Throws a [SyncException].
  Future<void> setUp({
    required SyncConnection connection,
    required String passphrase,
    required SyncConfig config,
    SyncProbe? probed,
  }) => _serialized(() async {
    if (_offlineOnly) throw const SyncException(SyncFailure.offlineOnly);
    await load();
    final generation = ++_generation;
    _timer?.cancel();
    _emit(_state.copyWith(running: true));
    try {
      final server = probed?.server ?? connection.server;
      final setup = config.copyWith(
        server: server,
        username: connection.username,
        folder: connection.folder,
      );
      final dav = _dav(
        server,
        connection.username,
        connection.password,
        connection.folder,
      );
      await _webDav(dav.ensureFolder);
      final (joined, typedKey, asTyped) = await _join(
        dav,
        setup,
        passphrase,
        probed?.file ?? await _webDav(() => dav.download(SyncConfig.fileName)),
        generation: generation,
      );
      if (generation != _generation) return;
      final (run, key) = asTyped
          ? await _toNfc(
              dav,
              setup,
              passphrase,
              typedKey,
              joined,
              generation: generation,
            )
          : (joined, typedKey);
      if (generation != _generation) return;
      await _save(setup, connection.password, key);
      _cursor = run.cursor;
      _emit(
        SyncState(
          loaded: true,
          config: setup,
          unlocked: true,
          running: true,
          status: const SyncStatus().succeeded(_clock(), run.result),
        ),
      );
      try {
        await _store.writeState(_state.status, _cursor);
      } on Object {
        // Kept in memory; written with the next sync.
      }
    } finally {
      if (generation == _generation) _emit(_state.copyWith(running: false));
    }
  });

  /// The first run with [passphrase] against [file]: with the file's
  /// salt and parameters when there is one, with a new key otherwise
  /// (and once more with the file's when another device created it in the
  /// meantime). The last value says whether the key is of the passphrase
  /// exactly as typed (a file made before passphrases were normalised; see
  /// [_toNfc]).
  Future<(SyncRun, BackupKey, bool)> _join(
    WebDavClient dav,
    SyncConfig config,
    String passphrase,
    WebDavDownload file, {
    required int generation,
  }) async {
    Future<SyncRun> first(BackupKey key, WebDavDownload file) =>
        _first(dav, config, key, file, generation: generation);
    if (file is WebDavFile) {
      final (:key, :asTyped) = await _keyFor(file.bytes, passphrase);
      return (await first(key, file), key, asTyped);
    }
    final key = await _codec.deriveKey(passphrase, salt: BackupCodec.newSalt());
    try {
      return (await first(key, file), key, false);
    } on SyncException catch (error) {
      if (error.failure != SyncFailure.wrongPassphrase) rethrow;
      // Another device created the file between the read and the write.
      final created = await _webDav(() => dav.download(SyncConfig.fileName));
      if (created is! WebDavFile) rethrow;
      final theirs = await _keyFor(created.bytes, passphrase);
      return (await first(theirs.key, created), theirs.key, theirs.asTyped);
    }
  }

  /// After [run] joined or unlocked the sync file with [typedKey], the key
  /// of [passphrase] exactly as typed (the file was made before passphrases
  /// were normalised): writes the file once more with a key of the
  /// passphrase in NFC and a new salt ([_rekey], as [changePassphrase]
  /// does), so that sync no longer depends on how the passphrase happens
  /// to be typed. Returns the run and the key to keep: the NFC key, or
  /// [typedKey] when that write failed (or sync was turned off meanwhile);
  /// the file is then left as it was and the next time the passphrase is
  /// entered tries again.
  ///
  /// Other devices then ask for the passphrase once
  /// ([SyncFailure.passphraseChanged]); this version unlocks with the NFC
  /// key first ([BackupCodec.unlockKeyOf]), so the same passphrase opens
  /// it however it is typed. A device on a version from before passphrases
  /// were normalised can't open it with a passphrase whose typed form isn't
  /// NFC: it needs the update.
  Future<(SyncRun, BackupKey)> _toNfc(
    WebDavClient dav,
    SyncConfig config,
    String passphrase,
    BackupKey typedKey,
    SyncRun run, {
    required int generation,
  }) async {
    try {
      final (rekeyed, key) = await _rekey(
        dav,
        config,
        typedKey,
        passphrase,
        cursor: run.cursor,
        generation: generation,
      );
      if (rekeyed.skipped) return (run, typedKey);
      // What the join brought in is what the user sees.
      return (
        SyncRun(result: run.result, cursor: rekeyed.cursor, report: run.report),
        key,
      );
    } on SyncException {
      return (run, typedKey);
    }
  }

  /// Writes the sync file (merged as in any run) with a key derived from
  /// [passphrase] in NFC with a new salt instead of [key]: the change-key
  /// path of [changePassphrase] and [_toNfc]. Throws a [SyncException].
  Future<(SyncRun, BackupKey)> _rekey(
    WebDavClient dav,
    SyncConfig config,
    BackupKey key,
    String passphrase, {
    required SyncCursor? cursor,
    required int generation,
  }) async {
    final newKey = await _codec.deriveKey(
      passphrase,
      salt: BackupCodec.newSalt(),
    );
    final run = await _engine.run(
      dav: dav,
      key: key,
      config: config,
      cursor: cursor,
      newKey: newKey,
      cancelled: () => generation != _generation,
    );
    return (run, newKey);
  }

  /// The first run: a file this device can't open with a key derived for
  /// it means another passphrase.
  Future<SyncRun> _first(
    WebDavClient dav,
    SyncConfig config,
    BackupKey key,
    WebDavDownload file, {
    required int generation,
  }) async {
    try {
      return await _engine.run(
        dav: dav,
        key: key,
        config: config,
        prefetched: file,
        cancelled: () => generation != _generation,
      );
    } on SyncException catch (error) {
      if (error.failure == SyncFailure.damaged ||
          error.failure == SyncFailure.passphraseChanged) {
        throw SyncException(SyncFailure.wrongPassphrase, cause: error);
      }
      rethrow;
    }
  }

  /// The key of [passphrase] for the sync file [bytes] (its salt and
  /// parameters): of the passphrase in NFC, or exactly as typed for a file
  /// made before passphrases were normalised ([BackupCodec.unlockKeyOf],
  /// which says so with `asTyped`).
  Future<({BackupKey key, bool asTyped})> _keyFor(
    Uint8List bytes,
    String passphrase,
  ) async {
    try {
      return await _codec.unlockKeyOf(bytes, passphrase);
    } on BackupFormatException catch (error) {
      throw SyncException(
        error.newerVersion ? SyncFailure.newerVersion : SyncFailure.notSyncFile,
      );
    }
  }

  /// Gives sync what it is missing on this device and syncs: the app
  /// [password] (the web app forgot it; it was changed on the server),
  /// and/or the [passphrase] (forgotten with the key, or changed on
  /// another device: the key is derived again from the sync file). Throws
  /// a [SyncException] ([SyncFailure.wrongPassphrase], ...); nothing is
  /// stored unless the sync succeeds.
  Future<void> unlock({String? password, String? passphrase}) =>
      _serialized(() async {
        await load();
        final config = _state.config;
        if (config == null) return;
        if (_offlineOnly) throw const SyncException(SyncFailure.offlineOnly);
        final usedPassword = password ?? _password;
        if (usedPassword == null) {
          throw const SyncException(SyncFailure.needsUnlock);
        }
        final generation = _generation;
        _emit(_state.copyWith(running: true));
        try {
          final dav = _dav(
            config.server,
            config.username,
            usedPassword,
            config.folder,
          );
          final SyncRun run;
          final BackupKey key;
          if (passphrase != null) {
            final file = await _webDav(() => dav.download(SyncConfig.fileName));
            final (joined, typedKey, asTyped) = await _join(
              dav,
              config,
              passphrase,
              file,
              generation: generation,
            );
            (run, key) = asTyped && generation == _generation
                ? await _toNfc(
                    dav,
                    config,
                    passphrase,
                    typedKey,
                    joined,
                    generation: generation,
                  )
                : (joined, typedKey);
          } else {
            key = _key ?? (throw const SyncException(SyncFailure.needsUnlock));
            run = await _engine.run(
              dav: dav,
              key: key,
              config: config,
              cursor: _cursor,
              cancelled: () => generation != _generation,
            );
          }
          if (generation != _generation) return;
          await _save(config, usedPassword, key);
          _cursor = run.cursor;
          _emit(_state.copyWith(unlocked: true));
          await _record(result: run.result);
        } on SyncException catch (error) {
          if (generation == _generation) await _record(failure: error.failure);
          rethrow;
        } finally {
          if (generation == _generation) {
            _emit(_state.copyWith(running: false));
          }
        }
      });

  /// Encrypts the sync file with a key derived from [passphrase] (a new
  /// salt) from now on: other devices then ask for it
  /// ([SyncFailure.passphraseChanged]). Throws a [SyncException].
  Future<void> changePassphrase(String passphrase) => _serialized(() async {
    final config = _state.config;
    final password = _password;
    final key = _key;
    if (config == null || password == null || key == null) {
      throw const SyncException(SyncFailure.needsUnlock);
    }
    if (_offlineOnly) throw const SyncException(SyncFailure.offlineOnly);
    final generation = _generation;
    _emit(_state.copyWith(running: true));
    try {
      final (run, newKey) = await _rekey(
        _dav(config.server, config.username, password, config.folder),
        config,
        key,
        passphrase,
        cursor: _cursor,
        generation: generation,
      );
      if (generation != _generation) return;
      await _save(config, password, newKey);
      _cursor = run.cursor;
      await _record(result: run.result);
    } on SyncException catch (error) {
      if (generation == _generation) await _record(failure: error.failure);
      rethrow;
    } finally {
      if (generation == _generation) _emit(_state.copyWith(running: false));
    }
  });

  /// Changes what is synced and when ([SyncConfig.excludedSections],
  /// [SyncConfig.includeSecrets], [SyncConfig.wifiOnly]); the server and
  /// account stay. Syncs afterwards when sync may run by itself.
  Future<void> updateOptions(SyncConfig config) async {
    final current = _state.config;
    if (current == null) return;
    final updated = current.copyWith(
      excludedSections: config.excludedSections,
      includeSecrets: config.includeSecrets,
      wifiOnly: config.wifiOnly,
    );
    try {
      await _store.writeConfig(updated);
    } on Object {
      // Used from now on; stored with the next change of the setup.
    }
    _emit(_state.copyWith(config: () => updated));
    notifyChanged();
  }

  /// Turns sync off on this device: forgets the setup, the app password
  /// and the key ([forget]). With [deleteRemote], first deletes the sync
  /// file on the server (other devices then stop finding data there and
  /// write it again with their next sync, unless they are turned off too);
  /// when that fails, nothing is forgotten and the [SyncException] is
  /// thrown.
  Future<void> turnOff({bool deleteRemote = false}) async {
    if (deleteRemote) {
      await _serialized(() async {
        final config = _state.config;
        final password = _password;
        if (config == null || password == null) {
          throw const SyncException(SyncFailure.needsUnlock);
        }
        if (_offlineOnly) throw const SyncException(SyncFailure.offlineOnly);
        await _webDav(
          () => _dav(
            config.server,
            config.username,
            password,
            config.folder,
          ).delete(SyncConfig.fileName),
        );
      });
    }
    await forget();
  }

  /// Forgets everything sync keeps on this device (setup, app password,
  /// key, last status) without contacting the server: Turn off, and
  /// Delete all local data. A sync running now is not written back.
  Future<void> forget() async {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _password = null;
    _key = null;
    _cursor = null;
    _emit(const SyncState(loaded: true));
    await _store.clear();
    // A sync merging into this device's data right now finishes that
    // first (it stops before the next step): what is deleted after this
    // returns stays deleted.
    await _queue.timeout(forgetWait, onTimeout: () {});
  }

  /// How long [forget] waits for a running sync to stop.
  static const forgetWait = Duration(seconds: 5);

  /// Stops the timer and the state stream.
  Future<void> dispose() async {
    _closed = true;
    _timer?.cancel();
    _timer = null;
    await _states.close();
  }

  Future<void> _save(SyncConfig config, String password, BackupKey key) async {
    try {
      await _store.writePassword(password);
      await _store.writeKey(key);
      await _store.writeConfig(config);
    } on Object catch (error) {
      throw SyncException(SyncFailure.localData, cause: error);
    }
    _password = password;
    _key = key;
  }

  WebDavClient _dav(
    Uri server,
    String username,
    String password,
    String folder,
  ) => WebDavClient(
    server: server,
    username: username,
    password: password,
    httpClient: _httpClient(),
    folderPath: folder,
    timeout: NetworkSession.current.hasProxy
        ? WebDavClient.defaultTimeout * 2
        : WebDavClient.defaultTimeout,
  );

  static Future<T> _webDav<T>(Future<T> Function() request) async {
    try {
      return await request();
    } on WebDavException catch (error, stackTrace) {
      Error.throwWithStackTrace(SyncException.fromWebDav(error), stackTrace);
    }
  }

  /// Runs [action] after the ones before it (one sync at a time).
  Future<T> _serialized<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  void _emit(SyncState state) {
    _state = state;
    if (!_states.isClosed) _states.add(state);
  }
}
