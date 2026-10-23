import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/dart.dart';
import 'package:equatable/equatable.dart';
import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/pairing/data/pairing_packs.dart';
import 'package:mozhi/pairing/models/pairing_item.dart';
import 'package:mozhi/pairing/protocol/pairing_channel.dart';
import 'package:mozhi/pairing/protocol/pairing_exception.dart';

/// How long one phone waits for the other.
class PairingTimeouts {
  const new({
    this.decision = const Duration(minutes: 10),
    this.transfer = const Duration(seconds: 30),
    this.install = const Duration(minutes: 10),
  });

  /// For a person on the other phone to choose what to send, or to accept.
  final Duration decision;

  /// Between two frames while files go across.
  final Duration transfer;

  /// For the other phone to check and install an item.
  final Duration install;
}

/// How far a transfer is: [bytes] of [totalBytes], in the item [itemId];
/// [installing] while the receiving phone installs it.
class PairingProgress extends Equatable {
  const new({
    required this.bytes,
    required this.totalBytes,
    this.itemId,
    this.installing = false,
  });

  final int bytes;
  final int totalBytes;
  final String? itemId;
  final bool installing;

  /// 0 to 1.
  double get fraction =>
      totalBytes == 0 ? 1 : (bytes / totalBytes).clamp(0, 1).toDouble();

  @override
  List<Object?> get props => [bytes, totalBytes, itemId, installing];
}

/// An offered item the receiving phone asked for, with the [files] it
/// wants.
class PairingRequestedItem {
  const new(this.outgoing, this.files);

  final PairingOutgoingItem outgoing;
  final List<PairingFile> files;

  PairingItem get item => outgoing.item;
}

/// An item of the offer, with what the receiving phone makes of it.
class PairingOfferedItem extends Equatable {
  const new(this.item, this.plan);

  final PairingItem item;
  final PairingPlan plan;

  @override
  List<Object?> get props => [item, plan];
}

/// The sending phone's side of a transfer (docs/pairing.md): [offer]
/// what the user chose, then [send] what the other phone asked for.
class PairingSender {
  new(this._channel, {this.timeouts = const PairingTimeouts()});

  final PairingChannel _channel;
  final PairingTimeouts timeouts;

  /// The short authentication string of the connection.
  String get sas => _channel.sas;

  /// Offers [items] and waits for the answer: the items and files the
  /// other phone wants (possibly none). Throws [PairingDeclinedException]
  /// when it said no (the connection is then closed), and
  /// [PairingProtocolException] when it asked for anything not offered.
  Future<List<PairingRequestedItem>> offer(
    List<PairingOutgoingItem> items,
  ) async {
    final offered = {for (final outgoing in items) outgoing.item.id: outgoing};
    await _channel.send('offer', {
      'items': [for (final outgoing in items) outgoing.item.toJson()],
    });
    final answer = await _channel.receiveMessage(
      timeout: timeouts.decision,
      expected: const {'accept', 'decline'},
    );
    if (answer.type == 'decline') {
      await _channel.close();
      throw const PairingDeclinedException();
    }
    final wanted = answer.fields['items'];
    if (wanted is! List<Object?>) {
      throw const PairingProtocolException('Invalid answer');
    }
    final requested = <PairingRequestedItem>[];
    final ids = <String>{};
    for (final entry in wanted) {
      final (id, names) = switch (entry) {
        {'id': final String id, 'files': final List<Object?> names} => (
          id,
          names,
        ),
        _ => throw const PairingProtocolException('Invalid answer'),
      };
      final outgoing = offered[id];
      if (outgoing == null || !ids.add(id)) {
        throw PairingProtocolException('Not offered: $id');
      }
      final files = <PairingFile>[];
      for (final name in names) {
        final file = name is String ? outgoing.item.file(name) : null;
        if (file == null || files.contains(file)) {
          throw PairingProtocolException('Not offered: $id/$name');
        }
        files.add(file);
      }
      if (files.isNotEmpty) {
        requested.add(PairingRequestedItem(outgoing, files));
      }
    }
    return requested;
  }

