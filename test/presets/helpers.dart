import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/presets/cubit/glossary_cubit.dart';
import 'package:mozhi/presets/cubit/presets_cubit.dart';
import 'package:mozhi/presets/data/glossary_repository.dart';
import 'package:mozhi/presets/data/presets_repository.dart';
import 'package:mozhi/presets/widgets/presets_share.dart';

import '../helpers/helpers.dart';

/// `pumpAndSettle` that fails after 10 s instead of hanging for minutes.
Future<void> settle(WidgetTester tester) => tester.pumpAndSettle(
  const Duration(milliseconds: 100),
  EnginePhase.sendSemanticsUpdate,
  const Duration(seconds: 10),
);

/// Real cubits backed by in-memory stores with predictable ids.
class PresetsHarness {
  PresetsHarness({MemoryStore? store}) : store = store ?? MemoryStore() {
    presets = PresetsCubit(
      repository: PresetsRepository(
        store: this.store,
        generateId: () => 'p${_ids++}',
      ),
    );
    glossaries = GlossaryCubit(
      repository: GlossaryRepository(
        store: this.store,
        generateId: () => 'g${_ids++}',
      ),
    );
  }

  final MemoryStore store;
  late final PresetsCubit presets;
  late final GlossaryCubit glossaries;
  int _ids = 0;

  /// Text shared through [PresetsShare] (file name -> text).
  final Map<String, String> shared = {};

  /// Text written to the clipboard (last value).
  String? clipboard;

  Future<void> close() async {
    await presets.close();
    await glossaries.close();
  }

  /// Pumps [child] with both cubits provided, a stubbed share sheet and a
  /// fake clipboard. [size] sets the logical screen size.
  Future<void> pump(WidgetTester tester, Widget child, {Size? size}) async {
    if (size != null) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }
    PresetsShare.share = (text, {required fileName, required mimeType}) async {
      shared[fileName] = text;
    };
    addTearDown(PresetsShare.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        switch (call.method) {
          case 'Clipboard.setData':
            clipboard = (call.arguments as Map)['text'] as String?;
            return null;
          case 'Clipboard.getData':
            return clipboard == null ? null : {'text': clipboard};
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpApp(
      MultiBlocProvider(
        providers: [
          BlocProvider.value(value: presets),
          BlocProvider.value(value: glossaries),
        ],
        child: child,
      ),
    );
  }
}
