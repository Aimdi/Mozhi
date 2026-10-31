// A standalone reproduction of a dart2js miscompilation, to file with the
// Dart SDK (see README.md). It prints the same lines on the VM and when
// compiled to JavaScript, except that dart2js reports the successful
// action as failed.

// The output is the point of the program.
// ignore_for_file: avoid_print

/// Anything that leaves a value in a JavaScript temporary before the
/// `try` (here, `calls`): dart2js later reads that temporary instead of
/// `failure`.
List<Object> calls = [];

Future<void> attempt(Future<void> Function() action) async {
  calls.add(calls.length);
  // Nullable, assigned only in the `catch`, captured by the closure below.
  Object? failure;
  try {
    await action();
  } on Object catch (error) {
    failure = error;
  }
  // Expected after a successful action: true. dart2js: false.
  final succeeded = failure == null;
  print('succeeded: $succeeded, failure: ${(() => failure)()}');
}

/// The same without `async`: dart2js gets it wrong too.
void attemptSync(void Function() action) {
  calls.add(calls.length);
  Object? failure;
  try {
    action();
  } on Object catch (error) {
    failure = error;
  }
  final succeeded = failure == null;
  print('succeeded: $succeeded, failure: ${(() => failure)()}');
}

Future<void> main() async {
  print('A successful action:');
  await attempt(() async {});
  print('A failing action:');
  await attempt(() async => throw StateError('boom'));
  print('A successful action (sync):');
  attemptSync(() {});
  print('A failing action (sync):');
  attemptSync(() => throw StateError('boom'));
}
