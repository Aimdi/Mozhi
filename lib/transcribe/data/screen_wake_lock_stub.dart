/// The browser's screen wake lock: only in the web app.
class WebWakeLock {
  const new();

  Future<void> acquire() async {}

  Future<void> release() async {}
}
