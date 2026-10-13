@Timeout(Duration(seconds: 60))
library;

import 'dart:convert';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/presets/cubit/glossary_cubit.dart';
import 'package:mozhi/presets/cubit/presets_cubit.dart';
import 'package:mozhi/presets/data/glossary_repository.dart';
import 'package:mozhi/presets/models/glossary.dart';
import 'package:mozhi/presets/view/presets_providers.dart';

void main() {
  testWidgets('PresetsProviders provides loaded cubits', (tester) async {
    final store = MemoryStore({
      GlossaryRepository.storageKey: jsonEncode(
        GlossaryRepository.encode(const [Glossary(id: 'g', name: 'G')]),
      ),
    });
    late BuildContext captured;
    await tester.pumpWidget(
      PresetsProviders(
        store: store,
        child: Builder(
          builder: (context) {
            captured = context;
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pump();
    final presets = captured.read<PresetsCubit>();
    final glossaries = captured.read<GlossaryCubit>();
    expect(presets.state.status, PresetsStatus.ready);
    expect(presets.state.presets, hasLength(3));
    expect(glossaries.state.status, GlossaryStatus.ready);
    expect(glossaries.state.glossaries.single.name, 'G');
  });
}
