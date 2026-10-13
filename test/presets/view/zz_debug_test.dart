import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/presets/view/presets_page.dart';

import '../helpers.dart';

const _chat = 'Chat with friends (casual)';
const _simple = 'Simple (A2 reading level)';

void main() {
  testWidgets('debug delete', (tester) async {
    final harness = PresetsHarness();
    addTearDown(harness.close);
    Future<void> settle(String step) async {
      // ignore: avoid_print
      print('step: $step');
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 5),
      );
    }

    await harness.presets.load();
    await harness.pump(tester, const PresetsPage());
    await settle('pumped');
    await harness.presets.setDefault('builtin-chatCasual');
    await settle('default');
    await tester.tap(find.byTooltip('Actions for $_chat'));
    await settle('menu');
    await tester.tap(find.text('Delete'));
    await settle('deleted');
    await tester.tap(find.text('Undo'));
    await settle('undo');
    await tester.drag(find.text(_simple), const Offset(-600, 0));
    await settle('dragged');
  });
}
