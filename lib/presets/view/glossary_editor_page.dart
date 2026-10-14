import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/undo_snack_bar.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/presets/cubit/glossary_cubit.dart';
import 'package:mozhi/presets/data/glossary_repository.dart';
import 'package:mozhi/presets/models/glossary.dart';
import 'package:mozhi/presets/widgets/glossary_dialogs.dart';
import 'package:mozhi/presets/widgets/import_text_dialog.dart';
import 'package:mozhi/presets/widgets/preset_labels.dart';
import 'package:mozhi/presets/widgets/presets_message.dart';
import 'package:mozhi/presets/widgets/presets_share.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';

/// Edits one glossary of the [GlossaryCubit] in context: a searchable table
/// of terms (tap to edit, swipe or delete button with undo), add term,
/// import from pasted CSV / TSV / JSON, export (copy / share as CSV, TSV or
/// JSON), rename / change languages, enable and delete.
///
/// When the glossary does not exist (any more) a message is shown.
class GlossaryEditorPage extends StatelessWidget {
  const new({required this.glossaryId, super.key});

  final String glossaryId;

  @override
  Widget build(BuildContext context) =>
      GlossaryEditorView(glossaryId: glossaryId);
}

enum _ExportAction { copyCsv, shareCsv, shareTsv, shareJson }

enum _MoreAction { details, delete }

class GlossaryEditorView extends StatefulWidget {
  const new({required this.glossaryId, super.key});

  final String glossaryId;

  @override
  State<GlossaryEditorView> createState() => _GlossaryEditorViewState();
}

class _GlossaryEditorViewState extends State<GlossaryEditorView> {
  final _search = TextEditingController();
  String _query = '';

  String get _id => widget.glossaryId;

  GlossaryCubit get _cubit => context.read<GlossaryCubit>();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _addTerm() async {
    final cubit = _cubit;
    final term = await showGlossaryTermDialog(context);
    if (term != null) await cubit.addTerm(_id, term);
  }

  Future<void> _editTerm(int index, GlossaryTerm term) async {
    final cubit = _cubit;
    final updated = await showGlossaryTermDialog(context, term: term);
    if (updated != null) await cubit.updateTerm(_id, index, updated);
  }

  void _deleteTerm(int index, GlossaryTerm term) {
    final l10n = context.l10n;
    final cubit = _cubit;
    unawaited(cubit.removeTerm(_id, index));
    showUndoSnackBar(
      context,
      message: l10n.glossaryEditorTermDeleted(term.source),
      onUndo: () => unawaited(cubit.insertTerm(_id, index, term)),
    );
  }

