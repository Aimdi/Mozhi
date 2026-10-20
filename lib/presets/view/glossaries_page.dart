import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/undo_snack_bar.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/presets/cubit/glossary_cubit.dart';
import 'package:mozhi/presets/models/glossary.dart';
import 'package:mozhi/presets/view/glossary_editor_page.dart';
import 'package:mozhi/presets/widgets/glossary_dialogs.dart';
import 'package:mozhi/presets/widgets/import_text_dialog.dart';
import 'package:mozhi/presets/widgets/preset_labels.dart';
import 'package:mozhi/presets/widgets/presets_message.dart';
import 'package:mozhi/presets/widgets/presets_share.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';

/// Opens the editor of the glossary with the given id.
typedef OpenGlossary = void Function(BuildContext context, String glossaryId);

/// Lists the glossaries of the [GlossaryCubit] in context with their
/// language pair, term count and an enable switch; swipe to delete (with
/// undo), JSON import / export, and a button to create one.
///
/// Tapping a glossary calls [onOpenGlossary], which defaults to pushing a
/// [GlossaryEditorPage] with `Navigator.push`.
class GlossariesPage extends StatelessWidget {
  const new({this.onOpenGlossary, super.key});

  final OpenGlossary? onOpenGlossary;

  /// Default [OpenGlossary]: pushes [GlossaryEditorPage] (re-providing the
  /// [GlossaryCubit] so it also works from a nested navigator).
  static void pushEditor(BuildContext context, String glossaryId) {
    final cubit = context.read<GlossaryCubit>();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BlocProvider.value(
          value: cubit,
          child: GlossaryEditorPage(glossaryId: glossaryId),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) =>
      GlossariesView(onOpenGlossary: onOpenGlossary ?? pushEditor);
}

enum _MenuAction { import, export }

class GlossariesView extends StatefulWidget {
  const new({required this.onOpenGlossary, super.key});

  final OpenGlossary onOpenGlossary;

  @override
  State<GlossariesView> createState() => _GlossariesViewState();
}

class _GlossariesViewState extends State<GlossariesView> {
  final Set<String> _dismissed = {};

  GlossaryCubit get _cubit => context.read<GlossaryCubit>();

  Future<void> _create() async {
    final cubit = _cubit;
    final details = await showGlossaryDetailsDialog(context);
    if (details == null || !mounted) return;
    final glossary = await cubit.create(
      name: details.name,
      sourceCode: details.sourceCode,
      targetCode: details.targetCode,
    );
    if (mounted) widget.onOpenGlossary(context, glossary.id);
  }

  void _delete(Glossary glossary) {
    final l10n = context.l10n;
    final cubit = _cubit;
    final index = cubit.state.glossaries.indexOf(glossary);
    setState(() => _dismissed.add(glossary.id));
    unawaited(cubit.delete(glossary.id));
    showUndoSnackBar(
      context,
      message: l10n.glossariesDeleted(l10n.glossaryName(glossary)),
      onUndo: () {
        unawaited(cubit.restore(glossary, index: index));
        if (mounted) setState(() => _dismissed.remove(glossary.id));
      },
    );
  }

  Future<void> _onMenu(_MenuAction action) async {
    final l10n = context.l10n;
    final cubit = _cubit;
    final messenger = ScaffoldMessenger.of(context);
    switch (action) {
      case _MenuAction.import:
        final count = await showImportTextDialog<int>(
          context,
          title: l10n.glossariesImport,
          hint: l10n.glossariesImportHint,
          invalidMessage: l10n.glossariesImportInvalid,
          onImport: cubit.importJson,
        );
        if (count != null) {
          messenger.showSnackBar(
            SnackBar(content: Text(l10n.glossariesImportDone(count))),
          );
        }
      case _MenuAction.export:
        await showExportSheet(
          context,
          build: cubit.exportJson,
          fileName: 'mozhi-glossaries.json',
          mimeType: 'application/json',
        );
    }
  }

