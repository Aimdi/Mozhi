import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart';
import 'package:translation_repository/translation_repository.dart';

/// Opens the searchable language picker; resolves to the chosen language
/// (null when dismissed). [source] picks the source list (with "Detect
/// language"), otherwise the target list (with custom styles for AI).
Future<Language?> showLanguagePicker(
  BuildContext context, {
  required bool source,
}) {
  final translate = context.read<TranslateCubit>();
  final settings = context.read<SettingsCubit>();
  return showModalBottomSheet<Language>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => MultiBlocProvider(
      providers: [
        BlocProvider.value(value: translate),
        BlocProvider.value(value: settings),
      ],
      child: LanguagePickerSheet(source: source),
    ),
  );
}

/// Sections: Detect (source), Recent, Pinned, Styles (AI target) and All.
/// Searching filters by English name, native name and code.
class LanguagePickerSheet extends StatefulWidget {
  const LanguagePickerSheet({required this.source, super.key});

  final bool source;

  @override
  State<LanguagePickerSheet> createState() => _LanguagePickerSheetState();
}

class _LanguagePickerSheetState extends State<LanguagePickerSheet> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _pick(Language language) => Navigator.of(context).pop(language);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final state = context.watch<TranslateCubit>().state;
    final settings = context.watch<SettingsCubit>().state;
    final source = widget.source;
    final languages = source ? state.sourceLanguages : state.targetLanguages;
    final selected = source ? state.source : state.target;
    final allowCustom =
        !source && (state.engine?.supportsCustomLanguages ?? false);

    final items = _buildItems(
      context,
      state: state,
      settings: settings,
      languages: languages,
      selected: selected,
      allowCustom: allowCustom,
    );

    final background =
        theme.bottomSheetTheme.modalBackgroundColor ??
        theme.bottomSheetTheme.backgroundColor ??
        theme.colorScheme.surfaceContainerLow;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      minChildSize: 0.4,
      maxChildSize: 1,
      builder: (context, controller) => CustomScrollView(
        controller: controller,
        slivers: [
          PinnedHeaderSliver(
            child: ColoredBox(
              color: background,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                      child: Text(
                        source
                            ? l10n.translatePickerSourceTitle
                            : l10n.translatePickerTargetTitle,
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                    TextField(
                      key: const Key('translate_language_search'),
                      controller: _search,
                      onChanged: (value) => setState(() => _query = value),
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _submitSearch(languages, allowCustom),
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
                        border: const OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(28)),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          SliverList.list(children: items),
          SliverPadding(
            padding: EdgeInsets.only(
              bottom: 24 + MediaQuery.viewInsetsOf(context).bottom,
            ),
          ),
        ],
      ),
    );
  }

  /// Enter picks the single/first match, or the custom language.
  void _submitSearch(List<Language> languages, bool allowCustom) {
    final query = _query.trim();
    if (query.isEmpty) return;
    final matches = _matches(languages, query);
    if (matches.isNotEmpty) {
      _pick(matches.first);
    } else if (allowCustom) {
      _pick(Language.custom(query));
    }
  }

  static List<Language> _matches(List<Language> languages, String query) {
    final q = query.toLowerCase();
    final starts = <Language>[];
    final contains = <Language>[];
    for (final language in languages) {
      if (language.isAuto) continue;
      final name = language.name.toLowerCase();
      final native = language.nativeName?.toLowerCase() ?? '';
      final code = language.code.toLowerCase();
      if (name.startsWith(q) || native.startsWith(q) || code == q) {
        starts.add(language);
      } else if (name.contains(q) || native.contains(q)) {
        contains.add(language);
      }
    }
    return [...starts, ...contains];
  }

  List<Widget> _buildItems(
    BuildContext context, {
    required TranslateState state,
    required AppSettings settings,
    required List<Language> languages,
    required Language selected,
    required bool allowCustom,
  }) {
    final l10n = context.l10n;
    final query = _query.trim();
    final regular = languages.where((l) => !l.isAuto).toList();
    final pinned = settings.pinnedLanguages;

    Widget tile(Language language) => _LanguageTile(
      language: language,
      selected: language == selected,
      pinned: pinned.contains(language),
      onTap: () => _pick(language),
    );

    final styles = allowCustom
        ? LanguageCatalog.customSuggestions
              .where(
                (s) =>
                    query.isEmpty ||
                    s.toLowerCase().contains(query.toLowerCase()),
              )
              .map(Language.custom)
              .toList()
        : const <Language>[];

    if (query.isNotEmpty) {
      final matches = _matches(regular, query);
      return [
        if (matches.isEmpty && allowCustom)
          ListTile(
            key: const Key('translate_language_custom'),
            contentPadding: const EdgeInsets.symmetric(horizontal: 24),
            leading: const Icon(Icons.auto_awesome),
            title: Text(l10n.translatePickerUseCustom(query)),
            subtitle: Text(l10n.translatePickerCustomHint),
            onTap: () => _pick(Language.custom(query)),
          ),
        if (matches.isEmpty && !allowCustom)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              l10n.translatePickerNoResults(query),
              textAlign: TextAlign.center,
            ),
          ),
        ...matches.map(tile),
        if (styles.isNotEmpty) ...[
          _Header(l10n.translatePickerStyles),
          ...styles.map(tile),
        ],
      ];
    }

    Language? available(Language wanted) {
      if (wanted.isCustom) return allowCustom ? wanted : null;
      for (final language in regular) {
        if (language == wanted) return language;
      }
      return null;
    }

    final recents = settings.recentLanguages.map(available).nonNulls.toList();
    final pinnedAvailable = pinned.map(available).nonNulls.toList();
    final auto = widget.source
        ? languages.where((l) => l.isAuto).firstOrNull
        : null;
    final detected = state.result?.detectedSource;

    return [
      if (auto != null)
        ListTile(
          key: const Key('translate_language_auto'),
          contentPadding: const EdgeInsets.symmetric(horizontal: 24),
          leading: const Icon(Icons.auto_awesome_outlined),
          title: Text(l10n.translateDetectLanguage),
          subtitle: detected == null
              ? null
              : Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: _DetectedChip(
                      label: l10n.translateDetectedLanguage(
                        languageNameFor(detected, regular),
                      ),
                    ),
                  ),
                ),
          selected: selected.isAuto,
          trailing: selected.isAuto ? const Icon(Icons.check) : null,
          onTap: () => _pick(auto),
        ),
      if (recents.isNotEmpty) ...[
        _Header(l10n.translatePickerRecent),
        ...recents.map(tile),
      ],
      if (pinnedAvailable.isNotEmpty) ...[
        _Header(l10n.translatePickerPinned),
        ...pinnedAvailable.map(tile),
      ],
      if (styles.isNotEmpty) ...[
        _Header(l10n.translatePickerStyles),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
          child: Text(
            l10n.translatePickerCustomHint,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        ...styles.map(tile),
      ],
      _Header(l10n.translatePickerAll),
      ...regular.map(tile),
    ];
  }
}

