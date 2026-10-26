import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';

/// "2 items kept on this device": how many items of personal data the
/// personal data shield replaced before the text left the device
/// (`TranslationResult.maskedPersonalData`), like the translate screen's
/// note, for results shown elsewhere (photos, documents). Screen readers
/// also hear what that means. Nothing when [count] is 0.
class PersonalDataKeptNote extends StatelessWidget {
  const new({required this.count, super.key});

  final int count;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final muted = AppPalette.of(context).secondaryText;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: MergeSemantics(
        child: Semantics(
          hint: l10n.translatePersonalDataKeptHint,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsetsDirectional.only(top: 1, end: 6),
                child: ExcludeSemantics(
                  child: Icon(Icons.shield_outlined, size: 16, color: muted),
                ),
              ),
              Expanded(
                child: Text(
                  l10n.translatePersonalDataKept(count),
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
