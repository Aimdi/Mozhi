import 'dart:io';
import 'dart:math';

import 'package:mozhi/pairing/data/pairing_packs.dart';
import 'package:mozhi/pairing/data/pairing_session.dart';
import 'package:mozhi/pairing/protocol/pairing_channel.dart';
import 'package:mozhi/pairing/protocol/pairing_code.dart';
import 'package:mozhi/pairing/protocol/pairing_connection.dart';
import 'package:mozhi/platform/lan_address.dart';

/// Starts listening on [address] for [validity] (see
/// [PairingListener.bind]).
typedef PairingListen = Future<PairingListener> Function(
  InternetAddress address,
  Duration validity,
);

/// Connects to the receiving phone of [code] (see [connectPairing]); stops
/// trying when [cancel] completes.
typedef PairingConnect = Future<PairingChannel> Function(
  PairingCode code, {
  Future<void>? cancel,
});

/// What the phone-to-phone screens work with; tests replace the network
/// and storage parts.
class PairingEnvironment {
  new({
    required this.library,
    required this._temporaryDirectory,
    Future<List<String>> Function()? addresses,
    PairingListen? listen,
    PairingConnect? connect,
    Future<void> Function({required bool enabled})? keepScreenOn,
    this.timeouts = const PairingTimeouts(),
    this.codeValidity = const Duration(minutes: 5),
    Random? random,
  }) : addresses = addresses ?? localNetworkAddresses,
       listen = listen ?? _listen,
       connect = connect ?? connectPairing,
       keepScreenOn = keepScreenOn ?? _noScreen,
       _random = random ?? Random();

  /// What this phone can send and take.
  final PairingLibrary library;

  /// This phone's private addresses, Wi-Fi first.
  final Future<List<String>> Function() addresses;

  final PairingListen listen;
  final PairingConnect connect;

  /// Keeps the screen on during a transfer (`ScreenAwake`).
  final Future<void> Function({required bool enabled}) keepScreenOn;

  final PairingTimeouts timeouts;

  /// How long a receiving phone's code works.
  final Duration codeValidity;

  final Future<Directory> Function() _temporaryDirectory;
  final Random _random;

  /// The folder for files of one transfer (`<temporary>/pairing/<n>`).
  /// Leftovers of earlier transfers (the app was closed during one) are
  /// removed first ([deleteFiles]).
  Future<Directory> workDirectory() async {
    final root = await deleteFiles(_temporaryDirectory);
    return Directory('${root.path}/${_random.nextInt(1 << 32)}');
  }

  /// Deletes `<temporary>/pairing` (what transfers left behind when the app
  /// was closed during one; a finished transfer removes its own files) and
  /// returns it. Never throws.
  static Future<Directory> deleteFiles(
    Future<Directory> Function() temporaryDirectory,
  ) async {
    final root = Directory('${(await temporaryDirectory()).path}/pairing');
    try {
      if (root.existsSync()) await root.delete(recursive: true);
    } on FileSystemException {
      // In use by a transfer of this run; it removes its own files.
    }
    return root;
  }

  static Future<PairingListener> _listen(
    InternetAddress address,
    Duration validity,
  ) => PairingListener.bind(address, validity: validity);

  static Future<void> _noScreen({required bool enabled}) async {}
}
