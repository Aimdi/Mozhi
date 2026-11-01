import 'package:material_ui/material_ui.dart';
import 'package:mozhi/conversation/widgets/conversation_orientation.dart';
import 'package:mozhi/core/privacy/ime_learning.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/widgets/language_search.dart';
import 'package:translation_repository/translation_repository.dart';

/// Opens a searchable language dialog (turned upside down when opened from
/// side B's half in face-to-face mode). Resolves to the chosen language, or
/// null when dismissed. Auto and custom entries of [languages] are left out;
/// [recent] languages are listed first.
Future<Language?> showConversationLanguagePicker(
  BuildContext context, {
  required Language selected,
  required List<Language> languages,
  List<Language> recent = const [],
}) {
  return showConversationDialog<Language>(
    context: context,
    builder: (_) => ConversationLanguagePicker(
      selected: selected,
      languages: languages,
      recent: recent,
    ),
  );
}

class ConversationLanguagePicker extends StatefulWidget {
  const new({
    required this.selected,
    required this.languages,
    this.recent = const [],
    super.key,
  });

  final Language selected;
  final List<Language> languages;
  final List<Language> recent;

  @override
  State<ConversationLanguagePicker> createState() =>
      _ConversationLanguagePickerState();
}

class _ConversationLanguagePickerState
    extends State<ConversationLanguagePicker> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  static bool _selectable(Language language) =>
      !language.isAuto && !language.isCustom;

  bool _matches(Language language) {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return true;
    return language.name.toLowerCase().contains(query) ||
        context.languageName(language).toLowerCase().contains(query) ||
        (language.nativeName?.toLowerCase().contains(query) ?? false) ||
        language.code.toLowerCase() == query;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final all = sortLanguagesByName(
      widget.languages.where(_selectable),
      context.languageName,
    );
    final recent = _query.trim().isEmpty
        ? [
            for (final language in widget.recent)
              if (_selectable(language) && all.contains(language)) language,
          ]
        : const <Language>[];
    final matches = all.where(_matches).toList();

    final items = <Widget>[
      if (recent.isNotEmpty) ...[
        _Header(l10n.conversationRecentLanguages),
        for (final language in recent) _tile(language),
        _Header(l10n.conversationAllLanguages),
      ],
      for (final language in matches) _tile(language),
    ];

    return Dialog(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 600),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
              child: Text(
                l10n.conversationPickLanguage,
                style: theme.textTheme.headlineSmall,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                key: const Key('conversation_language_search'),
                controller: _search,
                enableIMEPersonalizedLearning: imeLearningAllowed(context),
                onChanged: (value) => setState(() => _query = value),
                textInputAction: TextInputAction.search,
                onSubmitted: (_) {
                  if (matches.length == 1) {
                    Navigator.of(context).pop(matches.single);
                  }
                },
                decoration: InputDecoration(
                  hintText: l10n.conversationSearchLanguages,
                  prefixIcon: const Icon(Icons.search),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: matches.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        l10n.conversationNoLanguagesFound,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView(
                      key: const Key('conversation_language_list'),
                      shrinkWrap: true,
                      children: items,
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(l10n.commonCancel),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tile(Language language) {
    final selected = language == widget.selected;
    final native = language.nativeName;
    final name = context.languageName(language);
    return ListTile(
      selected: selected,
      title: Text(name),
      subtitle: native == null || native == name ? null : Text(native),
      trailing: selected ? const Icon(Icons.check) : null,
      contentPadding: const EdgeInsets.symmetric(horizontal: 24),
      onTap: () => Navigator.of(context).pop(language),
    );
  }
}

class _Header extends StatelessWidget {
  const new(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
        child: Text(
          label,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
      ),
    );
  }
}
