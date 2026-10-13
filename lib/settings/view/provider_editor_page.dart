import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/view/widgets/add_instance_dialog.dart';
import 'package:mozhi/settings/view/widgets/link_launcher.dart';
import 'package:mozhi/settings/view/widgets/model_picker_sheet.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';
import 'package:translation_repository/translation_repository.dart';

/// Create or edit an AI provider.
class ProviderEditorPage extends StatelessWidget {
  const new({super.key, this.providerId, this.presetId});

  /// Edit an existing provider (null = create new).
  final String? providerId;

  /// Preset to prefill a new provider from.
  final String? presetId;

  @override
  Widget build(BuildContext context) =>
      ProviderEditorView(providerId: providerId, presetId: presetId);
}

/// Readable name of an [LlmProvider].
String llmProviderName(AppLocalizations l10n, LlmProvider provider) =>
    switch (provider) {
      LlmProvider.openAiCompatible => l10n.settingsProviderTypeOpenAi,
      LlmProvider.anthropic => l10n.settingsProviderTypeAnthropic,
      LlmProvider.gemini => l10n.settingsProviderTypeGemini,
      LlmProvider.ollama => l10n.settingsProviderTypeOllama,
    };

/// Default API base URL per provider type.
String defaultBaseUrl(LlmProvider provider) => switch (provider) {
  LlmProvider.openAiCompatible => 'https://api.openai.com/v1',
  LlmProvider.anthropic => 'https://api.anthropic.com/v1',
  LlmProvider.gemini => 'https://generativelanguage.googleapis.com/v1beta',
  LlmProvider.ollama => 'http://localhost:11434',
};

class ProviderEditorView extends StatefulWidget {
  const new({super.key, this.providerId, this.presetId});

  final String? providerId;
  final String? presetId;

  @override
  State<ProviderEditorView> createState() => _ProviderEditorViewState();
}

sealed class _TestResult {
  const new();
}

class _TestRunning extends _TestResult {
  const new();
}

class _TestSuccess extends _TestResult {
  const new(this.output);
  final String output;
}

class _TestFailure extends _TestResult {
  const new(this.message);
  final String message;
}

class _ProviderEditorViewState extends State<ProviderEditorView> {
  static const _defaultEffort = '';
  static const List<String> _efforts = [
    _defaultEffort,
    'low',
    'medium',
    'high',
  ];

  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _baseUrl = TextEditingController();
  final _apiKey = TextEditingController();
  final _model = TextEditingController();

  AiProviderConfig? _existing;
  AiProviderPreset? _preset;
  bool _notFound = false;
  LlmProvider _provider = LlmProvider.openAiCompatible;
  String _effort = _defaultEffort;
  double? _temperature;
  double _lastTemperature = 0.3;
  bool _supportsVision = false;
  bool _obscureKey = true;
  bool _loadingModels = false;
  String? _modelsError;
  _TestResult? _test;

  bool get _isNew => _existing == null;

