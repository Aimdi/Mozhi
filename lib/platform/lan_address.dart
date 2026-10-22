import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:mozhi/platform/lan_address_stub.dart'
    if (dart.library.io) 'package:mozhi/platform/lan_address_io.dart'
    as impl;

/// A network interface: its name (`wlan0`, `ap0`, `rmnet0`...) and IPv4
/// addresses in dotted form.
typedef LanInterface = ({String name, List<String> addresses});

/// The device's private IPv4 addresses on a local network (10/8,
/// 172.16/12, 192.168/16), Wi-Fi first, then the hotspot, Ethernet and the
/// rest; empty on the web, without a network, and on errors.
///
/// Not loopback, link-local or carrier-grade NAT (100.64/10, which is also
/// where Tailscale lives), and not interfaces that never face the local
/// network even when their address is private: mobile data (`rmnet`,
/// `ccmni`), VPNs and tunnels (`tun`, `wg`, `ppp`, `ipsec`, `tailscale`)
/// and 464XLAT (`clat`, `v4-`). Guests on the same Wi-Fi can reach what
/// is left. Never throws.
Future<List<String>> localNetworkAddresses() async {
  try {
    return rankLanAddresses(await (debugLanInterfaces ?? impl.lanInterfaces)());
  } on Object {
    return const [];
  }
}

/// Replaces the platform's interface list in tests.
@visibleForTesting
Future<List<LanInterface>> Function()? debugLanInterfaces;

/// The private addresses of [interfaces], best first (see
/// [localNetworkAddresses]), without duplicates.
@visibleForTesting
List<String> rankLanAddresses(List<LanInterface> interfaces) {
  final ranked = <(int, int, String)>[];
  for (final (index, interface) in interfaces.indexed) {
    final rank = _interfaceRank(interface.name);
    if (rank == null) continue;
    for (final address in interface.addresses) {
      if (isPrivateIPv4(address)) ranked.add((rank, index, address));
    }
  }
  ranked.sort((a, b) {
    final byRank = a.$1.compareTo(b.$1);
    return byRank != 0 ? byRank : a.$2.compareTo(b.$2);
  });
  return [
    for (final address in {for (final (_, _, address) in ranked) address})
      address,
  ];
}

/// Lower is better; null for interfaces that never face the local network.
int? _interfaceRank(String name) {
  final lower = name.toLowerCase();
  bool starts(List<String> prefixes) => prefixes.any(lower.startsWith);
  if (starts(const [
    'lo',
    'rmnet',
    'ccmni',
    'tun',
    'wg',
    'ppp',
    'ipsec',
    'tailscale',
    'utun',
    'clat',
    'v4-',
    'dummy',
    'p2p',
  ])) {
    return null;
  }
  // The Wi-Fi the phone has joined (wlan0); hotspot interfaces are often
  // a second wlan (wlan1, swlan0) or ap0/softap0.
  if (lower == 'wlan0' || lower.startsWith('wifi')) return 0;
  if (starts(const ['wlan', 'swlan', 'ap', 'softap', 'wigig'])) return 1;
  if (starts(const ['eth', 'en', 'usb', 'rndis', 'bt-pan'])) return 2;
  return 3;
}

/// Whether [address] is a dotted IPv4 address in 10.0.0.0/8,
/// 172.16.0.0/12 or 192.168.0.0/16 (RFC 1918).
bool isPrivateIPv4(String address) {
  final parts = address.split('.');
  if (parts.length != 4) return false;
  final octets = <int>[];
  for (final part in parts) {
    final value = int.tryParse(part);
    if (value == null || value < 0 || value > 255 || part.length > 3) {
      return false;
    }
    octets.add(value);
  }
  return switch (octets) {
    [10, _, _, _] => true,
    [172, final b, _, _] => b >= 16 && b <= 31,
    [192, 168, _, _] => true,
    _ => false,
  };
}
