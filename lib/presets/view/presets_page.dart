import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/presets/cubit/presets_cubit.dart';
import 'package:mozhi/presets/models/preset.dart';
import 'package:mozhi/presets/widgets/import_text_dialog.dart';
import 'package:mozhi/presets/widgets/preset_editor_sheet.dart';
import 'package:mozhi/presets/widgets/preset_labels.dart';
import 'package:mozhi/presets/widgets/presets_message.dart';
import 'package:mozhi/presets/widgets/presets_share.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';

/// Lists the presets of the [PresetsCubit] in context: reorder by dragging,
/// tap to edit, swipe to delete (with undo), default badge, duplicate,
/// import / export.
///
/// [onOpenGlossaries] adds a "Glossaries" action to the app bar.
class PresetsPage extends StatelessWidget {
  const new({this.onOpenGlossaries, super.key});

  final VoidCallback? onOpenGlossaries;

  @override
  Widget build(BuildContext context) =>
      PresetsView(onOpenGlossaries: onOpenGlossaries);
}

enum _PresetAction {
  edit,
  toggleDefault,
  duplicate,
  share,
  moveUp,
  moveDown,
  delete,
}

enum _MenuAction { import, export, restoreExamples }

class PresetsView extends StatefulWidget {
  const new({this.onOpenGlossaries, super.key});

  final VoidCallback? onOpenGlossaries;

  @override
  State<PresetsView> createState() => _PresetsViewState();
}

class _PresetsViewState extends State<PresetsView> {
  /// Presets swiped away whose removal may not have reached the state yet.
  final Set<String> _dismissed = {};

  PresetsCubit get _cubit => context.read<PresetsCubit>();

