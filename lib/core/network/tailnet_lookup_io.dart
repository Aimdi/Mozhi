import 'dart:io';

/// The addresses of [host] from the system's resolver; see
/// `TailnetResolver`.
Future<List<String>> lookupAddresses(String host) async => [
  for (final address in await InternetAddress.lookup(host)) address.address,
];

/// The device's network interfaces ([NetworkInterface.list]) with their
/// addresses; see `TailnetResolver`.
Future<List<({String name, List<String> addresses})>> listInterfaces() async =>
    [
      for (final interface in await NetworkInterface.list())
        (
          name: interface.name,
          addresses: [
            for (final address in interface.addresses) address.address,
          ],
        ),
    ];
