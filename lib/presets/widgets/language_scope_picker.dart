import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/presets/models/glossary.dart';
import 'package:translation_repository/translation_repository.dart';

/// Searchable sheet of [LanguageCatalog.all] plus "Any language". Completes
/// with the chosen code ([LanguageScope.any] for any), or `null`.
Future<String?> showLanguageScopePicker(
  BuildContext context, {
  required String title,
  required String selected,
}) => showModalBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (_) => LanguageScopePicker(title: title, selected: selected),
);

class LanguageScopePicker extends StatefulWidget {
  const new({
    required this.title,
    required this.selected,
    super.key,
  });

  final String title;

  /// Currently selected code or [LanguageScope.any].
  final String selected;

  @override
  State<LanguageScopePicker> createState() => _LanguageScopePickerState();
}

class _LanguageScopePickerState extends State<LanguageScopePicker> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _isSelected(String code) => LanguageScope.isAny(widget.selected)
      ? LanguageScope.isAny(code)
      : code.toLowerCase() == widget.selected.trim().toLowerCase();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final needle = _query.trim().toLowerCase();
    final languages = [
      for (final language in LanguageCatalog.all)
        if (needle.isEmpty ||
            language.name.toLowerCase().contains(needle) ||
            (language.nativeName?.toLowerCase().contains(needle) ?? false) ||
            language.code.toLowerCase() == needle)
          language,
    ];
    final showAny =
        needle.isEmpty ||
        l10n.glossariesAnyLanguage.toLowerCase().contains(needle);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      minChildSize: 0.4,
      builder: (context, controller) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Semantics(
                  header: true,
                  child: Text(widget.title, style: theme.textTheme.titleLarge),
                ),
                const SizedBox(height: 12),
                SearchBar(
                  key: const Key('language_scope_search'),
                  controller: _search,
                  hintText: l10n.glossariesLanguageSearch,
                  elevation: const WidgetStatePropertyAll(0),
                  leading: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Icon(Icons.search),
                  ),
                  onChanged: (value) => setState(() => _query = value),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              controller: controller,
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                if (showAny)
                  _LanguageTile(
                    key: const Key('language_scope_any'),
                    title: l10n.glossariesAnyLanguage,
                    leading: const Icon(Icons.public),
                    selected: _isSelected(LanguageScope.any),
                    onTap: () => Navigator.of(context).pop(LanguageScope.any),
                  ),
                for (final language in languages)
                  _LanguageTile(
                    key: Key('language_scope_${language.code}'),
                    title: language.name,
                    subtitle: language.nativeName == language.name
                        ? null
                        : language.nativeName,
                    selected: _isSelected(language.code),
                    onTap: () => Navigator.of(context).pop(language.code),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LanguageTile extends StatelessWidget {
  const new({
    required this.title,
    required this.selected,
    required this.onTap,
    this.subtitle,
    this.leading,
    super.key,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 24),
      leading: leading,
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!),
      selected: selected,
      trailing: selected ? const Icon(Icons.check) : null,
      onTap: onTap,
    );
  }
}
