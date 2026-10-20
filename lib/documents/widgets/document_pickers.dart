import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/privacy/ime_learning.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/documents/widgets/document_labels.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/widgets/engine_selector.dart';
import 'package:translation_repository/translation_repository.dart';

/// Shows the engine list; resolves to the chosen engine (null when
/// dismissed).
Future<TranslationEngine?> showDocumentEnginePicker(
  BuildContext context, {
  required List<TranslationEngine> engines,
  required TranslationEngine? selected,
}) {
  return showModalBottomSheet<TranslationEngine>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) =>
        DocumentEngineSheet(engines: engines, selected: selected),
  );
}

/// Engines with their privacy badge; the selected one is checked.
class DocumentEngineSheet extends StatelessWidget {
  const new({required this.engines, required this.selected, super.key});

  final List<TranslationEngine> engines;
  final TranslationEngine? selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.3,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Semantics(
              header: true,
              child: Text(
                context.l10n.documentsEngineSheetTitle,
                style: theme.textTheme.titleLarge,
              ),
            ),
          ),
          for (final (index, engine) in engines.indexed) ...[
            if (index > 0) const Hairline(indent: 72),
            ListTile(
              key: Key('documents_engine_${engine.id}'),
              leading: EngineIcon(engine: engine),
              title: Text(engine.name),
              subtitle: engine.subtitle == null ? null : Text(engine.subtitle!),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 8,
                children: [
                  PrivacyBadge(engine: engine),
                  if (engine.id == selected?.id)
                    Icon(Icons.check, color: theme.colorScheme.primary),
                ],
              ),
              selected: engine.id == selected?.id,
              onTap: () => Navigator.of(context).pop(engine),
            ),
          ],
        ],
      ),
    );
  }
}

/// Shows a searchable language list; resolves to the chosen language
/// (null when dismissed). With [allowCustom], a free-form target (AI
/// engines) can be entered through the search field.
Future<Language?> showDocumentLanguagePicker(
  BuildContext context, {
  required String title,
  required List<Language> languages,
  required Language selected,
  bool allowCustom = false,
}) {
  return showModalBottomSheet<Language>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => DocumentLanguageSheet(
      title: title,
      languages: languages,
      selected: selected,
      allowCustom: allowCustom,
    ),
  );
}

class DocumentLanguageSheet extends StatefulWidget {
  const new({
    required this.title,
    required this.languages,
    required this.selected,
    this.allowCustom = false,
    super.key,
  });

  final String title;
  final List<Language> languages;
  final Language selected;
  final bool allowCustom;

  @override
  State<DocumentLanguageSheet> createState() => _DocumentLanguageSheetState();
}

class _DocumentLanguageSheetState extends State<DocumentLanguageSheet> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _matches(Language language, String query) {
    if (query.isEmpty) return true;
    final lower = query.toLowerCase();
    return language.name.toLowerCase().contains(lower) ||
        (language.nativeName?.toLowerCase().contains(lower) ?? false) ||
        language.code.toLowerCase() == lower;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final query = _query.trim();
    final matches = [
      for (final language in widget.languages)
        if (_matches(language, query)) language,
    ];
    final exact = matches.any(
      (language) => language.name.toLowerCase() == query.toLowerCase(),
    );
    final offerCustom = widget.allowCustom && query.isNotEmpty && !exact;
    final palette = AppPalette.of(context);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      minChildSize: 0.4,
      builder: (context, controller) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Semantics(
              header: true,
              child: Text(widget.title, style: theme.textTheme.titleLarge),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              key: const Key('documents_language_search'),
              controller: _search,
              enableIMEPersonalizedLearning: imeLearningAllowed(context),
              onChanged: (value) => setState(() => _query = value),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: l10n.documentsSearchLanguages,
                prefixIcon: const Icon(Icons.search),
              ),
            ),
          ),
          Expanded(
            child: ListView(
              controller: controller,
              padding: const EdgeInsets.only(bottom: 16),
              children: [
                if (offerCustom)
                  ListTile(
                    key: const Key('documents_language_custom'),
                    leading: const Icon(Icons.auto_awesome_outlined),
                    title: Text(l10n.documentsUseCustom(query)),
                    onTap: () =>
                        Navigator.of(context).pop(Language.custom(query)),
                  ),
                if (matches.isEmpty && !offerCustom)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      l10n.documentsNoLanguages,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: palette.secondaryText),
                    ),
                  ),
                for (final (index, language) in matches.indexed) ...[
                  if (index > 0) const Hairline(indent: 72),
                  ListTile(
                    key: Key('documents_language_${language.code}'),
                    leading: LanguageAvatar(code: language.code),
                    title: Text(documentLanguageLabel(l10n, language)),
                    subtitle:
                        language.nativeName == null ||
                            language.nativeName == language.name
                        ? null
                        : Text(language.nativeName!),
                    selected: language == widget.selected,
                    trailing: language == widget.selected
                        ? Icon(Icons.check, color: theme.colorScheme.primary)
                        : null,
                    onTap: () => Navigator.of(context).pop(language),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
