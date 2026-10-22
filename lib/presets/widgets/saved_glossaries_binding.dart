import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/presets/cubit/glossary_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

/// Makes every translation apply the user's enabled glossaries: hands the
/// [TranslationRepository] (read from context) a
/// `TranslationRepository.savedGlossaries` lookup that reads the
/// [GlossaryCubit] above at the time of each request, so edits apply to
/// the next translation. Place it below the [GlossaryCubit]; it renders
/// [child].
class SavedGlossariesBinding extends StatefulWidget {
  const new({required this.child, super.key});

  final Widget child;

  @override
  State<SavedGlossariesBinding> createState() => _SavedGlossariesBindingState();
}

class _SavedGlossariesBindingState extends State<SavedGlossariesBinding> {
  TranslationRepository? _repository;
  SavedGlossaryLookup? _lookup;

  @override
  void initState() {
    super.initState();
    final cubit = context.read<GlossaryCubit>();
    SavedGlossary lookup(String source, String target) =>
        cubit.state.savedGlossary(sourceCode: source, targetCode: target);
    final stored = _lookup = lookup;
    _repository = context.read<TranslationRepository>()
      ..savedGlossaries = stored;
  }

  @override
  void dispose() {
    final repository = _repository;
    if (repository != null && identical(repository.savedGlossaries, _lookup)) {
      repository.savedGlossaries = null;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
