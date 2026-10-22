import 'dart:io';

/// Whether the device has no network connection: none of its network
/// interfaces has an address other than loopback and link-local ones
/// (airplane mode, Wi-Fi and mobile data off). Asks the operating system
/// only: nothing is sent. False when it can't tell.
Future<bool> deviceSeemsOffline() async {
  try {
    final interfaces = await NetworkInterface.list();
    return interfaces.every((interface) => interface.addresses.isEmpty);
  } on Object {
    return false;
  }
}
