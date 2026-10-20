import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/privacy/ime_learning.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/widgets/language_text.dart';
import 'package:translation_repository/translation_repository.dart';

/// Display name of [language] ("Detect language" for [Language.auto]).
String dictionaryLanguageName(AppLocalizations l10n, Language language) =>
    language.isAuto ? l10n.dictionaryDetectLanguage : language.name;

/// Opens a searchable list of [languages] with [selected] checked; resolves
/// to the chosen language (null when dismissed).
Future<Language?> showDictionaryLanguagePicker(
  BuildContext context, {
  required String title,
  required List<Language> languages,
  required Language selected,
}) => showModalBottomSheet<Language>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (_) => DictionaryLanguagePicker(
    title: title,
    languages: languages,
    selected: selected,
  ),
);

/// Searchable language list of the dictionary (by English name, native
/// name or code). Picking a language pops it.
class DictionaryLanguagePicker extends StatefulWidget {
  const new({
    required this.title,
    required this.languages,
    required this.selected,
    super.key,
  });

  final String title;
  final List<Language> languages;
  final Language selected;

  @override
  State<DictionaryLanguagePicker> createState() =>
      _DictionaryLanguagePickerState();
}

class _DictionaryLanguagePickerState extends State<DictionaryLanguagePicker> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Languages matching the search: exact codes first, then names that
  /// start with it, then names that contain it.
  List<Language> _matches(AppLocalizations l10n) {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return widget.languages;
    final exact = <Language>[];
    final starts = <Language>[];
    final contains = <Language>[];
    for (final language in widget.languages) {
      final names = [
        dictionaryLanguageName(l10n, language).toLowerCase(),
        language.nativeName?.toLowerCase() ?? '',
      ];
      if (language.code.toLowerCase() == query) {
        exact.add(language);
      } else if (names.any((name) => name.startsWith(query))) {
        starts.add(language);
      } else if (names.any((name) => name.contains(query))) {
        contains.add(language);
      }
    }
    return [...exact, ...starts, ...contains];
  }

  void _pick(Language language) => Navigator.of(context).pop(language);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final matches = _matches(l10n);
    // Above the keyboard the search opens, so the results stay in view.
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: FractionallySizedBox(
        heightFactor: 0.85,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: Semantics(
                header: true,
                child: Text(
                  widget.title,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                key: const Key('dictionary_language_search'),
                controller: _search,
                enableIMEPersonalizedLearning: imeLearningAllowed(context),
                onChanged: (value) => setState(() => _query = value),
                textInputAction: TextInputAction.search,
                onSubmitted: (_) {
                  final current = _matches(l10n);
                  if (current.isNotEmpty) _pick(current.first);
                },
                decoration: InputDecoration(
                  // A label, unlike a hint, still names the field once it
                  // holds a query (WCAG 4.1.2, 3.3.2).
                  labelText: l10n.dictionaryPickerSearchHint,
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: l10n.commonClear,
                          icon: const Icon(Icons.close),
                          onPressed: () {
                            _search.clear();
                            setState(() => _query = '');
                          },
                        ),
                ),
              ),
            ),
            Expanded(
              child: matches.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          l10n.dictionaryPickerNoMatches,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: palette.secondaryText,
                          ),
                        ),
                      ),
                    )
                  : ListView.separated(
                      itemCount: matches.length,
                      separatorBuilder: (_, _) => const Hairline(indent: 80),
                      itemBuilder: (context, index) {
                        final language = matches[index];
                        final selected = language == widget.selected;
                        final native = language.nativeName;
                        return ListTile(
                          key: ValueKey('dictionary_language_${language.code}'),
                          contentPadding: const EdgeInsetsDirectional.only(
                            start: 24,
                            end: 16,
                          ),
                          selected: selected,
                          leading: LanguageAvatar(code: language.code),
                          title: Text(
                            dictionaryLanguageName(l10n, language),
                            style: TextStyle(
                              fontWeight: selected
                                  ? FontWeight.w800
                                  : FontWeight.w600,
                            ),
                          ),
                          subtitle:
                              native != null &&
                                  native.isNotEmpty &&
                                  native != language.name
                              // The locale picks a matching voice and glyphs.
                              ? Text.rich(
                                  TextSpan(
                                    text: native,
                                    locale: localeForLanguage(language),
                                  ),
                                  style: TextStyle(
                                    color: palette.secondaryText,
                                  ),
                                )
                              : null,
                          trailing: selected
                              ? Icon(
                                  Icons.check,
                                  color: theme.colorScheme.primary,
                                )
                              : null,
                          onTap: () => _pick(language),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
