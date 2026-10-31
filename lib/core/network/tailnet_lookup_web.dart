/// A browser cannot look names up: a Tailscale name stays public; see
/// `TailnetResolver`.
Future<List<String>> lookupAddresses(String host) async => const [];

/// A browser cannot see the device's interfaces: there is no Tailscale
/// interface, so nothing is looked up; see `TailnetResolver`.
Future<List<({String name, List<String> addresses})>> listInterfaces() async =>
    const [];
