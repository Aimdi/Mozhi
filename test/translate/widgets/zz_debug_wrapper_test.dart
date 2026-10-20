// TEMPORARY: records failures to the scratchpad (the test tool hides them).
// ignore_for_file: implementation_imports, depend_on_referenced_packages
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:test_api/src/backend/invoker.dart';

import 'language_bar_test.dart' as a;

const _out =
    '/tmp/claude-0/-home-user-Mozhi/071da89e-592f-547c-b32a-54fb03071e39/scratchpad/failures.txt';

void main() {
  tearDown(() {
    final live = Invoker.current!.liveTest;
    for (final error in live.errors) {
      File(_out).writeAsStringSync(
        '=== ${live.test.name}\n${error.error}\n${error.stackTrace}\n',
        mode: FileMode.append,
      );
    }
  });
  a.main();
}
