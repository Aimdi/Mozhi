// The web app's address in the browser's address bar.
// dart:js_interop exists only in a browser: elsewhere there is none.
import 'package:mozhi/platform/web_address_stub.dart'
    if (dart.library.js_interop) 'package:mozhi/platform/web_address_web.dart'
    as platform;

/// Removes the query from the web app's address ([address], default
/// `Uri.base`), keeping its path and the route after `#`: a link with text
/// to translate (`/?text=…#/translate`) is handled once, not again by every
/// reload (which would replace what the user typed since and save the same
/// translation in the history again). The browser's history keeps its
/// entry ([replace], default the browser's `history.replaceState`).
/// Nothing happens without a query.
void clearWebAddressQuery({
  Uri? address,
  void Function(String address)? replace,
}) {
  final next = addressWithoutQuery(address ?? Uri.base);
  if (next != null) (replace ?? platform.replaceWebAddress)(next);
}

/// [address] without its query, as an absolute path with the fragment
/// (still encoded); null when it has no query.
String? addressWithoutQuery(Uri address) {
  if (!address.hasQuery) return null;
  final path = address.path.isEmpty ? '/' : address.path;
  return address.hasFragment ? '$path#${address.fragment}' : path;
}

/// Removes the query of the route after `#` in the web app's address
/// ([address], default `Uri.base`): `/#/proofread?text=…` becomes
/// `/#/proofread` once the screen took the text, so that a reload does not
/// put it in again over what the user typed. Only the address changes
/// ([replace] as for [clearWebAddressQuery]); nothing happens without such
/// a query.
void clearWebRouteQuery({
  Uri? address,
  void Function(String address)? replace,
}) {
  final next = addressWithoutRouteQuery(address ?? Uri.base);
  if (next != null) (replace ?? platform.replaceWebAddress)(next);
}

/// [address] with the query of its fragment (the route) removed, as an
/// absolute path with its own query and the fragment (still encoded); null
/// when the fragment has no query.
String? addressWithoutRouteQuery(Uri address) {
  if (!address.hasFragment) return null;
  final fragment = address.fragment;
  final query = fragment.indexOf('?');
  if (query < 0) return null;
  final path = address.path.isEmpty ? '/' : address.path;
  final search = address.hasQuery ? '?${address.query}' : '';
  return '$path$search#${fragment.substring(0, query)}';
}
