import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/quick_translate/models/quick_languages.dart';
import 'package:translation_repository/translation_repository.dart';

/// Compact inline target picker: recent and common languages as chips, and
/// a search over every target of the engine (plus a custom free-form
/// target for AI engines).
class QuickLanguagePanel extends StatefulWidget {
  const new({
    required this.languages,
    required this.selected,
    required this.onSelected,
    required this.onBack,
    this.allowCustom = false,
    super.key,
  });

  final QuickLanguages languages;
  final Language selected;
  final ValueChanged<Language> onSelected;

  /// Closes the panel without picking.
  final VoidCallback onBack;
  final bool allowCustom;

  @override
  State<QuickLanguagePanel> createState() => _QuickLanguagePanelState();
}

class _QuickLanguagePanelState extends State<QuickLanguagePanel> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _submit() {
    final query = _query.trim();
    if (query.isEmpty) return;
    final matches = widget.languages.search(query, limit: 1);
    if (matches.isNotEmpty) {
      widget.onSelected(matches.first);
    } else if (widget.allowCustom) {
      widget.onSelected(Language.custom(query));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final query = _query.trim();

    return Column(
      key: const Key('quick_translate_language_panel'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            IconButton(
              key: const Key('quick_translate_language_back'),
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              icon: const BackButtonIcon(),
              onPressed: widget.onBack,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  l10n.translatePickerTargetTitle,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          key: const Key('quick_translate_language_search'),
          controller: _search,
          onChanged: (value) => setState(() => _query = value),
          onSubmitted: (_) => _submit(),
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: l10n.translatePickerSearchHint,
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
            filled: true,
            isDense: true,
            border: const OutlineInputBorder(
              borderRadius: BorderRadius.all(Radius.circular(28)),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (query.isEmpty)
          ..._chipSections(context)
        else
          ..._results(context, query),
      ],
    );
  }

  List<Widget> _chipSections(BuildContext context) {
    final l10n = context.l10n;
    final languages = widget.languages;
    return [
      if (languages.recent.isNotEmpty)
        _ChipSection(
          key: const Key('quick_translate_recent_languages'),
          title: l10n.translatePickerRecent,
          languages: languages.recent,
          selected: widget.selected,
          onSelected: widget.onSelected,
        ),
      if (languages.common.isNotEmpty)
        _ChipSection(
          key: const Key('quick_translate_common_languages'),
          title: l10n.quickTranslateCommon,
          languages: languages.common,
          selected: widget.selected,
          onSelected: widget.onSelected,
        ),
    ];
  }

  List<Widget> _results(BuildContext context, String query) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final matches = widget.languages.search(query);
    final exact = matches.any(
      (language) => language.name.toLowerCase() == query.toLowerCase(),
    );
    final palette = AppPalette.of(context);
    return [
      for (final (index, language) in matches.indexed) ...[
        if (index > 0) const Hairline(indent: 64),
        ListTile(
          contentPadding: const EdgeInsetsDirectional.only(start: 8, end: 8),
          leading: language.isCustom
              ? null
              : LanguageAvatar(code: language.code),
          title: Text(
            language.name,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle:
              language.nativeName == null ||
                  language.nativeName == language.name
              ? null
              : Text(
                  language.nativeName!,
                  style: TextStyle(color: palette.secondaryText),
                ),
          selected: language == widget.selected,
          trailing: language == widget.selected
              ? Icon(Icons.check, color: theme.colorScheme.primary)
              : null,
          onTap: () => widget.onSelected(language),
        ),
      ],
      if (widget.allowCustom && !exact)
        ListTile(
          key: const Key('quick_translate_custom_language'),
          contentPadding: const EdgeInsetsDirectional.only(start: 8, end: 8),
          leading: const Icon(Icons.auto_awesome_outlined),
          title: Text(l10n.translatePickerUseCustom(query)),
          onTap: () => widget.onSelected(Language.custom(query)),
        )
      else if (matches.isEmpty)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            l10n.translatePickerNoResults(query),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: palette.secondaryText,
            ),
          ),
        ),
    ];
  }
}

class _ChipSection extends StatelessWidget {
  const new({
    required this.title,
    required this.languages,
    required this.selected,
    required this.onSelected,
    super.key,
  });

  final String title;
  final List<Language> languages;
  final Language selected;
  final ValueChanged<Language> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 4, bottom: 8),
            child: Semantics(
              header: true,
              child: Text(
                title,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final language in languages)
                ChoiceChip(
                  label: Text(language.name),
                  tooltip: language.nativeName == language.name
                      ? null
                      : language.nativeName,
                  selected: language == selected,
                  onSelected: (_) => onSelected(language),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
