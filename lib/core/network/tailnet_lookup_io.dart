import 'dart:io';

/// The addresses of [host] from the system's resolver; see
/// `TailnetResolver`.
Future<List<String>> lookupAddresses(String host) async => [
  for (final address in await InternetAddress.lookup(host)) address.address,
];
