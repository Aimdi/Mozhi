import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/presets/cubit/presets_cubit.dart';
import 'package:mozhi/presets/models/preset.dart';
import 'package:mozhi/presets/view/presets_page.dart';

import '../helpers.dart';

const _chat = 'Chat with friends (casual)';
const _simple = 'Simple (A2 reading level)';

void trace(String s) => File('/tmp/claude-0/-home-user-Mozhi/071da89e-592f-547c-b32a-54fb03071e39/scratchpad/presets_agent_x7/trace.log').writeAsStringSync('$s\n', mode: FileMode.append);

void main() {
  group('PresetsPage', () {
    late PresetsHarness harness;

    setUp(() { trace('setUp'); harness = PresetsHarness(); });
    tearDown(() async { trace('tearDown'); await harness.close(); trace('closed'); });

    PresetsState state() => harness.presets.state;

    testWidgets('deletes', (tester) async {
      trace('start');
      await harness.presets.load();
      trace('loaded');
      await harness.pump(tester, const PresetsPage());
      trace('pumped');
      await settle(tester);
      trace('settled');
      await harness.presets.setDefault('builtin-chatCasual');
      trace('default');
      await settle(tester);
      await tester.tap(find.byTooltip('Actions for $_chat'));
      await settle(tester);
      trace('menu');
      await tester.tap(find.text('Delete'));
      await settle(tester);
      trace('deleted');
      expect(find.text(_chat), findsNothing);
      expect(state().presets, hasLength(2));
      expect(state().defaultId, isNull);
      expect(find.text('Deleted “$_chat”'), findsOneWidget);
      trace('expect1');
      await tester.tap(find.text('Undo'));
      await settle(tester);
      trace('undo');
      expect(find.text(_chat), findsOneWidget);
      expect(state().presets[1].builtIn, BuiltInPreset.chatCasual);
      expect(state().defaultId, 'builtin-chatCasual');
      trace('expect2');
      await tester.drag(find.text(_simple), const Offset(-600, 0));
      await settle(tester);
      trace('dragged');
      expect(find.text(_simple), findsNothing);
      expect(state().presets, hasLength(2));
      trace('done');
    });
  });
}