  /// Sends the files of [requested], item by item, waiting after each
  /// item for the other phone to install it; returns what became of each.
  /// [onProgress] follows the bytes sent.
  Future<List<PairingItemResult>> send(
    List<PairingRequestedItem> requested, {
    void Function(PairingProgress progress)? onProgress,
  }) async {
    final total = requested.fold(
      0,
      (sum, item) => sum + item.files.fold(0, (sum, file) => sum + file.size),
    );
    var sent = 0;
    final results = <PairingItemResult>[];
    for (final request in requested) {
      final id = request.item.id;
      for (final file in request.files) {
        await _channel.send('file', {
          'item': id,
          'name': file.name,
          'size': file.size,
        });
        var bytes = 0;
        await for (final chunk in _chunks(
          request.outgoing.readers[file.name]!,
        )) {
          bytes += chunk.length;
          if (bytes > file.size) break;
          await _channel.sendData(chunk);
          sent += chunk.length;
          onProgress?.call(
            PairingProgress(bytes: sent, totalBytes: total, itemId: id),
          );
        }
        if (bytes != file.size) {
          // The file changed since it was offered: the other phone could
          // not tell where it ends, so the transfer stops.
          await _channel.cancel('changed');
          throw const PairingProtocolException('A file changed');
        }
      }
      onProgress?.call(
        PairingProgress(
          bytes: sent,
          totalBytes: total,
          itemId: id,
          installing: true,
        ),
      );
      final result = await _channel.receiveMessage(
        timeout: timeouts.install,
        expected: const {'result'},
      );
      final outcome = PairingItemOutcome.tryParse(result.fields['status']);
      if (result.fields['item'] != id || outcome == null) {
        throw const PairingProtocolException('Invalid result');
      }
      results.add(PairingItemResult(id, outcome));
    }
    await _channel.send('done');
    await _channel.receiveMessage(
      timeout: timeouts.transfer,
      expected: const {'done'},
    );
    await _channel.close();
    return results;
  }

  /// Stops the transfer and tells the other phone.
  Future<void> cancel() => _channel.cancel();

  /// Closes the connection.
  Future<void> close() => _channel.close();

  /// [read]'s bytes in chunks that fit a frame.
  static Stream<List<int>> _chunks(PairingFileReader read) async* {
    await for (final chunk in read()) {
      for (var start = 0; start < chunk.length; start += _chunkSize) {
        final end = start + _chunkSize < chunk.length
            ? start + _chunkSize
            : chunk.length;
        yield start == 0 && end == chunk.length
            ? chunk
            : chunk.sublist(start, end);
      }
    }
  }

  /// Bytes of file data per frame.
  static const int _chunkSize = 64 * 1024;
}

/// The receiving phone's side of a transfer (docs/pairing.md): [offer]
/// waits for what the other phone offers and plans each item with the
/// [PairingLibrary]; then [decline] or [accept].
///
/// Offline files are written into [workDirectory] (which it creates and
/// removes) while their size and hashes are checked against this phone's
/// plan; a file that does not match fails its item
/// ([PairingItemOutcome.damaged]) and nothing of the item is installed.
/// The data item (at most [PairingBackupItem.maxSize]) stays in memory and
/// is never written to storage.
class PairingReceiver {
  new(
    this._channel,
    this._library, {
    required this.workDirectory,
    this.timeouts = const PairingTimeouts(),
  });

  /// Most items an offer may have.
  static const maxItems = 1000;

  final PairingChannel _channel;
  final PairingLibrary _library;
  final Directory workDirectory;
  final PairingTimeouts timeouts;
  List<PairingOfferedItem> _offered = const [];

  /// The short authentication string of the connection.
  String get sas => _channel.sas;

  /// Waits for the other phone's offer and plans each item.
  Future<List<PairingOfferedItem>> offer() async {
    final message = await _channel.receiveMessage(
      timeout: timeouts.decision,
      expected: const {'offer'},
    );
    final items = message.fields['items'];
    if (items is! List<Object?> || items.length > maxItems) {
      throw const PairingProtocolException('Invalid offer');
    }
    final parsed = [
      for (final item in items)
        // Kinds of a newer Mozhi are left out, so the rest still moves.
        if (!_newerKind(item)) PairingItem.fromJson(item),
    ];
    if ({for (final item in parsed) item.id}.length != parsed.length) {
      throw const PairingProtocolException('Duplicate item');
    }
    return _offered = [
      for (final item in parsed)
        PairingOfferedItem(item, await _library.plan(item)),
    ];
  }

  /// Whether [item] names a kind this version doesn't know (a string that
  /// isn't a [PairingItemKind]); any other invalid item stays an error.
  static bool _newerKind(Object? item) =>
      item is Map<String, Object?> &&
      item['kind'] is String &&
      PairingItemKind.tryParse(item['kind']) == null;

  /// Says no to the offer and closes the connection.
  Future<void> decline() async {
    await _channel.send('decline');
    await _channel.close();
  }

