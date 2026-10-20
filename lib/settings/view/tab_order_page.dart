import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/view/app_shell.dart' show AppDestination;
import 'package:mozhi/core/undo_snack_bar.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';

/// The order of the app's tabs (`AppSettings.tabOrder`, route
/// `/settings/tabs`): the four tabs in a reorderable list, each with a drag
/// handle and Move up / Move down buttons (the alternative to dragging for
/// keyboards, switch access and single taps, WCAG 2.5.7), and Reset in the
/// app bar (undoable). Screen readers also get the list's own move
/// actions. The app opens on the first tab.
///
/// Reads [SettingsCubit] from the app-wide providers.
class TabOrderPage extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) => const TabOrderView();
}

class TabOrderView extends StatelessWidget {
  const new({super.key});

  /// Key of the Reset action.
  static const resetKey = Key('tab_order_reset');

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<SettingsCubit>();
    final order = context.select<SettingsCubit, List<AppTab>>(
      (cubit) => cubit.state.tabOrder,
    );
    final isDefault = listEquals(order, AppTab.values);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.settingsTabOrder),
        actions: [
          IconButton(
            key: resetKey,
            tooltip: l10n.settingsTabOrderReset,
            icon: const Icon(Icons.restore),
            onPressed: isDefault ? null : () => _reset(context),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) => ReorderableListView.builder(
          buildDefaultDragHandles: false,
          padding: centeredPadding(constraints.maxWidth),
          header: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 16, 16),
            child: Text(
              l10n.settingsTabOrderHint,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: AppPalette.of(context).secondaryText),
            ),
          ),
          itemCount: order.length,
          onReorderItem: cubit.moveTab,
          itemBuilder: (context, index) => _TabTile(
            key: ValueKey(order[index]),
            tab: order[index],
            index: index,
            count: order.length,
            onMove: (to) => cubit.moveTab(index, to),
          ),
        ),
      ),
    );
  }

  void _reset(BuildContext context) {
    final cubit = context.read<SettingsCubit>();
    final previous = cubit.state.tabOrder;
    cubit.resetTabOrder();
    showUndoSnackBar(
      context,
      message: context.l10n.settingsTabOrderResetDone,
      onUndo: () => cubit.setTabOrder(previous),
    );
  }
}

/// One tab: its drag handle, icon and name ("Opens when the app starts"
/// under the first one) and the move buttons, which go on a line of their
/// own when the name would not fit beside them (narrow screens, large
/// text).
class _TabTile extends StatelessWidget {
  const new({
    required this.tab,
    required this.index,
    required this.count,
    required this.onMove,
    super.key,
  });

  final AppTab tab;
  final int index;
  final int count;

  /// Moves the tab to the given position.
  final ValueChanged<int> onMove;

  /// Width of the move buttons.
  static const _buttonsWidth = 96.0;

  /// Width of the tab's icon and the gap after it.
  static const _iconWidth = 36.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final destination = AppDestination.of(tab);
    final name = destination.label(l10n);
    final nameStyle = theme.textTheme.bodyLarge;
    final label = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(destination.icon, color: palette.secondaryText),
        const SizedBox(width: _iconWidth - 24),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(name, style: nameStyle),
              if (index == 0)
                Text(
                  l10n.settingsTabOrderFirst,
                  key: const Key('tab_order_first'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: palette.secondaryText,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
    // The enabled arrows in the text colour, so the disabled ones (at the
    // ends of the list) stand out from them in both themes.
    final onSurface = theme.colorScheme.onSurface;
    final arrowStyle = IconButton.styleFrom(
      foregroundColor: onSurface,
      disabledForegroundColor: onSurface.withValues(alpha: 0.38),
    );
    final buttons = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: Key('tab_order_up_${tab.name}'),
          tooltip: l10n.settingsTabOrderMoveUp(name),
          style: arrowStyle,
          icon: const Icon(Icons.arrow_upward),
          onPressed: index > 0 ? () => onMove(index - 1) : null,
        ),
        IconButton(
          key: Key('tab_order_down_${tab.name}'),
          tooltip: l10n.settingsTabOrderMoveDown(name),
          style: arrowStyle,
          icon: const Icon(Icons.arrow_downward),
          onPressed: index < count - 1 ? () => onMove(index + 1) : null,
        ),
      ],
    );
    return Material(
      type: MaterialType.transparency,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            ReorderableDragStartListener(
              index: index,
              child: Semantics(
                label: l10n.settingsTabOrderDragHandle,
                child: Tooltip(
                  message: l10n.settingsTabOrderDragHandle,
                  excludeFromSemantics: true,
                  child: SizedBox.square(
                    dimension: 48,
                    child: Icon(
                      Icons.drag_indicator,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final nameWidth = _textWidth(context, name, nameStyle);
                  final fits =
                      _iconWidth + nameWidth + 8 + _buttonsWidth <=
                      constraints.maxWidth;
                  if (fits) {
                    return Row(
                      children: [
                        Expanded(child: label),
                        buttons,
                      ],
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: label,
                        ),
                      ),
                      Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: buttons,
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The width of [text] on one line in [style], at the current text size.
  static double _textWidth(
    BuildContext context,
    String text,
    TextStyle? style,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }
}