  void _delete(Preset preset) {
    final l10n = context.l10n;
    final cubit = _cubit;
    final index = cubit.state.presets.indexOf(preset);
    final wasDefault = cubit.state.defaultId == preset.id;
    setState(() => _dismissed.add(preset.id));
    unawaited(cubit.delete(preset.id));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(l10n.presetsDeleted(l10n.presetName(preset))),
          action: SnackBarAction(
            label: l10n.commonUndo,
            onPressed: () {
              unawaited(
                cubit.restore(preset, index: index, makeDefault: wasDefault),
              );
              if (mounted) setState(() => _dismissed.remove(preset.id));
            },
          ),
        ),
      );
  }

  void _onAction(_PresetAction action, Preset preset, int index) {
    final l10n = context.l10n;
    final cubit = _cubit;
    switch (action) {
      case _PresetAction.edit:
        unawaited(showPresetEditor(context, preset: preset));
      case _PresetAction.toggleDefault:
        unawaited(
          cubit.setDefault(
            cubit.state.defaultId == preset.id ? null : preset.id,
          ),
        );
      case _PresetAction.duplicate:
        unawaited(
          cubit.duplicate(
            preset.id,
            name: l10n.presetsCopyName(l10n.presetName(preset)),
          ),
        );
      case _PresetAction.share:
        unawaited(
          showExportSheet(
            context,
            build: () => cubit.exportJson(ids: {preset.id}),
            fileName: 'mozhi-preset.json',
            mimeType: 'application/json',
          ),
        );
      case _PresetAction.moveUp:
        unawaited(cubit.move(index, index - 1));
      case _PresetAction.moveDown:
        unawaited(cubit.move(index, index + 1));
      case _PresetAction.delete:
        _delete(preset);
    }
  }

  Future<void> _onMenu(_MenuAction action) async {
    final l10n = context.l10n;
    final cubit = _cubit;
    final messenger = ScaffoldMessenger.of(context);
    switch (action) {
      case _MenuAction.import:
        final count = await showImportTextDialog<int>(
          context,
          title: l10n.presetsImport,
          hint: l10n.presetsImportHint,
          invalidMessage: l10n.presetsImportInvalid,
          onImport: cubit.importJson,
        );
        if (count != null) {
          messenger.showSnackBar(
            SnackBar(content: Text(l10n.presetsImportDone(count))),
          );
        }
      case _MenuAction.export:
        await showExportSheet(
          context,
          build: cubit.exportJson,
          fileName: 'mozhi-presets.json',
          mimeType: 'application/json',
        );
      case _MenuAction.restoreExamples:
        await _restoreExamples();
    }
  }

  Future<void> _restoreExamples() async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final count = await _cubit.restoreExamples();
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(l10n.presetsExamplesRestored(count))),
      );
  }

  /// Once the cubit no longer has a swiped preset, stop hiding its id.
  void _forgetDeleted(BuildContext context, PresetsState state) {
    final ids = {for (final preset in state.presets) preset.id};
    _dismissed.removeWhere((id) => !ids.contains(id));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<PresetsCubit>().state;
    final presets = [
      for (final preset in state.presets)
        if (!_dismissed.contains(preset.id)) preset,
    ];
    return BlocListener<PresetsCubit, PresetsState>(
      listenWhen: (previous, current) => previous.presets != current.presets,
      listener: _forgetDeleted,
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.presetsTitle),
          actions: [
            if (widget.onOpenGlossaries != null)
              IconButton(
                key: const Key('presets_open_glossaries'),
                tooltip: l10n.presetsGlossaries,
                icon: const Icon(Icons.menu_book_outlined),
                onPressed: widget.onOpenGlossaries,
              ),
            PopupMenuButton<_MenuAction>(
              key: const Key('presets_menu'),
              tooltip: l10n.commonMoreOptions,
              onSelected: (action) => unawaited(_onMenu(action)),
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: _MenuAction.import,
                  child: ListTile(
                    leading: const Icon(Icons.file_download_outlined),
                    title: Text(l10n.presetsImport),
                  ),
                ),
                PopupMenuItem(
                  value: _MenuAction.export,
                  enabled: state.presets.isNotEmpty,
                  child: ListTile(
                    leading: const Icon(Icons.file_upload_outlined),
                    title: Text(l10n.presetsExport),
                  ),
                ),
                PopupMenuItem(
                  value: _MenuAction.restoreExamples,
                  child: ListTile(
                    leading: const Icon(Icons.auto_awesome_outlined),
                    title: Text(l10n.presetsRestoreExamples),
                  ),
                ),
              ],
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          key: const Key('presets_add'),
          onPressed: () => unawaited(showPresetEditor(context)),
          icon: const Icon(Icons.add),
          label: Text(l10n.presetsNew),
        ),
        body: LayoutBuilder(
          builder: (context, constraints) {
            final padding = centeredPadding(
              constraints.maxWidth,
              maxWidth: 760,
              bottom: 96,
            );
            if (state.status == PresetsStatus.failure &&
                state.presets.isEmpty) {
              return PresetsMessage(
                icon: Icons.error_outline,
                title: l10n.presetsLoadFailed,
                action: FilledButton.tonal(
                  onPressed: () => unawaited(_cubit.load()),
                  child: Text(l10n.commonRetry),
                ),
              );
            }
            if (state.presets.isEmpty &&
                (state.status == PresetsStatus.initial ||
                    state.status == PresetsStatus.loading)) {
              return const Center(child: CircularProgressIndicator());
            }
            if (presets.isEmpty) {
              return PresetsMessage(
                icon: Icons.tune,
                title: l10n.presetsEmptyTitle,
                body: l10n.presetsEmptyBody,
                action: FilledButton.tonalIcon(
                  key: const Key('presets_restore_examples'),
                  onPressed: () => unawaited(_restoreExamples()),
                  icon: const Icon(Icons.auto_awesome_outlined),
                  label: Text(l10n.presetsRestoreExamples),
                ),
              );
            }
            return ReorderableListView.builder(
              key: const Key('presets_list'),
              buildDefaultDragHandles: false,
              padding: padding,
              header: _Intro(text: l10n.presetsIntro),
              itemCount: presets.length,
              onReorderItem: (from, to) {
                // Indexes refer to the visible list; map them back.
                final all = state.presets;
                unawaited(
                  _cubit.move(
                    all.indexOf(presets[from]),
                    all.indexOf(presets[to]),
                  ),
                );
              },
              itemBuilder: (context, index) {
                final preset = presets[index];
                return _PresetTile(
                  key: ValueKey(preset.id),
                  preset: preset,
                  index: index,
                  count: presets.length,
                  isDefault: preset.id == state.defaultId,
                  onTap: () => _onAction(_PresetAction.edit, preset, index),
                  onAction: (action) =>
                      _onAction(action, preset, state.presets.indexOf(preset)),
                  onDismissed: () => _delete(preset),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _Intro extends StatelessWidget {
  const new({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 16),
      child: Text(
        text,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _PresetTile extends StatelessWidget {
  const new({
    required this.preset,
    required this.index,
    required this.count,
    required this.isDefault,
    required this.onTap,
    required this.onAction,
    required this.onDismissed,
    super.key,
  });

  final Preset preset;
  final int index;
  final int count;
  final bool isDefault;
  final VoidCallback onTap;
  final ValueChanged<_PresetAction> onAction;
  final VoidCallback onDismissed;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final name = l10n.presetName(preset);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Dismissible(
        key: ValueKey('dismiss-${preset.id}'),
        direction: DismissDirection.endToStart,
        onDismissed: (_) => onDismissed(),
        background: Container(
          alignment: AlignmentDirectional.centerEnd,
          padding: const EdgeInsetsDirectional.only(end: 24),
          decoration: BoxDecoration(
            color: colors.errorContainer,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Icon(Icons.delete_outline, color: colors.onErrorContainer),
        ),
        child: Card.filled(
          margin: EdgeInsets.zero,
          color: colors.surfaceContainerLow,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: ListTile(
            minTileHeight: 72,
            contentPadding: const EdgeInsetsDirectional.only(start: 4, end: 4),
            onTap: onTap,
            leading: ReorderableDragStartListener(
              index: index,
              child: Semantics(
                container: true,
                label: l10n.presetsReorderHint(name),
                child: const SizedBox(
                  width: 48,
                  height: 48,
                  child: Icon(Icons.drag_indicator),
                ),
              ),
            ),
            title: Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(name, style: theme.textTheme.titleMedium),
                if (isDefault) _DefaultBadge(label: l10n.presetsDefaultBadge),
              ],
            ),
            subtitle: Text(
              l10n.presetSummary(preset.options),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: PopupMenuButton<_PresetAction>(
              tooltip: l10n.presetsActionsTooltip(name),
              onSelected: onAction,
              itemBuilder: (context) => [
                _item(
                  _PresetAction.edit,
                  Icons.edit_outlined,
                  l10n.presetsEdit,
                ),
                _item(
                  _PresetAction.toggleDefault,
                  isDefault ? Icons.star_rounded : Icons.star_outline_rounded,
                  isDefault
                      ? l10n.presetsRemoveDefault
                      : l10n.presetsSetDefault,
                ),
                _item(
                  _PresetAction.duplicate,
                  Icons.copy_all_outlined,
                  l10n.presetsDuplicate,
                ),
                _item(
                  _PresetAction.share,
                  Icons.share_outlined,
                  l10n.presetsShareOne,
                ),
                if (index > 0)
                  _item(
                    _PresetAction.moveUp,
                    Icons.arrow_upward,
                    l10n.presetsMoveUp,
                  ),
                if (index < count - 1)
                  _item(
                    _PresetAction.moveDown,
                    Icons.arrow_downward,
                    l10n.presetsMoveDown,
                  ),
                _item(
                  _PresetAction.delete,
                  Icons.delete_outline,
                  l10n.commonDelete,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static PopupMenuItem<_PresetAction> _item(
    _PresetAction value,
    IconData icon,
    String label,
  ) => PopupMenuItem(
    value: value,
    child: ListTile(leading: Icon(icon), title: Text(label)),
  );
}

class _DefaultBadge extends StatelessWidget {
  const new({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      key: const Key('presets_default_badge'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.star_rounded, size: 14, color: colors.onPrimaryContainer),
          const SizedBox(width: 4),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: colors.onPrimaryContainer,
            ),
          ),
        ],
      ),
    );
  }
}
