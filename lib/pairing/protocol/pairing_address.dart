import 'dart:io';

/// Which addresses pairing talks to: private IPv4 addresses only (10/8,
/// 172.16/12, 192.168/16, as Wi-Fi networks and phone hotspots hand out),
/// never the internet, carrier-grade NAT (100.64/10), link-local or IPv6
/// addresses. [allowLoopback] adds 127/8, for tests on one machine.
class PairingAddressPolicy {
  const new({this.allowLoopback = false});

  /// Whether this device's own loopback addresses are allowed (tests).
  final bool allowLoopback;

  /// Whether pairing may connect to or accept a connection from
  /// [address].
  bool allows(InternetAddress address) {
    if (address.type != InternetAddressType.IPv4) return false;
    final bytes = address.rawAddress;
    if (allowLoopback && bytes[0] == 127) return true;
    return isPrivateIPv4(bytes);
  }

  /// Whether the four bytes of [address] are a private IPv4 address.
  static bool isPrivateIPv4(List<int> address) =>
      address.length == 4 &&
      (address[0] == 10 ||
          (address[0] == 172 && address[1] >= 16 && address[1] < 32) ||
          (address[0] == 192 && address[1] == 168));
}
