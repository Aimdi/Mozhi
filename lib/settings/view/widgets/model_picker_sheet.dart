import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:translation_repository/translation_repository.dart';

/// Searchable list of [models]; pops the chosen model id.
class ModelPickerSheet extends StatefulWidget {
  const new({required this.models, this.selected, super.key});

  final List<LlmModel> models;
  final String? selected;

  @override
  State<ModelPickerSheet> createState() => _ModelPickerSheetState();
}

class _ModelPickerSheetState extends State<ModelPickerSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final query = _query.trim().toLowerCase();
    final models = query.isEmpty
        ? widget.models
        : widget.models
              .where(
                (m) =>
                    m.id.toLowerCase().contains(query) ||
                    m.label.toLowerCase().contains(query),
              )
              .toList();
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      minChildSize: 0.4,
      builder: (context, controller) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              autofocus: widget.models.length > 8,
              decoration: InputDecoration(
                hintText: l10n.settingsProviderModelSearch,
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
          Expanded(
            child: models.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(l10n.settingsProviderModelsEmpty),
                    ),
                  )
                : ListView.builder(
                    controller: controller,
                    itemCount: models.length,
                    itemBuilder: (context, index) {
                      final model = models[index];
                      final selected = model.id == widget.selected;
                      return ListTile(
                        title: Text(model.label),
                        subtitle: model.label == model.id
                            ? null
                            : Text(model.id),
                        selected: selected,
                        trailing: selected ? const Icon(Icons.check) : null,
                        onTap: () => Navigator.of(context).pop(model.id),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
