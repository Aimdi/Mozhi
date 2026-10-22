// The phone-to-phone screens, loaded when first opened (the router imports
// this library deferred).
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/pairing/cubit/pairing_send_cubit.dart';
import 'package:mozhi/pairing/pairing_routes.dart';
import 'package:mozhi/pairing/view/pairing_send_page.dart';

export 'pairing_entries.dart' show PairingPage;
export 'pairing_receive_page.dart' show PairingReceivePage;
export 'pairing_send_page.dart' show PairingSendPage;

/// **Send to another phone** for the location [uri] (see
/// [PairingRoutes.send]): its code filled in, the language packs selected
/// for `?what=packs`.
Widget pairingSendPageFor(Uri uri) {
  final query = uri.queryParameters;
  final code = query[PairingRoutes.codeParameter];
  return PairingSendPage(
    // Another code (another link while the page is open) starts afresh.
    key: ValueKey(code),
    initialCode: code,
    purpose: query[PairingRoutes.purposeParameter] == PairingRoutes.packsPurpose
        ? PairingSendPurpose.packs
        : PairingSendPurpose.everything,
  );
}
