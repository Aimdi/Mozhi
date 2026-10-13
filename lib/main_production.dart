import 'package:mozhi/app/app.dart';
import 'package:mozhi/bootstrap.dart';

Future<void> main() async {
  await bootstrap((dependencies) => App(dependencies: dependencies));
}
