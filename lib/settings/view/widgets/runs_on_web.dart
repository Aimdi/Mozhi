import 'package:flutter/foundation.dart';

/// Overrides [runsOnWeb] in tests (null: the real platform).
@visibleForTesting
bool? debugRunsOnWeb;

/// Whether the app runs in a browser, where some settings do not apply
/// (e.g. the HTTP proxy: the browser makes the requests itself).
bool get runsOnWeb => debugRunsOnWeb ?? kIsWeb;