class _Header extends StatelessWidget {
  const _Header(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 4),
        child: Text(
          title,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
      ),
    );
  }
}

class _DetectedChip extends StatelessWidget {
  const _DetectedChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelMedium
              ?.copyWith(color: scheme.onSecondaryContainer),
        ),
      ),
    );
  }
}

class _LanguageTile extends StatelessWidget {
  const _LanguageTile({
    required this.language,
    required this.selected,
    required this.pinned,
    required this.onTap,
  });

  final Language language;
  final bool selected;
  final bool pinned;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final native = language.nativeName;
    void togglePin() =>
        context.read<SettingsCubit>().togglePinnedLanguage(language);
    return ListTile(
      contentPadding: const EdgeInsetsDirectional.only(start: 24, end: 8),
      selected: selected,
      leading: language.isCustom ? const Icon(Icons.auto_awesome) : null,
      title: Text(language.name),
      subtitle: language.isCustom
          ? Text(l10n.translatePickerCustomBadge)
          : (native != null && native.isNotEmpty && native != language.name)
          ? Text(native)
          : null,
      onTap: onTap,
      onLongPress: togglePin,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (selected) const Icon(Icons.check),
          IconButton(
            tooltip: pinned
                ? l10n.translateUnpin(language.name)
                : l10n.translatePin(language.name),
            isSelected: pinned,
            icon: const Icon(Icons.push_pin_outlined),
            selectedIcon: const Icon(Icons.push_pin),
            onPressed: togglePin,
          ),
        ],
      ),
    );
  }
}
