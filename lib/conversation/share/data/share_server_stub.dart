// coverage:ignore-file

import 'package:mozhi/conversation/share/data/share_room.dart';
import 'package:mozhi/conversation/share/data/share_server.dart';

/// See `startShareServer` in `share_server.dart`: the web app cannot host.
Future<ShareServer> startShareServer({
  required String address,
  required ShareRoom room,
  required ShareStrings strings,
}) => Future.error(UnsupportedError('Sharing needs the Android app'));

/// See `shareServerSupported` in `share_server.dart`.
bool get shareServerSupported => false;