  /// Asks for the items [ids] of the offer (those that are
  /// [PairingItemStatus.available]), receives and installs them (a data
  /// item restored with [mode]) and returns what became of each.
  /// [onProgress] follows the bytes received.
  Future<List<PairingItemResult>> accept(
    Set<String> ids, {
    required BackupRestoreMode mode,
    void Function(PairingProgress progress)? onProgress,
  }) async {
    final accepted = [
      for (final offered in _offered)
        if (ids.contains(offered.item.id) &&
            offered.plan.status == PairingItemStatus.available &&
            offered.plan.files.isNotEmpty)
          offered,
    ];
    await _channel.send('accept', {
      'items': [
        for (final offered in accepted)
          {
            'id': offered.item.id,
            'files': [for (final file in offered.plan.files) file.name],
          },
      ],
    });
    final total = accepted.fold(0, (sum, offered) => sum + offered.plan.size);
    var received = 0;
    final results = <PairingItemResult>[];
    await workDirectory.create(recursive: true);
    try {
      for (final (index, offered) in accepted.indexed) {
        final id = offered.item.id;
        final folder = Directory('${workDirectory.path}/$index');
        final files = <File>[];
        // The data (a backup, with secrets when included) is kept in
        // memory rather than in the cache folder.
        final data = offered.item.kind == PairingItemKind.data
            ? BytesBuilder(copy: false)
            : null;
        PairingItemOutcome? outcome;
        for (final expected in offered.plan.files) {
          final header = await _channel.receiveMessage(
            timeout: timeouts.transfer,
            expected: const {'file'},
          );
          if (header.fields['item'] != id ||
              header.fields['name'] != expected.name ||
              header.fields['size'] != expected.size) {
            throw const PairingProtocolException('Unexpected file');
          }
          final file = data == null
              ? File('${folder.path}/${expected.name}')
              : null;
          if (file != null) files.add(file);
          final failure = await _receiveFile(
            expected,
            file: outcome == null ? file : null,
            memory: outcome == null ? data : null,
            onBytes: (bytes) {
              received += bytes;
              onProgress?.call(
                PairingProgress(bytes: received, totalBytes: total, itemId: id),
              );
            },
          );
          outcome ??= failure;
        }
        if (outcome == null) {
          onProgress?.call(
            PairingProgress(
              bytes: received,
              totalBytes: total,
              itemId: id,
              installing: true,
            ),
          );
          outcome = data == null
              ? await _library.install(offered.item, files, mode: mode)
              : await _library.restore(
                  offered.item,
                  data.takeBytes(),
                  mode: mode,
                );
        }
        await _deleteQuietly(folder);
        await _channel.send('result', {'item': id, 'status': outcome.name});
        results.add(PairingItemResult(id, outcome));
      }
      await _channel.receiveMessage(
        timeout: timeouts.transfer,
        expected: const {'done'},
      );
      await _channel.send('done');
      await _channel.close();
      return results;
    } finally {
      await _deleteQuietly(workDirectory);
    }
  }

  /// Stops the transfer and tells the other phone.
  Future<void> cancel() => _channel.cancel();

  /// Closes the connection.
  Future<void> close() => _channel.close();

  /// Receives the data of [expected] into [file] or [memory] (or discards
  /// it with neither: its item failed already), checking its size and
  /// hashes. Null when it matched; else why the item fails.
  Future<PairingItemOutcome?> _receiveFile(
    PairingFile expected, {
    required void Function(int bytes) onBytes,
    File? file,
    BytesBuilder? memory,
  }) async {
    final sha256 = expected.sha256 == null
        ? null
        : const DartSha256().newHashSink();
    final sha1 = expected.sha1 == null ? null : const DartSha1().newHashSink();
    // Plans name their files after this phone's catalogue; anything else
    // is never written.
    var failure = PairingFile.isValidName(expected.name)
        ? null
        : PairingItemOutcome.failed;
    RandomAccessFile? output;
    if (file != null && failure == null) {
      try {
        await file.parent.create(recursive: true);
        output = await file.open(mode: FileMode.write);
      } on FileSystemException catch (error) {
        failure = isNoSpace(error)
            ? PairingItemOutcome.noSpace
            : PairingItemOutcome.failed;
      }
    }
    try {
      var received = 0;
      while (received < expected.size) {
        final frame = await _channel.receive(timeout: timeouts.transfer);
        final Uint8List bytes;
        switch (frame) {
          case PairingData(bytes: final data):
            bytes = data;
          case PairingMessage(type: 'cancel'):
            throw const PairingCancelledException();
          case PairingMessage():
            throw const PairingProtocolException('Expected file data');
        }
        received += bytes.length;
        if (received > expected.size) {
          throw const PairingProtocolException('File longer than announced');
        }
        sha256?.add(bytes);
        sha1?.add(bytes);
        if (failure == null) memory?.add(bytes);
        if (output != null && failure == null) {
          try {
            await output.writeFrom(bytes);
          } on FileSystemException catch (error) {
            failure = isNoSpace(error)
                ? PairingItemOutcome.noSpace
                : PairingItemOutcome.failed;
          }
        }
        onBytes(bytes.length);
      }
    } finally {
      try {
        await output?.close();
      } on FileSystemException {
        failure ??= PairingItemOutcome.failed;
      }
    }
    if (failure != null) return failure;
    if (sha256 != null && _hex(sha256) != expected.sha256) {
      return PairingItemOutcome.damaged;
    }
    if (sha1 != null && _hex(sha1) != expected.sha1) {
      return PairingItemOutcome.damaged;
    }
    return null;
  }

  static String _hex(DartHashSink sink) {
    sink.close();
    final buffer = StringBuffer();
    for (final byte in sink.hashSync().bytes) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  static Future<void> _deleteQuietly(Directory directory) async {
    try {
      if (directory.existsSync()) await directory.delete(recursive: true);
    } on FileSystemException {
      // Left for the next transfer's clean-up.
    }
  }
}
