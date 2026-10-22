import 'package:material_ui/material_ui.dart';
import 'package:mozhi/pairing/data/pairing_environment.dart';
import 'package:mozhi/pairing/data/pairing_packs.dart';

/// No pairing in a browser: nothing to send or take, no storage.
PairingEnvironment pairingEnvironmentOf(BuildContext context) =>
    PairingEnvironment(
      library: PairingLibrary(),
      temporaryDirectory: () =>
          throw UnsupportedError('Phone to phone needs the Android app'),
    );

/// Nothing is stored in a browser.
Future<void> deletePairingFiles() async {}