  @override
  void initState() {
    super.initState();
    final providerId = widget.providerId;
    if (providerId != null) {
      final existing = context
          .read<SettingsCubit>()
          .state
          .providers
          .where((p) => p.id == providerId)
          .firstOrNull;
      if (existing == null) {
        _notFound = true;
        return;
      }
      _existing = existing;
      _preset = existing.presetId == null
          ? null
          : AiProviderPreset.byId(existing.presetId!);
      _name.text = existing.name;
      _provider = existing.provider;
      _baseUrl.text = existing.baseUrl;
      _apiKey.text = existing.apiKey ?? '';
      _model.text = existing.model;
      _effort = existing.effort ?? _defaultEffort;
      _temperature = existing.temperature;
      _lastTemperature = existing.temperature ?? _lastTemperature;
      _supportsVision = existing.supportsVision;
    } else {
      final presetId = widget.presetId;
      final preset = presetId == null ? null : AiProviderPreset.byId(presetId);
      _preset = preset;
      if (preset != null) {
        _name.text = preset.name;
        _provider = preset.provider;
        _baseUrl.text = preset.baseUrl;
        _model.text = preset.defaultModel;
        _effort = preset.defaultEffort ?? _defaultEffort;
      } else {
        _baseUrl.text = defaultBaseUrl(_provider);
      }
    }
    _baseUrl.addListener(_onFieldChanged);
    _model.addListener(_onFieldChanged);
  }

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _apiKey.dispose();
    _model.dispose();
    super.dispose();
  }

  void _onFieldChanged() => setState(() {});

  bool get _apiKeyRequired =>
      _preset?.requiresApiKey ??
      (_provider == LlmProvider.anthropic || _provider == LlmProvider.gemini);

  bool get _showTemperature => _provider != LlmProvider.anthropic;

  bool get _insecure {
    final uri = Uri.tryParse(_baseUrl.text.trim());
    if (uri == null || uri.scheme != 'http' || uri.host.isEmpty) return false;
    return !AiProviderConfig.isLocalHost(uri.host);
  }

  String? _required(String? value) => (value == null || value.trim().isEmpty)
      ? context.l10n.settingsProviderRequired
      : null;

  String? _validateUrl(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return context.l10n.settingsProviderRequired;
    final uri = Uri.tryParse(text);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return context.l10n.settingsProviderUrlInvalid;
    }
    return null;
  }

  String? _validateKey(String? value) =>
      _apiKeyRequired ? _required(value) : null;

  void _setProvider(LlmProvider? provider) {
    if (provider == null || provider == _provider) return;
    setState(() {
      final current = _baseUrl.text.trim();
      if (current.isEmpty || current == defaultBaseUrl(_provider)) {
        _baseUrl.text = defaultBaseUrl(provider);
      }
      _provider = provider;
      _test = null;
    });
  }

  String _normalizedBaseUrl() {
    var url = _baseUrl.text.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  AiProviderConfig _buildConfig({String? id}) {
    final apiKey = _apiKey.text.trim();
    final existing = _existing;
    return AiProviderConfig(
      id: id ?? existing?.id ?? 'draft',
      name: _name.text.trim(),
      provider: _provider,
      baseUrl: _normalizedBaseUrl(),
      model: _model.text.trim(),
      apiKey: apiKey.isEmpty ? null : apiKey,
      presetId: existing?.presetId ?? _preset?.id,
      effort: _effort == _defaultEffort ? null : _effort,
      temperature: _showTemperature ? _temperature : null,
      headers: existing?.headers ?? _preset?.headers ?? const {},
      enabled: existing?.enabled ?? true,
      supportsVision: _supportsVision,
    );
  }

  void _close() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/settings/providers');
    }
  }

  void _save() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final config = _buildConfig(
      id: _existing?.id ?? 'p${DateTime.now().microsecondsSinceEpoch}',
    );
    context.read<SettingsCubit>().saveProvider(config);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(context.l10n.settingsProviderSaved)));
    _close();
  }

  Future<void> _delete() async {
    final existing = _existing;
    if (existing == null) return;
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.delete_outline),
        title: Text(l10n.settingsProviderDeleteTitle(existing.name)),
        content: Text(l10n.settingsProviderDeleteBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.commonDelete),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false) || !mounted) return;
    context.read<SettingsCubit>().removeProvider(existing.id);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(l10n.settingsProviderDeleted)));
    _close();
  }

  Future<void> _testConnection() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final repository = context.read<TranslationRepository>();
    setState(() => _test = const _TestRunning());
    _TestResult result;
    try {
      result = _TestSuccess(await repository.testProvider(_buildConfig()));
    } on Object catch (error) {
      result = _TestFailure(describeError(error));
    }
    if (mounted) setState(() => _test = result);
  }

  Future<void> _browseModels() async {
    final l10n = context.l10n;
    final repository = context.read<TranslationRepository>();
    setState(() {
      _loadingModels = true;
      _modelsError = null;
    });
    List<LlmModel> models;
    try {
      models = await repository.listModels(_buildConfig());
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _loadingModels = false;
          _modelsError = l10n.settingsProviderModelsFailed(
            describeError(error),
          );
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _loadingModels = false;
      _modelsError = models.isEmpty ? l10n.settingsProviderModelsEmpty : null;
    });
    if (models.isEmpty) return;
    final chosen = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) =>
          ModelPickerSheet(models: models, selected: _model.text.trim()),
    );
    if (chosen != null && mounted) {
      setState(() => _model.text = chosen);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (_notFound) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.settingsProviderEditTitle)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              l10n.settingsProviderNotFound,
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _isNew
              ? l10n.settingsProviderNewTitle
              : l10n.settingsProviderEditTitle,
        ),
        actions: [
          if (!_isNew)
            IconButton(
              tooltip: l10n.commonDelete,
              icon: const Icon(Icons.delete_outline),
              onPressed: _delete,
            ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) => Form(
          key: _formKey,
          child: ListView(
            padding: centeredPadding(constraints.maxWidth, maxWidth: 640),
            children: [
              const SizedBox(height: 8),
              TextFormField(
                controller: _name,
                textInputAction: TextInputAction.next,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  labelText: l10n.settingsProviderName,
                  border: const OutlineInputBorder(),
                ),
                validator: _required,
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<LlmProvider>(
                initialValue: _provider,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: l10n.settingsProviderType,
                  border: const OutlineInputBorder(),
                ),
                items: [
                  for (final provider in LlmProvider.values)
                    DropdownMenuItem(
                      value: provider,
                      child: Text(
                        llmProviderName(l10n, provider),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: _setProvider,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _baseUrl,
                keyboardType: TextInputType.url,
                autocorrect: false,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: l10n.settingsProviderBaseUrl,
                  border: const OutlineInputBorder(),
                  errorMaxLines: 3,
                ),
                validator: _validateUrl,
              ),
              if (_insecure)
                _InsecureWarning(text: l10n.settingsProviderInsecureWarning),
              const SizedBox(height: 16),
              TextFormField(
                controller: _apiKey,
                obscureText: _obscureKey,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.visiblePassword,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: _apiKeyRequired
                      ? l10n.settingsProviderApiKey
                      : l10n.settingsProviderApiKeyOptional,
                  helperText: l10n.settingsProviderKeyStorage,
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: _obscureKey
                        ? l10n.settingsProviderShowKey
                        : l10n.settingsProviderHideKey,
                    icon: Icon(
                      _obscureKey
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                    onPressed: () => setState(() => _obscureKey = !_obscureKey),
                  ),
                ),
                validator: _validateKey,
              ),
              if (_preset?.apiKeyUrl case final url?)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    onPressed: () => LinkLauncher.open(context, Uri.parse(url)),
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: Text(l10n.settingsProviderGetKey),
                  ),
                ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _model,
                autocorrect: false,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  labelText: l10n.settingsProviderModel,
                  border: const OutlineInputBorder(),
                ),
                validator: _required,
              ),
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: OutlinedButton.icon(
                  onPressed: _loadingModels ? null : _browseModels,
                  icon: _loadingModels
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.list_alt_outlined),
                  label: Text(l10n.settingsProviderBrowseModels),
                ),
              ),
              if (_modelsError case final error?)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    error,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: Theme.of(context).colorScheme.error),
                  ),
                ),
              if (_suggestedModels case final models when models.isNotEmpty)
                _SuggestedModels(
                  models: models,
                  selected: _model.text.trim(),
                  onSelected: (model) => setState(() => _model.text = model),
                ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _efforts.contains(_effort)
                    ? _effort
                    : _defaultEffort,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: l10n.settingsProviderEffort,
                  border: const OutlineInputBorder(),
                ),
                items: [
                  for (final effort in _efforts)
                    DropdownMenuItem(
                      value: effort,
                      child: Text(
                        _effortLabel(l10n, effort),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) =>
                    setState(() => _effort = value ?? _defaultEffort),
              ),
              if (_showTemperature) ...[
                const SizedBox(height: 8),
                _TemperatureField(
                  value: _temperature,
                  onUseDefault: ({required useDefault}) => setState(() {
                    _temperature = useDefault ? null : _lastTemperature;
                  }),
                  onChanged: (value) => setState(() {
                    _temperature = value;
                    _lastTemperature = value;
                  }),
                ),
              ],
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.settingsProviderVision),
                subtitle: Text(l10n.settingsProviderVisionSubtitle),
                value: _supportsVision,
                onChanged: (value) => setState(() => _supportsVision = value),
              ),
              const SizedBox(height: 16),
              if (_test case final test?) ...[
                _TestResultView(result: test),
                const SizedBox(height: 16),
              ],
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 12,
                runSpacing: 12,
                children: [
                  OutlinedButton.icon(
                    onPressed: _test is _TestRunning ? null : _testConnection,
                    icon: const Icon(Icons.network_check),
                    label: Text(l10n.settingsProviderTest),
                  ),
                  FilledButton.icon(
                    onPressed: _save,
                    icon: const Icon(Icons.check),
                    label: Text(l10n.commonSave),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<String> get _suggestedModels {
    final preset = _preset;
    if (preset == null || preset.provider != _provider) return const [];
    return {
      if (preset.defaultModel.isNotEmpty) preset.defaultModel,
      ...preset.suggestedModels,
    }.toList();
  }

  static String _effortLabel(AppLocalizations l10n, String effort) =>
      switch (effort) {
        'low' => l10n.settingsProviderEffortLow,
        'medium' => l10n.settingsProviderEffortMedium,
        'high' => l10n.settingsProviderEffortHigh,
        _ => l10n.settingsProviderEffortDefault,
      };
}

class _InsecureWarning extends StatelessWidget {
  const new({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, size: 20, color: colors.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.warning),
            ),
          ),
        ],
      ),
    );
  }
}

