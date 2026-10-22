import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/dart.dart';
import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/pairing/data/pairing_packs.dart';
import 'package:mozhi/pairing/models/pairing_item.dart';

/// Lower-case hex SHA-256 of [bytes].
String sha256Of(List<int> bytes) => [
  for (final byte in const DartSha256().hashSync(bytes).bytes)
    byte.toRadixString(16).padLeft(2, '0'),
].join();

/// Lower-case hex SHA-1 of [bytes].
String sha1Of(List<int> bytes) => [
  for (final byte in const DartSha1().hashSync(bytes).bytes)
    byte.toRadixString(16).padLeft(2, '0'),
].join();

/// [length] bytes of [seed].
Uint8List bytesOf(int length, [int seed = 1]) => Uint8List.fromList([
  for (var i = 0; i < length; i++) (i * seed + seed) & 0xff,
]);

/// Offline files of one [kind] in memory: [contents] by item key, then file
/// name. [plans] decides what the receiving side makes of an item
/// (default: it needs every offered file, with its SHA-256); [installs]
/// records what was installed (the bytes of each file).
class FakePacks implements PairingPacks {
  new({
    this.kind = PairingItemKind.translation,
    this.contents = const {},
    Map<String, PairingPlan>? plans,
    this.outcome = PairingItemOutcome.installed,
    this.failOutgoing = false,
  }) : plans = plans ?? {};

  @override
  final PairingItemKind kind;
  final Map<String, Map<String, List<int>>> contents;
  final Map<String, PairingPlan> plans;
  PairingItemOutcome outcome;
  final bool failOutgoing;
  final installs = <String, Map<String, List<int>>>{};

  /// The item [key] as the sender offers it.
  PairingItem item(String key) => PairingItem(
    kind: kind,
    key: key,
    files: [
      for (final MapEntry(key: name, value: bytes) in contents[key]!.entries)
        PairingFile(name: name, size: bytes.length, sha256: sha256Of(bytes)),
    ],
  );

  @override
  Future<List<PairingOutgoingItem>> outgoing() async {
    if (failOutgoing) throw const FileSystemException('unreadable');
    return [
      for (final MapEntry(:key, value: files) in contents.entries)
        PairingOutgoingItem(item(key), {
          for (final MapEntry(key: name, value: bytes) in files.entries)
            name: () => Stream.fromIterable([
              bytes.sublist(0, bytes.length ~/ 2),
              bytes.sublist(bytes.length ~/ 2),
            ]),
        }),
    ];
  }

  @override
  Future<PairingPlan> plan(PairingItem item) async =>
      plans[item.key] ?? PairingPlan.available(item.files);

  @override
  Future<PairingItemOutcome> install(PairingItem item, List<File> files) async {
    installs[item.key] = {
      for (final file in files)
        file.uri.pathSegments.last: await file.readAsBytes(),
    };
    return outcome;
  }
}

/// A backup section that keeps its data in memory and records restores.
class FakeSection implements BackupSection {
  new(this.id, this.data);

  @override
  final String id;

  Object? data;
  final restores = <(Object?, BackupRestoreMode)>[];

  @override
  int get version => 1;

  @override
  Future<Object?> export({required bool includeSecrets}) async =>
      includeSecrets ? {'value': data, 'secret': 'key'} : {'value': data};

  @override
  Future<void> restore(
    Object? data, {
    required int version,
    required BackupRestoreMode mode,
  }) async {
    restores.add((data, mode));
    this.data = data;
  }
}
