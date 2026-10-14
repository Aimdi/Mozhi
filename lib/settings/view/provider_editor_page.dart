import 'dart:async';

import 'package:flutter/semantics.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/core/widgets/local_overlay.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/view/widgets/add_instance_dialog.dart';
import 'package:mozhi/settings/view/widgets/insecure_http_warning.dart';
import 'package:mozhi/settings/view/widgets/link_launcher.dart';
import 'package:mozhi/settings/view/widgets/model_picker_sheet.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';
import 'package:mozhi/usage/usage.dart';
import 'package:translation_repository/translation_repository.dart';

/// Create or edit an AI provider or a machine translation service (DeepL,
/// LibreTranslate).
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

/// Readable name of a machine translation [service]; null for
/// [MtService.llm].
String? mtServiceName(AppLocalizations l10n, MtService service) =>
    switch (service) {
      MtService.llm => null,
      MtService.deepl => l10n.settingsProviderServiceDeepl,
      MtService.libreTranslate => l10n.settingsProviderServiceLibreTranslate,
    };

/// Readable name of a [PromptProfile]. [PromptProfile.auto] includes the
/// profile it resolves to for [model], e.g. "Automatic (TranslateGemma)".
String promptProfileName(
  AppLocalizations l10n,
  PromptProfile profile, {
  String model = '',
}) => switch (profile) {
  PromptProfile.auto => l10n.settingsProviderPromptAuto(
    promptProfileName(l10n, PromptProfile.detect(model)),
  ),
  PromptProfile.general => l10n.settingsProviderPromptGeneral,
  PromptProfile.translateGemma => l10n.settingsProviderPromptTranslateGemma,
  PromptProfile.hunyuanMt => l10n.settingsProviderPromptHunyuanMt,
};

