import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/composer_card.dart';
import 'package:mozhi/dictionary/cubit/dictionary_cubit.dart';
import 'package:mozhi/dictionary/widgets/dictionary_result.dart'
    show dictionaryProvidersRoute;
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

/// The AI model that writes the dictionary's entries, as a chip for the
/// app bar ([ComposerEngineChip]): its menu picks another one for the
/// dictionary ([DictionaryCubit.pickEngine], kept while the page lives,
/// like Proofread's model) and opens the AI provider settings. Nothing
/// without an engine.
class DictionaryEngineChip extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final engine = context.select<DictionaryCubit, TranslationEngine?>(
      (cubit) => cubit.state.engine,
    );
    final engines = context.select<TranslateCubit, List<TranslationEngine>>(
      (cubit) => cubit.state.engines,
    );
    if (engine == null) return const SizedBox.shrink();
    final router = GoRouter.maybeOf(context);
    return ComposerEngineChip(
      key: const Key('dictionary_engine_chip'),
      engine: engine,
      engines: [
        for (final option in engines)
          if (option.supportsExtras) option,
      ],
      onSelected: context.read<DictionaryCubit>().pickEngine,
      // Above the tabs: back returns to the dictionary.
      onManage: router == null
          ? null
          : () => unawaited(router.push<void>(dictionaryProvidersRoute)),
    );
  }
}
