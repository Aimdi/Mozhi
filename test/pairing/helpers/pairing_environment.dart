import 'dart:io';

import 'package:mozhi/pairing/data/pairing_environment.dart';
import 'package:mozhi/pairing/data/pairing_packs.dart';
import 'package:mozhi/pairing/data/pairing_session.dart';
import 'package:mozhi/pairing/protocol/pairing_connection.dart';

import 'loopback.dart';

/// A [PairingEnvironment] on loopback: the given addresses (127.0.0.1),
/// listeners and connections that allow loopback, files in [temp], and a
/// record of the screen being kept on ([screen]).
class TestPairingEnvironment {
  new(
    this.temp, {
    required PairingLibrary library,
    List<String> addresses = const ['127.0.0.1'],
    Duration codeValidity = const Duration(minutes: 1),
    PairingTimeouts timeouts = const PairingTimeouts(),
    Exception? bindError,
  }) {
    environment = PairingEnvironment(
      library: library,
      temporaryDirectory: () async => temp,
      addresses: () async => addresses,
      listen: (address, validity) async {
        if (bindError != null) throw bindError;
        final listener = await PairingListener.bind(
          address,
          validity: validity,
          policy: loopbackPolicy,
        );
        listeners.add(listener);
        return listener;
      },
      connect: (code) => connectPairing(code, policy: loopbackPolicy),
      keepScreenOn: ({required enabled}) async => screen.add(enabled),
      timeouts: timeouts,
      codeValidity: codeValidity,
    );
  }

  final Directory temp;
  late final PairingEnvironment environment;
  final listeners = <PairingListener>[];
  final screen = <bool>[];

  Future<void> dispose() async {
    for (final listener in listeners) {
      await listener.close();
    }
  }
}
