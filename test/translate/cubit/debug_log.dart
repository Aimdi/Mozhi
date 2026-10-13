// TEMP debug helper (removed before finishing).
// ignore_for_file: implementation_imports, depend_on_referenced_packages
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:test_api/src/backend/invoker.dart';

void logFailures() {
  tearDown(() {
    final live = Invoker.current!.liveTest;
    if (live.errors.isEmpty) return;
    File(
      '/tmp/claude-0/-home-user-Mozhi/071da89e-592f-547c-b32a-54fb03071e39/scratchpad/failures.log',
    ).writeAsStringSync(
      '=== ${live.test.name}\n'
      '${live.errors.map((e) => '${e.error}\n${e.stackTrace}').join('\n')}\n',
      mode: FileMode.append,
    );
  });
}
