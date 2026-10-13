import 'package:material_ui/material_ui.dart';
import 'package:mozhi/image_translate/widgets/image_translate_labels.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:translation_repository/translation_repository.dart';

/// Opens a searchable list of [languages]; resolves to the chosen language
/// (null when dismissed).
Future<Language?> showImageLanguagePicker(
  BuildContext context, {
  required List<Language> languages,
  required Language selected,
  required String title,
}) => showModalBottomSheet<Language>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (_) => ImageLanguagePickerSheet(
    languages: languages,
    selected: selected,
    title: title,
  ),
);

/// A simple searchable language list (search by name, native name or
/// code).
class ImageLanguagePickerSheet extends StatefulWidget {
  const new({
    required this.languages,
    required this.selected,
    required this.title,
    super.key,
  });

  final List<Language> languages;
  final Language selected;
  final String title;

  @override
  State<ImageLanguagePickerSheet> createState() =>
      _ImageLanguagePickerSheetState();
}

class _ImageLanguagePickerSheetState extends State<ImageLanguagePickerSheet> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<Language> get _matches {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return widget.languages;
    return [
      for (final language in widget.languages)
        if (language.name.toLowerCase().contains(query) ||
            (language.nativeName?.toLowerCase().contains(query) ?? false) ||
            language.code.toLowerCase() == query)
          language,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final matches = _matches;
    final height = MediaQuery.sizeOf(context).height * 0.75;
    return SizedBox(
      height: height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(widget.title, style: theme.textTheme.titleMedium),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              key: const Key('image_language_search'),
              controller: _search,
              onChanged: (value) => setState(() => _query = value),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: l10n.imageTranslateSearchLanguages,
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          Expanded(
            child: matches.isEmpty
                ? Center(child: Text(l10n.imageTranslateNoLanguages))
                : ListView.builder(
                    itemCount: matches.length,
                    itemBuilder: (context, index) {
                      final language = matches[index];
                      final selected = language == widget.selected;
                      final native = language.nativeName;
                      return ListTile(
                        key: Key('image_language_${language.code}'),
                        selected: selected,
                        title: Text(imageLanguageLabel(l10n, language)),
                        subtitle: native == null || native == language.name
                            ? null
                            : Text(native),
                        trailing: selected ? const Icon(Icons.check) : null,
                        onTap: () => Navigator.of(context).pop(language),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
