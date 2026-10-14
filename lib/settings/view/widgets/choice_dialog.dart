import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';

/// One option of a [ChoiceDialog].
class ChoiceDialogOption<T> {
  const new({
    required this.value,
    required this.title,
    this.subtitle,
    this.secondary,
  });

  final T value;
  final Widget title;
  final Widget? subtitle;

  /// Shown at the end of the row, e.g. an icon.
  final Widget? secondary;
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
    super.key,
  });

  final String title;

  /// Explanation above the options.
  final String? body;

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
    return AlertDialog(
      title: Text(widget.title),
      scrollable: true,
      contentPadding: const EdgeInsets.only(top: 16),
      content: RadioGroup<T>(
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
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text(body),
              ),
            for (final option in widget.options)
              RadioListTile<T>(
                value: option.value,
                title: option.title,
                subtitle: option.subtitle,
                secondary: option.secondary,
              ),
          ],
        ),
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
}