  void _forgetDeleted(BuildContext context, GlossaryState state) {
    final ids = {for (final glossary in state.glossaries) glossary.id};
    _dismissed.removeWhere((id) => !ids.contains(id));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final state = context.watch<GlossaryCubit>().state;
    final glossaries = [
      for (final glossary in state.glossaries)
        if (!_dismissed.contains(glossary.id)) glossary,
    ];
    return BlocListener<GlossaryCubit, GlossaryState>(
      listenWhen: (previous, current) =>
          previous.glossaries != current.glossaries,
      listener: _forgetDeleted,
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.glossariesTitle),
          actions: [
            PopupMenuButton<_MenuAction>(
              key: const Key('glossaries_menu'),
              tooltip: l10n.commonMoreOptions,
              onSelected: (action) => unawaited(_onMenu(action)),
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: _MenuAction.import,
                  child: ListTile(
                    leading: const Icon(Icons.file_download_outlined),
                    title: Text(l10n.glossariesImport),
                  ),
                ),
                PopupMenuItem(
                  value: _MenuAction.export,
                  enabled: state.glossaries.isNotEmpty,
                  child: ListTile(
                    leading: const Icon(Icons.file_upload_outlined),
                    title: Text(l10n.glossariesExportAll),
                  ),
                ),
              ],
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          key: const Key('glossaries_add'),
          onPressed: () => unawaited(_create()),
          icon: const Icon(Icons.add),
          label: Text(l10n.glossariesNew),
        ),
        body: LayoutBuilder(
          builder: (context, constraints) {
            if (state.status == GlossaryStatus.failure &&
                state.glossaries.isEmpty) {
              return PresetsMessage(
                icon: Icons.error_outline,
                title: l10n.glossariesLoadFailed,
                action: FilledButton(
                  onPressed: () => unawaited(_cubit.load()),
                  child: Text(l10n.commonRetry),
                ),
              );
            }
            if (state.glossaries.isEmpty &&
                (state.status == GlossaryStatus.initial ||
                    state.status == GlossaryStatus.loading)) {
              return const Center(child: CircularProgressIndicator());
            }
            if (glossaries.isEmpty) {
              return PresetsMessage(
                icon: Icons.menu_book_outlined,
                title: l10n.glossariesEmptyTitle,
                body: l10n.glossariesEmptyBody,
              );
            }
            return ListView.builder(
              key: const Key('glossaries_list'),
              padding: centeredPadding(
                constraints.maxWidth,
                maxWidth: 760,
                bottom: 96,
              ),
              itemCount: glossaries.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(4, 8, 4, 16),
                    child: Text(
                      l10n.glossariesIntro,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  );
                }
                final glossary = glossaries[index - 1];
                return _GlossaryTile(
                  key: ValueKey(glossary.id),
                  glossary: glossary,
                  onTap: () => widget.onOpenGlossary(context, glossary.id),
                  onEnabled: (enabled) => unawaited(
                    _cubit.setEnabled(glossary.id, enabled: enabled),
                  ),
                  onDismissed: () => _delete(glossary),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _GlossaryTile extends StatelessWidget {
  const new({
    required this.glossary,
    required this.onTap,
    required this.onEnabled,
    required this.onDismissed,
    super.key,
  });

  final Glossary glossary;
  final VoidCallback onTap;
  final ValueChanged<bool> onEnabled;
  final VoidCallback onDismissed;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final name = l10n.glossaryName(glossary);
    // A flat list row with a hairline below, X style.
    return Dismissible(
      key: ValueKey('dismiss-${glossary.id}'),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onDismissed(),
      background: Container(
        alignment: AlignmentDirectional.centerEnd,
        padding: const EdgeInsetsDirectional.only(end: 24),
        color: colors.errorContainer,
        child: Icon(Icons.delete_outline, color: colors.onErrorContainer),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              minTileHeight: 72,
              contentPadding: const EdgeInsetsDirectional.only(
                start: 4,
                end: 4,
              ),
              onTap: onTap,
              leading: CircleAvatar(
                backgroundColor: glossary.enabled
                    ? colors.secondaryContainer
                    : colors.surfaceContainerHighest,
                foregroundColor: glossary.enabled
                    ? colors.onSecondaryContainer
                    : colors.onSurfaceVariant,
                child: const Icon(Icons.menu_book_outlined),
              ),
              title: Text(name, style: theme.textTheme.titleMedium),
              subtitle: Text(
                '${l10n.glossaryScope(glossary)} · '
                '${l10n.glossariesTermCount(glossary.terms.length)}',
              ),
              trailing: Semantics(
                label: l10n.glossariesEnableLabel(name),
                child: Switch(
                  key: Key('glossary_enabled_${glossary.id}'),
                  value: glossary.enabled,
                  onChanged: onEnabled,
                ),
              ),
            ),
            const Hairline(),
          ],
        ),
      ),
    );
  }
}