class _SuggestedModels extends StatelessWidget {
  const new({
    required this.models,
    required this.selected,
    required this.onSelected,
  });

  final List<String> models;
  final String selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.l10n.settingsProviderSuggestedModels,
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final model in models)
                ChoiceChip(
                  label: Text(model),
                  selected: model == selected,
                  onSelected: (_) => onSelected(model),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TemperatureField extends StatelessWidget {
  const new({
    required this.value,
    required this.onUseDefault,
    required this.onChanged,
  });

  final double? value;
  final void Function({required bool useDefault}) onUseDefault;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final current = value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(l10n.settingsProviderTemperature),
          subtitle: Text(l10n.settingsProviderTemperatureDefault),
          value: current == null,
          onChanged: (checked) => onUseDefault(useDefault: checked ?? false),
        ),
        if (current != null)
          Row(
            children: [
              Expanded(
                child: Slider(
                  value: current.clamp(0, 2),
                  max: 2,
                  divisions: 20,
                  label: current.toStringAsFixed(1),
                  semanticFormatterCallback: (v) => v.toStringAsFixed(1),
                  onChanged: onChanged,
                ),
              ),
              SizedBox(
                width: 40,
                child: Text(
                  current.toStringAsFixed(1),
                  textAlign: TextAlign.end,
                ),
              ),
            ],
          ),
      ],
    );
  }
}

class _TestResultView extends StatelessWidget {
  const new({required this.result});

  final _TestResult result;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final (icon, color, text) = switch (result) {
      _TestRunning() => (null, colors.onSurfaceVariant, ''),
      _TestSuccess(:final output) => (
        Icons.check_circle_outline,
        colors.success,
        l10n.settingsProviderTestOk(output),
      ),
      _TestFailure(:final message) => (
        Icons.error_outline,
        colors.error,
        l10n.settingsProviderTestFailed(message),
      ),
    };
    if (icon == null) return const LinearProgressIndicator();
    return Semantics(
      liveRegion: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: color),
              const SizedBox(width: 12),
              Expanded(
                child: SelectableText(
                  text,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
