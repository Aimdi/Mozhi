import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';

/// One option of a [ChoiceDialog].
class ChoiceDialogOption<T> {
  const new({
    required this.value,
    required this.title,
    this.subtitle,
    this.secondary,
    this.action,
  });

  final T value;
  final Widget title;
  final Widget? subtitle;

  /// Shown at the end of the row, e.g. an icon. It is merged into the
  /// option's semantics, so it must not be interactive (see [action]).
  final Widget? secondary;

  /// An interactive widget after the option, e.g. a preview button. It is
  /// kept out of the option's radio row, so screen readers, keyboards and
  /// switch access reach it on its own.
  final Widget? action;
}

/// Picks one of [options] with radio buttons, starting at [initialValue].
///
/// Choosing a radio only moves the selection; Save confirms it. Committing
/// on change would close the dialog on the first arrow key press, since the
/// arrow keys select the next radio of a group, so keyboard users could not
/// reach the options further down (WCAG 2.1.1, 3.2.2).
///
/// Pops the chosen value (which may be [initialValue]), or null when
/// cancelled.
class ChoiceDialog<T extends Object> extends StatefulWidget {
  const new({
    required this.title,
    required this.options,
    required this.initialValue,
    this.body,
    this.footer,
    super.key,
  });

  final String title;

  /// Explanation above the options.
  final String? body;

  /// Shown under the options and outside their scroll view, so it stays
  /// visible however far the options are scrolled (e.g. a status line).
  /// Scrolls on its own beyond a quarter of the screen height.
  final Widget? footer;

  final List<ChoiceDialogOption<T>> options;
  final T initialValue;

  /// Key of the Save action.
  static const saveKey = Key('choice_dialog_save');

  @override
  State<ChoiceDialog<T>> createState() => _ChoiceDialogState<T>();
}

class _ChoiceDialogState<T extends Object> extends State<ChoiceDialog<T>> {
  late T _value = widget.initialValue;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final body = widget.body;
    final footer = widget.footer;
    final options = RadioGroup<T>(
      groupValue: _value,
      onChanged: (value) {
        if (value != null) setState(() => _value = value);
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (body != null)
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(24, 0, 24, 8),
              child: Text(body),
            ),
          for (final option in widget.options) _option(option),
        ],
      ),
    );
    return AlertDialog(
      title: Text(widget.title),
      // With a footer, only the options scroll.
      scrollable: footer == null,
      contentPadding: const EdgeInsets.only(top: 16),
      content: footer == null
          ? options
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Flexible(child: SingleChildScrollView(child: options)),
                // At large text sizes a long footer scrolls on its own
                // rather than pushing the options and actions off screen.
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height / 4,
                  ),
                  child: SingleChildScrollView(child: footer),
                ),
              ],
            ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        TextButton(
          key: ChoiceDialog.saveKey,
          onPressed: () => Navigator.of(context).pop(_value),
          child: Text(l10n.commonSave),
        ),
      ],
    );
  }

  Widget _option(ChoiceDialogOption<T> option) {
    final action = option.action;
    final tile = RadioListTile<T>(
      value: option.value,
      title: option.title,
      subtitle: option.subtitle,
      secondary: option.secondary,
      contentPadding: action == null
          ? null
          : const EdgeInsetsDirectional.only(start: 16, end: 8),
    );
    if (action == null) return tile;
    // RadioListTile merges its whole row into one radio node, which would
    // swallow a button placed inside it: keep the action beside the tile.
    return Row(
      children: [
        Expanded(child: tile),
        Padding(
          padding: const EdgeInsetsDirectional.only(end: 12),
          child: action,
        ),
      ],
    );
  }
}