  Future<void> _import() async {
    final l10n = context.l10n;
    final cubit = _cubit;
    final messenger = ScaffoldMessenger.of(context);
    final result = await showImportTextDialog<TermImport>(
      context,
      title: l10n.glossaryEditorImportTitle,
      help: l10n.glossaryEditorImportHelp,
      hint: l10n.glossaryEditorImportHint,
      invalidMessage: l10n.glossaryEditorImportInvalid,
      onImport: (text) => cubit.importTerms(_id, text),
    );
    if (result == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            l10n.glossaryEditorImportDone(
              result.added,
              result.updated,
              result.skipped,
            ),
          ),
        ),
      );
  }

  Future<void> _export(_ExportAction action, Glossary glossary) {
    final format = switch (action) {
      _ExportAction.copyCsv ||
      _ExportAction.shareCsv => GlossaryExportFormat.csv,
      _ExportAction.shareTsv => GlossaryExportFormat.tsv,
      _ExportAction.shareJson => GlossaryExportFormat.json,
    };
    return exportText(
      ScaffoldMessenger.maybeOf(context),
      context.l10n,
      build: () => GlossaryRepository.exportTerms(glossary, format),
      copy: action == _ExportAction.copyCsv,
      fileName: '${_fileStem(glossary.name)}.${format.extension}',
      mimeType: format.mimeType,
    );
  }

  Future<void> _onMore(_MoreAction action, Glossary glossary) async {
    switch (action) {
      case _MoreAction.details:
        await _editDetails(glossary);
      case _MoreAction.delete:
        await _deleteGlossary(glossary);
    }
  }

  Future<void> _editDetails(Glossary glossary) async {
    final cubit = _cubit;
    final details = await showGlossaryDetailsDialog(
      context,
      glossary: glossary,
    );
    if (details == null) return;
    final current = cubit.state.byId(_id);
    if (current == null) return;
    await cubit.save(
      current.copyWith(
        name: details.name,
        sourceCode: details.sourceCode,
        targetCode: details.targetCode,
      ),
    );
  }

  Future<void> _deleteGlossary(Glossary glossary) async {
    final l10n = context.l10n;
    final cubit = _cubit;
    final navigator = Navigator.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.glossaryEditorDeleteTitle),
        content: Text(
          l10n.glossaryEditorDeleteBody(l10n.glossaryName(glossary)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            key: const Key('glossary_editor_delete_confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.commonDelete),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false)) return;
    await cubit.delete(_id);
    await navigator.maybePop();
  }

  static String _fileStem(String name) {
    final slug = name
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return slug.isEmpty ? 'mozhi-glossary' : 'mozhi-glossary-$slug';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<GlossaryCubit>().state;
    final glossary = state.byId(_id);
    if (glossary == null) {
      final loading =
          state.status == GlossaryStatus.initial ||
          state.status == GlossaryStatus.loading;
      return Scaffold(
        appBar: AppBar(title: Text(l10n.glossariesTitle)),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : PresetsMessage(
                icon: Icons.menu_book_outlined,
                title: l10n.glossaryEditorNotFound,
              ),
      );
    }
    final needle = _query.trim().toLowerCase();
    final visible = <(int, GlossaryTerm)>[
      for (var i = 0; i < glossary.terms.length; i++)
        if (needle.isEmpty || _matches(glossary.terms[i], needle))
          (i, glossary.terms[i]),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.glossaryName(glossary)),
        actions: [
          IconButton(
            key: const Key('glossary_editor_import'),
            tooltip: l10n.glossaryEditorImport,
            icon: const Icon(Icons.playlist_add),
            onPressed: () => unawaited(_import()),
          ),
          PopupMenuButton<_ExportAction>(
            key: const Key('glossary_editor_export'),
            tooltip: l10n.glossaryEditorExport,
            icon: const Icon(Icons.ios_share),
            enabled: glossary.terms.isNotEmpty,
            onSelected: (action) => unawaited(_export(action, glossary)),
            itemBuilder: (context) => [
              _menuItem(
                _ExportAction.copyCsv,
                Icons.copy_outlined,
                l10n.glossaryEditorCopyCsv,
              ),
              _menuItem(
                _ExportAction.shareCsv,
                Icons.table_chart_outlined,
                l10n.glossaryEditorShareCsv,
              ),
              _menuItem(
                _ExportAction.shareTsv,
                Icons.table_rows_outlined,
                l10n.glossaryEditorShareTsv,
              ),
              _menuItem(
                _ExportAction.shareJson,
                Icons.data_object,
                l10n.glossaryEditorShareJson,
              ),
            ],
          ),
          PopupMenuButton<_MoreAction>(
            key: const Key('glossary_editor_more'),
            tooltip: l10n.commonMoreOptions,
            onSelected: (action) => unawaited(_onMore(action, glossary)),
            itemBuilder: (context) => [
              _menuItem(
                _MoreAction.details,
                Icons.edit_outlined,
                l10n.glossaryEditorEditDetails,
              ),
              _menuItem(
                _MoreAction.delete,
                Icons.delete_outline,
                l10n.glossaryEditorDelete,
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('glossary_editor_add'),
        onPressed: () => unawaited(_addTerm()),
        icon: const Icon(Icons.add),
        label: Text(l10n.glossaryEditorAddTerm),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final padding = centeredPadding(
            constraints.maxWidth,
            maxWidth: 960,
            bottom: 96,
          );
          final wide = constraints.maxWidth - padding.horizontal >= 600;
          return CustomScrollView(
            slivers: [
              SliverPadding(
                padding: padding.copyWith(bottom: 8),
                sliver: SliverList.list(
                  children: [
                    _Header(
                      glossary: glossary,
                      onEnabled: (enabled) =>
                          unawaited(_cubit.setEnabled(_id, enabled: enabled)),
                      onEditDetails: () => unawaited(_editDetails(glossary)),
                    ),
                    const SizedBox(height: 16),
                    if (glossary.terms.isNotEmpty)
                      SearchBar(
                        key: const Key('glossary_editor_search'),
                        controller: _search,
                        hintText: l10n.glossaryEditorSearchHint,
                        elevation: const WidgetStatePropertyAll(0),
                        leading: const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 8),
                          child: Icon(Icons.search),
                        ),
                        trailing: [
                          if (_query.isNotEmpty)
                            IconButton(
                              tooltip: l10n.glossaryEditorClearSearch,
                              icon: const Icon(Icons.close),
                              onPressed: () {
                                _search.clear();
                                setState(() => _query = '');
                              },
                            ),
                        ],
                        onChanged: (value) => setState(() => _query = value),
                      ),
                    if (wide && visible.isNotEmpty) const _TableHeader(),
                  ],
                ),
              ),
              if (glossary.terms.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: PresetsMessage(
                    icon: Icons.translate,
                    title: l10n.glossaryEditorEmptyTitle,
                    body: l10n.glossaryEditorEmptyBody,
                    action: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: [
                        FilledButton.tonalIcon(
                          onPressed: () => unawaited(_addTerm()),
                          icon: const Icon(Icons.add),
                          label: Text(l10n.glossaryEditorAddTerm),
                        ),
                        OutlinedButton.icon(
                          key: const Key('glossary_editor_empty_import'),
                          onPressed: () => unawaited(_import()),
                          icon: const Icon(Icons.playlist_add),
                          label: Text(l10n.glossaryEditorImport),
                        ),
                      ],
                    ),
                  ),
                )
              else if (visible.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: PresetsMessage(
                    icon: Icons.search_off,
                    title: l10n.glossaryEditorNoMatches,
                  ),
                )
              else
                SliverPadding(
                  padding: padding.copyWith(top: 0),
                  sliver: SliverList.builder(
                    itemCount: visible.length,
                    itemBuilder: (context, i) {
                      final (index, term) = visible[i];
                      return _TermRow(
                        key: ValueKey('term-$index-${term.source}'),
                        index: index,
                        term: term,
                        wide: wide,
                        onTap: () => unawaited(_editTerm(index, term)),
                        onDelete: () => _deleteTerm(index, term),
                      );
                    },
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  static bool _matches(GlossaryTerm term, String needle) =>
      term.source.toLowerCase().contains(needle) ||
      term.target.toLowerCase().contains(needle) ||
      term.note.toLowerCase().contains(needle);

  static PopupMenuItem<T> _menuItem<T>(T value, IconData icon, String label) =>
      PopupMenuItem(
        value: value,
        child: ListTile(leading: Icon(icon), title: Text(label)),
      );
}

class _Header extends StatelessWidget {
  const new({
    required this.glossary,
    required this.onEnabled,
    required this.onEditDetails,
  });

  final Glossary glossary;
  final ValueChanged<bool> onEnabled;
  final VoidCallback onEditDetails;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Card.filled(
      margin: EdgeInsets.zero,
      color: colors.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Column(
        children: [
          ListTile(
            key: const Key('glossary_editor_scope'),
            leading: const Icon(Icons.translate),
            title: Text(l10n.glossaryScope(glossary)),
            subtitle: Text(l10n.glossariesTermCount(glossary.terms.length)),
            trailing: IconButton(
              tooltip: l10n.glossaryEditorEditDetails,
              icon: const Icon(Icons.edit_outlined),
              onPressed: onEditDetails,
            ),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          SwitchListTile(
            key: const Key('glossary_editor_enabled'),
            secondary: const Icon(Icons.check_circle_outline),
            title: Text(l10n.glossaryEditorEnabled),
            subtitle: Text(l10n.glossaryEditorEnabledDescription),
            value: glossary.enabled,
            onChanged: onEnabled,
          ),
        ],
      ),
    );
  }
}

class _TableHeader extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final style = theme.textTheme.labelLarge?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return ExcludeSemantics(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 0, 4),
        child: Row(
          children: [
            Expanded(
              flex: 3,
              child: Text(l10n.glossaryEditorSource, style: style),
            ),
            Expanded(
              flex: 3,
              child: Text(l10n.glossaryEditorTarget, style: style),
            ),
            Expanded(
              flex: 3,
              child: Text(l10n.glossaryEditorNoteColumn, style: style),
            ),
            const SizedBox(width: 96),
          ],
        ),
      ),
    );
  }
}

class _TermRow extends StatelessWidget {
  const new({
    required this.index,
    required this.term,
    required this.wide,
    required this.onTap,
    required this.onDelete,
    super.key,
  });

  /// Index of [term] in the glossary.
  final int index;
  final GlossaryTerm term;
  final bool wide;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final delete = IconButton(
      tooltip: l10n.glossaryEditorDeleteTerm(term.source),
      icon: const Icon(Icons.delete_outline),
      onPressed: onDelete,
    );
    final caseBadge = term.caseSensitive
        ? Tooltip(
            message: l10n.glossaryEditorCaseSensitiveBadge,
            child: Icon(
              Icons.text_fields,
              size: 20,
              color: colors.primary,
              semanticLabel: l10n.glossaryEditorCaseSensitiveBadge,
            ),
          )
        : null;
    final Widget content;
    if (wide) {
      content = InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsetsDirectional.only(start: 16),
            child: Row(
              children: [
                Expanded(
                  flex: 3,
                  child: Text(term.source, style: theme.textTheme.bodyLarge),
                ),
                Expanded(
                  flex: 3,
                  child: Text(term.target, style: theme.textTheme.bodyLarge),
                ),
                Expanded(
                  flex: 3,
                  child: Text(
                    term.note,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
                SizedBox(width: 48, child: caseBadge),
                delete,
              ],
            ),
          ),
        ),
      );
    } else {
      content = ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsetsDirectional.only(start: 16, end: 4),
        title: Row(
          children: [
            Flexible(child: Text(term.source)),
            if (caseBadge != null) ...[const SizedBox(width: 8), caseBadge],
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.arrow_forward, size: 16, color: colors.primary),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    term.target,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: colors.onSurface,
                    ),
                  ),
                ),
              ],
            ),
            if (term.note.isNotEmpty)
              Text(term.note, maxLines: 2, overflow: TextOverflow.ellipsis),
          ],
        ),
        trailing: delete,
      );
    }
    return Dismissible(
      key: ValueKey('dismiss-${term.source}-$index'),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onDelete(),
      background: ColoredBox(
        color: colors.errorContainer,
        child: Align(
          alignment: AlignmentDirectional.centerEnd,
          child: Padding(
            padding: const EdgeInsetsDirectional.only(end: 24),
            child: Icon(Icons.delete_outline, color: colors.onErrorContainer),
          ),
        ),
      ),
      child: Semantics(
        label: l10n.glossaryEditorTermSemantics(term.source, term.target),
        child: Column(
          children: [
            content,
            Divider(height: 1, color: colors.outlineVariant),
          ],
        ),
      ),
    );
  }
}
