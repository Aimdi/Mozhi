import 'package:material_ui/material_ui.dart';

/// Placeholder; replaced by the owning feature agent.
class ProviderEditorPage extends StatelessWidget {
  const ProviderEditorPage({super.key, this.providerId, this.presetId});

  /// Edit an existing provider (null = create new).
  final String? providerId;

  /// Preset to prefill a new provider from.
  final String? presetId;

  @override
  Widget build(BuildContext context) => const Scaffold();
}
