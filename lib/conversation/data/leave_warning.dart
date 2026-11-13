import 'package:mozhi/conversation/data/leave_warning_io.dart'
    if (dart.library.js_interop) 'package:mozhi/conversation/data/leave_warning_web.dart';

/// Turns the browser's "Leave site? Changes you made may not be saved"
/// question on or off: a conversation keeps its turns in memory only, so a
/// reload (or closing the tab) would lose them. Does nothing outside the
/// web app (Android keeps the app's state while it is in the background).
///
/// Tests replace it to see the calls.
void Function({required bool enabled}) setLeaveWarning =
    setPlatformLeaveWarning;
