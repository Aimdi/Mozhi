import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/core/widgets/composer_card.dart';
import 'package:mozhi/proofread/cubit/proofread_cubit.dart';

/// The AI model that proofreads, as a chip for the app bar
/// ([ComposerEngineChip]): its menu is the options sheet's model choice
/// ([ProofreadCubit.setEngine], kept while the page lives) and opens the
/// AI provider settings. Nothing without an engine.
class ProofreadEngineChip extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final router = GoRouter.maybeOf(context);
    return BlocBuilder<ProofreadCubit, ProofreadState>(
      // Engine equality ignores the model: compare instances.
      buildWhen: (previous, current) =>
          !identical(previous.engine, current.engine) ||
          !identical(previous.availableEngines, current.availableEngines),
      builder: (context, state) {
        final engine = state.engine;
        if (engine == null) return const SizedBox.shrink();
        return ComposerEngineChip(
          key: const Key('proofread_engine_chip'),
          engine: engine,
          engines: state.availableEngines,
          onSelected: context.read<ProofreadCubit>().setEngine,
          // Above the tabs: back returns to proofreading.
          onManage: router == null
              ? null
              : () => unawaited(router.push<void>(AppRoutes.providers)),
        );
      },
    );
  }
}
