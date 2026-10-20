import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/privacy/ime_learning.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/usage/models/models.dart';
import 'package:mozhi/usage/widgets/usage_format.dart';

/// Result of [showUsageBudgetDialog]: the new monthly character budget, or
/// null `monthlyChars` to remove it.
typedef UsageBudgetChoice = ({int? monthlyChars});

/// Asks for a monthly character budget. Resolves to null when cancelled.
Future<UsageBudgetChoice?> showUsageBudgetDialog(
  BuildContext context, {
  UsageBudget? current,
}) => showDialog<UsageBudgetChoice>(
  context: context,
  builder: (context) => UsageBudgetDialog(current: current),
);

class UsageBudgetDialog extends StatefulWidget {
  const new({this.current, super.key});

  /// The budget being edited; null when none is set.
  final UsageBudget? current;

  @override
  State<UsageBudgetDialog> createState() => _UsageBudgetDialogState();
}

class _UsageBudgetDialogState extends State<UsageBudgetDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _controller = TextEditingController(
    text: widget.current?.monthlyChars.toString() ?? '',
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context)
        .pop<UsageBudgetChoice>((monthlyChars: int.parse(_controller.text)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final threshold =
        widget.current?.warningThreshold ?? UsageBudget.defaultWarningThreshold;
    return AlertDialog(
      title: Text(
        l10n.usageBudgetDialogTitle,
        style: Theme.of(context).textTheme.titleLarge,
      ),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.usageBudgetDialogBody(context.usagePercent(threshold)),
              style: TextStyle(color: AppPalette.of(context).secondaryText),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _controller,
              enableIMEPersonalizedLearning: imeLearningAllowed(context),
              autofocus: true,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: l10n.usageBudgetFieldLabel,
              ),
              validator: (value) {
                final chars = int.tryParse(value ?? '');
                return chars == null || chars <= 0
                    ? l10n.usageBudgetFieldInvalid
                    : null;
              },
              onFieldSubmitted: (_) => _save(),
            ),
          ],
        ),
      ),
      actions: [
        if (widget.current != null)
          TextButton(
            onPressed: () =>
                Navigator.of(context)
                    .pop<UsageBudgetChoice>((monthlyChars: null)),
            child: Text(l10n.usageBudgetRemove),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(onPressed: _save, child: Text(l10n.commonSave)),
      ],
    );
  }
}
