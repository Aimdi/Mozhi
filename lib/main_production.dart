import 'package:mozhi/app/app.dart';
import 'package:mozhi/app_lock/data/app_lock_windows.dart';
import 'package:mozhi/bootstrap.dart';

/// [args]: the window the Android activity runs this engine in
/// (`MainActivity.getDartEntrypointArgs`), for the app lock.
Future<void> main(List<String> args) async {
  AppLockWindow.declare(args);
  await bootstrap((dependencies) => App(dependencies: dependencies));
}