/// The [UsageTracker] provided above [context], or null when the app runs
/// without usage tracking (e.g. in some tests).
UsageTracker? _usageTrackerOf(BuildContext context) {
  try {
    return context.read<UsageTracker>();
  } on ProviderNotFoundException {
    return null;
  }
}

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
  final _nameFocus = FocusNode();
  final _baseUrlFocus = FocusNode();
  final _apiKeyFocus = FocusNode();
  final _modelFocus = FocusNode();

  /// The plain-http base URL the user agreed to use without encryption.
  String? _insecureConfirmedFor;

  AiProviderConfig? _existing;
  AiProviderPreset? _preset;
  UsageTracker? _usageTracker;
  bool _notFound = false;
  LlmProvider _provider = LlmProvider.openAiCompatible;

  /// [MtService.llm] for AI providers; DeepL or LibreTranslate otherwise.
  /// Fixed for the lifetime of the editor (from the provider or preset).
  MtService _service = MtService.llm;
  PromptProfile _promptProfile = PromptProfile.auto;
  String _effort = _defaultEffort;
  double? _temperature;
  double _lastTemperature = 0.3;
  bool _supportsVision = false;
  bool _obscureKey = true;
  bool _loadingModels = false;
  String? _modelsError;
  _TestResult? _test;

  bool get _isNew => _existing == null;

  /// Whether this is a machine translation service (no model, prompts,
  /// effort, temperature or vision).
  bool get _isMt => _service != MtService.llm;

  /// DeepL picks the official API from the key when the URL is empty.
  bool get _urlOptional => _service == MtService.deepl;

  /// DeepL needs only a key (the URL is optional), so the key comes first.
  bool get _keyFirst => _service == MtService.deepl;

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
      _usageTracker = _usageTrackerOf(context);
      final preset = existing.presetId == null
          ? null
          : AiProviderPreset.byId(existing.presetId!);
      // A preset of another kind (e.g. an AI preset id on a DeepL
      // provider) must not supply key rules, links or headers.
      _preset = preset?.service == existing.service ? preset : null;
      _service = existing.service;
      _promptProfile = existing.promptProfile;
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
        _service = preset.service;
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
    _nameFocus.dispose();
    _baseUrlFocus.dispose();
    _apiKeyFocus.dispose();
    _modelFocus.dispose();
    super.dispose();
  }

  void _onFieldChanged() => setState(() {});

  bool get _apiKeyRequired => switch (_service) {
    MtService.deepl => true,
    MtService.libreTranslate => false,
    MtService.llm =>
      _preset?.requiresApiKey ??
          (_provider == LlmProvider.anthropic ||
              _provider == LlmProvider.gemini),
  };

  bool get _showTemperature => _provider != LlmProvider.anthropic;

  bool get _insecure => isInsecureHttp(Uri.tryParse(_baseUrl.text.trim()));

  static String _hostOf(String url) =>
      (Uri.tryParse(url.trim())?.host ?? '').toLowerCase();

  /// Headers the preset adds for its own service (e.g. OpenRouter's
  /// `HTTP-Referer` and `X-Title`) that must not follow the provider to
  /// another host (they identify the app to whoever runs that server).
  Map<String, String> get _presetHeadersDropped {
    final preset = _preset;
    if (preset == null || preset.headers.isEmpty) return const {};
    final host = _hostOf(_baseUrl.text);
    if (host.isEmpty || host == _hostOf(preset.baseUrl)) return const {};
    return preset.headers;
  }

  Map<String, String> get _headers {
    final preset = _preset;
    final headers = _existing?.headers ?? preset?.headers ?? const {};
    final dropped = _presetHeadersDropped;
    if (dropped.isNotEmpty) {
      return {
        for (final MapEntry(:key, :value) in headers.entries)
          if (!dropped.containsKey(key)) key: value,
      };
    }
    // Back on the preset's own host: its headers apply again.
    if (preset != null && preset.headers.isNotEmpty) {
      return {...preset.headers, ...headers};
    }
    return headers;
  }

  String? _required(String? value) => (value == null || value.trim().isEmpty)
      ? context.l10n.settingsProviderRequired
      : null;

  String? _validateUrl(String? value) {
    final l10n = context.l10n;
    final text = value?.trim() ?? '';
    if (text.isEmpty) {
      // DeepL without a URL uses the official API (chosen from the key).
      return _urlOptional ? null : l10n.settingsProviderRequired;
    }
    final uri = Uri.tryParse(text);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return l10n.settingsProviderUrlInvalid;
    }
    // Secrets in the URL would be stored in plain preferences and shown in
    // errors; keys belong in the API key field (secure storage).
    return switch (urlSecretProblem(text)) {
      UrlSecretProblem.credentials => l10n.settingsProviderUrlCredentials,
      UrlSecretProblem.query => l10n.settingsProviderUrlQuery,
      null => null,
    };
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
      // Machine translation services have no model settings.
      effort: _isMt || _effort == _defaultEffort ? null : _effort,
      temperature: !_isMt && _showTemperature ? _temperature : null,
      headers: _headers,
      enabled: existing?.enabled ?? true,
      supportsVision: !_isMt && _supportsVision,
      // Kept from the provider or preset: dropping it would silently turn
      // a DeepL or LibreTranslate service into an AI provider.
      service: _service,
      promptProfile: _promptProfile,
    );
  }

  void _close() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/settings/providers');
    }
  }

  /// Validates the form. On failure, focuses the first invalid field and
  /// announces that the form needs fixing (WCAG 3.3.1, 4.1.3).
  bool _validate() {
    if (_formKey.currentState?.validate() ?? false) return true;
    // In the order of the fields on screen.
    final fields = [
      (_nameFocus, _required(_name.text)),
      if (_keyFirst) ...[
        (_apiKeyFocus, _validateKey(_apiKey.text)),
        (_baseUrlFocus, _validateUrl(_baseUrl.text)),
      ] else ...[
        (_baseUrlFocus, _validateUrl(_baseUrl.text)),
        (_apiKeyFocus, _validateKey(_apiKey.text)),
      ],
      if (!_isMt) (_modelFocus, _required(_model.text)),
    ];
    for (final (focus, error) in fields) {
      if (error != null) {
        focus.requestFocus();
        break;
      }
    }
    unawaited(
      SemanticsService.sendAnnouncement(
        View.of(context),
        context.l10n.settingsProviderFixErrors,
        Directionality.of(context),
      ),
    );
    return false;
  }

  /// Plain http to a non-local host sends the text (and API key) readable
  /// by anyone on the way, so it needs an explicit confirmation once per
  /// URL before anything is saved or sent.
  Future<bool> _confirmInsecure() async {
    if (!_insecure) return true;
    final url = _normalizedBaseUrl();
    if (_insecureConfirmedFor == url) return true;
    final l10n = context.l10n;
    final host = Uri.tryParse(url)?.host ?? url;
    final hasKey = _apiKey.text.trim().isNotEmpty;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.no_encryption_outlined),
        title: Text(l10n.settingsProviderInsecureConfirmTitle),
        content: Text(
          hasKey
              ? l10n.settingsProviderInsecureConfirmBodyKey(host)
              : l10n.settingsProviderInsecureConfirmBody(host),
        ),
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
            child: Text(l10n.settingsProviderInsecureConfirmAction),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false) || !mounted) return false;
    _insecureConfirmedFor = url;
    return true;
  }

  Future<void> _save() async {
    if (!_validate()) return;
    if (!await _confirmInsecure() || !mounted) return;
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
    // Its usage counters and budget go with it (best effort).
    _usageTracker?.removeProvider(existing.id).ignore();
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(l10n.settingsProviderDeleted)));
    _close();
  }

  Future<void> _testConnection() async {
    if (!_validate()) return;
    if (!await _confirmInsecure() || !mounted) return;
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
    final title = switch ((_isMt, _isNew)) {
      (true, true) => l10n.settingsProviderMtNewTitle,
      (true, false) => l10n.settingsProviderMtEditTitle,
      (false, true) => l10n.settingsProviderNewTitle,
      (false, false) => l10n.settingsProviderEditTitle,
    };
    final urlField = _buildUrlField(context);
    final keyField = _buildKeyField(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
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
                focusNode: _nameFocus,
                textInputAction: TextInputAction.next,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  labelText: l10n.settingsProviderName,
                  border: const OutlineInputBorder(),
                ),
                validator: _required,
              ),
              const SizedBox(height: 16),
              if (mtServiceName(l10n, _service) case final service?)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.translate),
                  title: Text(service),
                  subtitle: Text(l10n.settingsProvidersPresetsMt),
                )
              else
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
              if (_keyFirst) keyField else urlField,
              const SizedBox(height: 16),
              if (_keyFirst) urlField else keyField,
              if (!_isMt) ..._buildModelFields(context),
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
              if ((_existing, _usageTracker) case (
                final existing?,
                final tracker?,
              )) ...[
                const SizedBox(height: 24),
                UsageCard(
                  providerId: existing.id,
                  tracker: tracker,
                  onShowAll: () => unawaited(context.push(AppRoutes.usage)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// The base URL with its notes: one list child, so showing or hiding the
  /// notes doesn't shift (and rebuild) the fields below.
  Widget _buildUrlField(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          controller: _baseUrl,
          focusNode: _baseUrlFocus,
          keyboardType: TextInputType.url,
          autocorrect: false,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: switch (_service) {
              MtService.llm => l10n.settingsProviderBaseUrl,
              MtService.deepl => l10n.settingsProviderServerUrlOptional,
              MtService.libreTranslate => l10n.settingsProviderServerUrl,
            },
            helperText: switch (_service) {
              MtService.llm => null,
              MtService.deepl => l10n.settingsProviderDeeplUrlHelper,
              MtService.libreTranslate => l10n.settingsProviderLibreUrlHelper,
            },
            helperMaxLines: 3,
            border: const OutlineInputBorder(),
            errorMaxLines: 4,
          ),
          validator: _validateUrl,
        ),
        if (_insecure)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: InsecureHttpWarning(
              key: const Key('provider_insecure_warning'),
              title: l10n.settingsProviderInsecureTitle,
              text: l10n.settingsProviderInsecureWarning,
            ),
          ),
        if (_presetHeadersDropped case final dropped when dropped.isNotEmpty)
          _Note(
            icon: Icons.info_outline,
            text: l10n.settingsProviderPresetHeadersDropped(
              _preset!.name,
              dropped.keys.join(', '),
            ),
          ),
      ],
    );
  }

  /// The API key and the preset's "Get an API key" link.
  Widget _buildKeyField(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          controller: _apiKey,
          focusNode: _apiKeyFocus,
          obscureText: _obscureKey,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.visiblePassword,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: _apiKeyRequired
                ? l10n.settingsProviderApiKey
                : l10n.settingsProviderApiKeyOptional,
            helperText: _service == MtService.libreTranslate
                ? l10n.settingsProviderLibreKeyHelper
                : l10n.settingsProviderKeyStorage,
            helperMaxLines: 3,
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
      ],
    );
  }

  /// Model, effort, temperature, prompt style and vision (AI providers
  /// only).
  List<Widget> _buildModelFields(BuildContext context) {
    final l10n = context.l10n;
    final model = _model.text.trim();
    return [
      const SizedBox(height: 16),
      TextFormField(
        controller: _model,
        focusNode: _modelFocus,
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
              ? SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    semanticsLabel: l10n.settingsProviderModelsLoading,
                  ),
                )
              : const Icon(Icons.list_alt_outlined),
          label: Text(l10n.settingsProviderBrowseModels),
        ),
      ),
      if (_modelsError case final error?)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Semantics(
            container: true,
            liveRegion: true,
            child: Text(
              error,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ),
      if (_suggestedModels case final models when models.isNotEmpty)
        _SuggestedModels(
          models: models,
          selected: model,
          onSelected: (chosen) => setState(() => _model.text = chosen),
        ),
      const SizedBox(height: 16),
      DropdownButtonFormField<String>(
        initialValue: _efforts.contains(_effort) ? _effort : _defaultEffort,
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
        onChanged: (value) => setState(() => _effort = value ?? _defaultEffort),
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
      const SizedBox(height: 16),
      // One list child for the selector and its note (see the URL field).
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<PromptProfile>(
            key: const Key('provider_prompt_profile'),
            initialValue: _promptProfile,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: l10n.settingsProviderPromptStyle,
              helperText: l10n.settingsProviderPromptStyleHelper,
              helperMaxLines: 3,
              border: const OutlineInputBorder(),
            ),
            items: [
              for (final profile in PromptProfile.values)
                DropdownMenuItem(
                  value: profile,
                  child: Text(
                    promptProfileName(l10n, profile, model: model),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (value) => setState(() {
              _promptProfile = value ?? PromptProfile.auto;
              _test = null;
            }),
          ),
          if (_promptProfile.resolve(model).isTranslationOnly)
            _Note(
              icon: Icons.info_outline,
              text: l10n.settingsProviderPromptTranslationOnly,
            ),
        ],
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(l10n.settingsProviderVision),
        subtitle: Text(l10n.settingsProviderVisionSubtitle),
        value: _supportsVision,
        onChanged: (value) => setState(() => _supportsVision = value),
      ),
    ];
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

/// A small informational line under a field.
class _Note extends StatelessWidget {
  const new({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Semantics(
              container: true,
              liveRegion: true,
              child: Text(
                text,
                style: theme.textTheme.bodySmall?.copyWith(color: color),
              ),
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
                  // The app theme hides checkmarks; the fill alone is too
                  // faint to show the selection (WCAG 1.4.1, 1.4.11).
                  showCheckmark: true,
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
                // The slider's own overlay keeps its value indicator's
                // empty semantics node off the rest of the page (see
                // LocalOverlay); MergeSemantics folds it into the slider.
                child: MergeSemantics(
                  child: Semantics(
                    label: l10n.settingsProviderTemperature,
                    child: LocalOverlay(
                      child: Slider(
                        value: current.clamp(0, 2),
                        max: 2,
                        divisions: 20,
                        label: current.toStringAsFixed(1),
                        semanticFormatterCallback: (v) => v.toStringAsFixed(1),
                        onChanged: onChanged,
                      ),
                    ),
                  ),
                ),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 40),
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
    if (icon == null) {
      return LinearProgressIndicator(
        semanticsLabel: l10n.settingsProviderTesting,
      );
    }
    return Semantics(
      container: true,
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
