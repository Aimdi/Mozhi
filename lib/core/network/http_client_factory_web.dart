import 'package:http/browser_client.dart';
import 'package:http/http.dart' as http;

/// The browser's `fetch` client; see `createHttpClient`. The proxy setting
/// does not apply in a browser.
http.Client createPlatformHttpClient({String? proxy}) => BrowserClient();
