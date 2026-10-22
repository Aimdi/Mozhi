// The app's pairing dependencies: the offline models and backups of the
// Android app (pairing_environment_of_io.dart); nothing in a browser,
// where phone to phone does not run.
export 'pairing_environment_of_web.dart'
    if (dart.library.io) 'pairing_environment_of_io.dart';
