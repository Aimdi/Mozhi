import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/core/widgets/consent_prompt.dart' show destinationLabel;
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:translation_repository/translation_repository.dart';

/// The translate screen's first-use hint, in one line under the prompt that
/// asks before text the device can't translate goes online
/// (`ConsentRequest.fromOnDevice`): "Download keeps your text on this
/// phone. Once sends only this text to Google via mozhi.example."
///
/// It shows until the user first answers such a prompt ([markSeen], called
/// when consent is given), remembered in the preferences ([store], default
/// the [KeyValueStore] provided above) under [storeKey]; without a store it
/// always shows. Shows nothing while the preference is read.
class TranslateFirstUseHint extends StatefulWidget {
  const new({required this.consent, this.store, super.key});

  /// The request the privacy settings stopped (names where it would go).
  final ConsentRequiredException consent;

  /// Where "seen" is remembered; defaults to the one provided above.
  final KeyValueStore? store;

  /// Preferences key (`seen` once the user answered a prompt); it goes with
  /// "Delete all local data".
  static const storeKey = 'translate.firstUseHint';

  static const _seen = 'seen';

  /// Remembers that the user answered (in [store], default the
  /// [KeyValueStore] above [context]); errors are ignored.
  static Future<void> markSeen(
    BuildContext context, {
    KeyValueStore? store,
  }) async {
    final target = store ?? _maybeStore(context);
    if (target == null) return;
    try {
      await target.write(storeKey, _seen);
    } on Object {
      // Shown again next time: harmless.
    }
  }

  static KeyValueStore? _maybeStore(BuildContext context) {
    try {
      return context.read<KeyValueStore>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  @override
  State<TranslateFirstUseHint> createState() => _TranslateFirstUseHintState();
}

class _TranslateFirstUseHintState extends State<TranslateFirstUseHint> {
  /// Whether to show it (null while the preference is read).
  bool? _show;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_show != null) return;
    final store = widget.store ?? TranslateFirstUseHint._maybeStore(context);
    if (store == null) {
      _show = true;
      return;
    }
    unawaited(_read(store));
  }

  Future<void> _read(KeyValueStore store) async {
    bool show;
    try {
      show =
          await store.read(TranslateFirstUseHint.storeKey) !=
          TranslateFirstUseHint._seen;
    } on Object {
      show = true;
    }
    if (mounted) setState(() => _show = show);
  }

  @override
  Widget build(BuildContext context) {
    if (_show != true) return const SizedBox.shrink();
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final muted = AppPalette.of(context).secondaryText;
    final consent = widget.consent;
    return Padding(
      key: const Key('translate_first_use_hint'),
      padding: const EdgeInsetsDirectional.only(top: 8, start: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.only(top: 2, end: 8),
            child: Icon(Icons.info_outline, size: 16, color: muted),
          ),
          Expanded(
            child: Text(
              l10n.translateFirstUseHint(
                l10n.offlineDownloadAction,
                l10n.commonConsentOnce,
                destinationLabel(
                  l10n,
                  consent.destination,
                  engineId: consent.engineId,
                ),
              ),
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ),
        ],
      ),
    );
  }
}
