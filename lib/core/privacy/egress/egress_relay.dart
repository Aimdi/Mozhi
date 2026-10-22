import 'package:mozhi/core/privacy/egress/egress_ledger.dart';
import 'package:mozhi/core/privacy/egress/egress_relay_io.dart'
    if (dart.library.js_interop) 'package:mozhi/core/privacy/egress/egress_relay_web.dart'
    as platform;

/// Joins the network activity of the app's windows on Android: the quick
/// translate window (a translucent window over another app) runs its own
/// Flutter engine, so its requests are recorded in a ledger of their own.
/// It hands each finished entry ([forward]) to the main window's ledger
/// ([receive]) when that window runs in the same process. Only the entries
/// travel (no text: see `EgressEntry.toMap`), and only inside the app's
/// process (`IsolateNameServer`). A no-op in browsers.
abstract final class EgressRelay {
  /// The name the main window's port is registered under.
  static const portName = 'io.github.aimdi.mozhi/egress_ledger';

  /// Main window: adds the entries other windows send to [ledger] until
  /// the returned function is called.
  static void Function() receive(EgressLedger ledger) =>
      platform.receiveEgress(ledger, portName);

  /// Quick translate window: sends every finished entry of [ledger] to the
  /// main window (when it runs) until the returned function is called.
  static void Function() forward(EgressLedger ledger) =>
      platform.forwardEgress(ledger, portName);
}
