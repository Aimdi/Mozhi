import 'dart:async';

import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';

/// Location of the web page translator. Register it as the `web` sub-route
/// of `/translate` (see the feature's integration notes).
abstract final class WebTranslateRoute {
  static const path = '/translate/web';

  /// Query parameter carrying the address to open.
  static const urlParameter = 'url';

  /// `/translate/web` or `/translate/web?url=…` (loads [url] on open).
  static String location({String? url}) => Uri(
    path: path,
    queryParameters: url == null || url.trim().isEmpty
        ? null
        : {urlParameter: url.trim()},
  ).toString();
}

/// App bar button that opens the web page translator.
class WebTranslateButton extends StatelessWidget {
  const new({this.url, super.key});

  /// Address to load right away, if any.
  final String? url;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: const Key('web_translate_open_page_button'),
      tooltip: context.l10n.webTranslateTitle,
      icon: const Icon(Icons.travel_explore),
      onPressed: () =>
          unawaited(context.push(WebTranslateRoute.location(url: url))),
    );
  }
}
