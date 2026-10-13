import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/presets/cubit/glossary_cubit.dart';
import 'package:mozhi/presets/cubit/presets_cubit.dart';
import 'package:mozhi/presets/data/glossary_repository.dart';
import 'package:mozhi/presets/data/presets_repository.dart';

/// Provides an app-wide [PresetsCubit] and [GlossaryCubit] (both loaded
/// immediately) to [child]. Place it above `MaterialApp.router` so every
/// route, sheet and dialog can read them.
///
/// Data is stored in [store] (defaults to [PreferencesStore]) under
/// `presets.v1` and `glossaries.v1`. Pass repositories to override.
class PresetsProviders extends StatelessWidget {
  const PresetsProviders({
    required this.child,
    this.store,
    this.presetsRepository,
    this.glossaryRepository,
    super.key,
  });

  final Widget child;
  final KeyValueStore? store;
  final PresetsRepository? presetsRepository;
  final GlossaryRepository? glossaryRepository;

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(
          create: (_) {
            final cubit = PresetsCubit(
              repository: presetsRepository ?? PresetsRepository(store: store),
            );
            unawaited(cubit.load());
            return cubit;
          },
        ),
        BlocProvider(
          create: (_) {
            final cubit = GlossaryCubit(
              repository:
                  glossaryRepository ?? GlossaryRepository(store: store),
            );
            unawaited(cubit.load());
            return cubit;
          },
        ),
      ],
      child: child,
    );
  }
}
