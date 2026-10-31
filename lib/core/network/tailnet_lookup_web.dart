/// A browser cannot look names up: a Tailscale name stays public; see
/// `TailnetResolver`.
Future<List<String>> lookupAddresses(String host) async => const [];
