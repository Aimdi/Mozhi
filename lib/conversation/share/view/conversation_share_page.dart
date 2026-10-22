import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/conversation/cubit/conversation_cubit.dart';
import 'package:mozhi/conversation/share/cubit/conversation_share_cubit.dart';
import 'package:mozhi/conversation/share/data/share_room.dart';
import 'package:mozhi/conversation/share/data/share_translations.dart';
import 'package:mozhi/conversation/share/widgets/conversation_share_guard.dart';
import 'package:mozhi/core/qr/qr_code_view.dart';
import 'package:mozhi/core/widgets/consent_prompt.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/platform/clipboard_service.dart';

/// What the sharing page needs from the conversation it shares: pass it as
/// the navigation's `extra` ([openConversationShare] does).
class ConversationShareLaunch {
  const new({required this.share, required this.conversation});

  final ConversationShareCubit share;
  final ConversationCubit conversation;
}

/// Opens the sharing page of the conversation above [context] (at
/// [AppRoutes.conversationShare] with a [GoRouter], else on the
/// navigator).
Future<void> openConversationShare(BuildContext context) async {
  final launch = ConversationShareLaunch(
    share: context.read<ConversationShareCubit>(),
    conversation: context.read<ConversationCubit>(),
  );
  final router = GoRouter.maybeOf(context);
  if (router != null) {
    await router.push<void>(AppRoutes.conversationShare, extra: launch);
    return;
  }
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ConversationSharePage(launch: launch),
    ),
  );
}

/// **Share on this network**: the QR code and link guests on the same
/// Wi-Fi open, the PIN, the guests and their languages, and Stop. Starts
/// sharing when it opens (see [ConversationShareCubit]).
class ConversationSharePage extends StatelessWidget {
  const new({required this.launch, super.key});

  /// The page for the navigation's [extra] (a [ConversationShareLaunch]);
  /// an empty page for anything else (the router sends a link without
  /// one to the conversation).
  static Widget fromExtra(Object? extra) => extra is ConversationShareLaunch
      ? ConversationSharePage(launch: extra)
      : const Scaffold(body: SizedBox.shrink());

  final ConversationShareLaunch launch;

  @override
  Widget build(BuildContext context) => MultiBlocProvider(
    providers: [
      BlocProvider<ConversationShareCubit>.value(value: launch.share),
      BlocProvider<ConversationCubit>.value(value: launch.conversation),
    ],
    child: const ConversationShareView(),
  );
}

/// The sharing page of the [ConversationShareCubit] above it.
class ConversationShareView extends StatefulWidget {
  const new({super.key});

  /// From this width the code sits beside the details.
  static const double wideBreakpoint = 840;

  @override
  State<ConversationShareView> createState() => _ConversationShareViewState();
}

class _ConversationShareViewState extends State<ConversationShareView> {
  @override
  void initState() {
    super.initState();
    final cubit = context.read<ConversationShareCubit>();
    if (!cubit.state.isActive) unawaited(cubit.start());
  }

  Future<void> _stop() async {
    final navigator = Navigator.of(context);
    await context.read<ConversationShareCubit>().stop();
    if (mounted && navigator.canPop()) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<ConversationShareCubit>().state;
    final cubit = context.read<ConversationShareCubit>();
    final Widget body = switch (state.status) {
      ConversationShareStatus.starting => _Message(
        key: const Key('conversation_share_starting'),
        icon: null,
        title: l10n.conversationShareStarting,
      ),
      ConversationShareStatus.noNetwork => _Message(
        key: const Key('conversation_share_no_network'),
        icon: Icons.wifi_off,
        title: l10n.conversationShareNoNetworkTitle,
        body: l10n.conversationShareNoNetwork,
        action: l10n.commonRetry,
        onAction: () => unawaited(cubit.start()),
      ),
      ConversationShareStatus.failed => _Message(
        key: const Key('conversation_share_failed'),
        icon: Icons.error_outline,
        title: l10n.conversationShareFailed,
        action: l10n.commonRetry,
        onAction: () => unawaited(cubit.start()),
      ),
      ConversationShareStatus.idle => _Message(
        key: const Key('conversation_share_stopped'),
        icon: Icons.wifi_tethering_off,
        title: l10n.conversationShareStopped,
        action: l10n.conversationShareAgain,
        onAction: () => unawaited(cubit.start()),
      ),
      ConversationShareStatus.live => _Live(state: state, onStop: _stop),
    };
    return ConversationShareGuard(
      child: Scaffold(
        appBar: AppBar(title: Text(l10n.conversationShareTitle)),
        body: SafeArea(top: false, child: body),
      ),
    );
  }
}

/// A centred status: starting (a spinner), no network, failed, stopped.
class _Message extends StatelessWidget {
  const new({
    required this.icon,
    required this.title,
    this.body,
    this.action,
    this.onAction,
    super.key,
  });

  final IconData? icon;
  final String title;
  final String? body;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon = this.icon;
    final body = this.body;
    final action = this.action;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon == null)
                const CircularProgressIndicator()
              else
                Icon(icon, size: 48, color: theme.colorScheme.primary),
              const SizedBox(height: 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
              if (body != null) ...[
                const SizedBox(height: 8),
                Text(
                  body,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
              ],
              if (action != null) ...[
                const SizedBox(height: 16),
                FilledButton(onPressed: onAction, child: Text(action)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The live sharing: code and link, then PIN, guests, languages, replies,
/// the privacy note and Stop.
class _Live extends StatelessWidget {
  const new({required this.state, required this.onStop});

  final ConversationShareState state;
  final Future<void> Function() onStop;

  @override
  Widget build(BuildContext context) {
    final url = state.url.toString();
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide =
            constraints.maxWidth >= ConversationShareView.wideBreakpoint;
        final codeSize = (wide ? 320.0 : constraints.maxWidth - 80).clamp(
          160.0,
          320.0,
        );
        final code = _CodeCard(url: url, size: codeSize);
        final details = _Details(state: state, onStop: onStop);
        if (wide) {
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1040),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(padding: const EdgeInsets.all(24), child: code),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(0, 16, 24, 24),
                      children: [details],
                    ),
                  ),
                ],
              ),
            ),
          );
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(children: [code, details]),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The QR code, what to do with it and the link.
class _CodeCard extends StatelessWidget {
  const new({required this.url, required this.size});

  final String url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: size + 48),
      child: Column(
        children: [
          QrCodeView(
            key: const Key('conversation_share_qr'),
            data: url,
            semanticLabel: l10n.conversationShareQrLabel,
            size: size,
          ),
          const SizedBox(height: 12),
          Text(
            l10n.conversationShareScan,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Semantics(
                  label: l10n.conversationShareLink,
                  child: SelectableText(
                    url,
                    key: const Key('conversation_share_link'),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ),
              IconButton(
                key: const Key('conversation_share_copy'),
                tooltip: l10n.conversationShareCopyLink,
                icon: const Icon(Icons.content_copy_outlined),
                onPressed: () => unawaited(_copy(context)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _copy(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final message = context.l10n.commonCopied;
    await copyText(url);
    if (systemShowsCopyConfirmation) return;
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _Details extends StatelessWidget {
  const new({required this.state, required this.onStop});

  final ConversationShareState state;
  final Future<void> Function() onStop;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final cubit = context.read<ConversationShareCubit>();
    final palette = AppPalette.of(context);
    final pin = state.pin;
    final heading = theme.textTheme.titleSmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        SwitchListTile(
          key: const Key('conversation_share_pin_switch'),
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.conversationSharePinSwitch),
          value: pin != null,
          onChanged: (value) => cubit.setPinRequired(required: value),
        ),
        if (pin != null)
          Semantics(
            container: true,
            label: l10n.conversationSharePin(pin.split('').join(' ')),
            excludeSemantics: true,
            child: Text(
              l10n.conversationSharePin(pin),
              key: const Key('conversation_share_pin'),
              style: theme.textTheme.headlineMedium?.copyWith(
                letterSpacing: 4,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        if (state.locked) ...[
          const SizedBox(height: 8),
          _Note(
            icon: Icons.lock_outline,
            text: l10n.conversationShareLocked,
            color: theme.colorScheme.error,
          ),
        ],
        const SizedBox(height: 16),
        Text(
          l10n.conversationShareGuests(state.guests.length),
          key: const Key('conversation_share_guest_count'),
          style: heading,
        ),
        if (state.guests.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final guest in state.guests) _GuestChip(guest: guest),
            ],
          ),
        ],
        if (state.languages.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(l10n.conversationShareLanguages, style: heading),
          const SizedBox(height: 4),
          Text(
            l10n.conversationShareLanguagesHint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: palette.secondaryText,
            ),
          ),
          for (final language in state.languages)
            _LanguageRow(
              language: language,
              engineName: state.engineName,
              onGranted: () => cubit.retryLanguage(language.language),
            ),
        ],
        const SizedBox(height: 8),
        SwitchListTile(
          key: const Key('conversation_share_replies_switch'),
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.conversationShareReplies),
          subtitle: Text(l10n.conversationShareRepliesHint),
          value: state.repliesAllowed,
          onChanged: (value) => cubit.setRepliesAllowed(allowed: value),
        ),
        const SizedBox(height: 8),
        _Note(
          icon: Icons.shield_outlined,
          text: l10n.conversationSharePrivacyNote,
        ),
        const SizedBox(height: 8),
        _Note(icon: Icons.info_outline, text: l10n.conversationShareFromNow),
        const SizedBox(height: 24),
        Center(
          child: FilledButton.tonalIcon(
            key: const Key('conversation_share_stop'),
            onPressed: () => unawaited(onStop()),
            icon: const Icon(Icons.stop_circle_outlined),
            label: Text(l10n.conversationShareStop),
          ),
        ),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  const new({required this.icon, required this.text, this.color});

  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = this.color ?? AppPalette.of(context).secondaryText;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.only(top: 2, end: 12),
          child: Icon(icon, size: 20, color: color),
        ),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}

class _GuestChip extends StatelessWidget {
  const new({required this.guest});

  final ShareGuest guest;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final label =
        '${l10n.conversationShareGuestLabel(guest.number)} · '
        '${guest.language.name}';
    return Semantics(
      container: true,
      label: guest.connected ? label : l10n.conversationShareGuestAway(label),
      excludeSemantics: true,
      child: Chip(
        key: Key('conversation_share_guest_${guest.number}'),
        avatar: Icon(
          guest.connected ? Icons.person_outline : Icons.wifi_off,
          size: 18,
        ),
        label: Text(label),
      ),
    );
  }
}

/// How one extra language reaches its guests; asks for consent when the
/// host's engine may not be sent it.
class _LanguageRow extends StatelessWidget {
  const new({
    required this.language,
    required this.engineName,
    required this.onGranted,
  });

  final ShareLanguageState language;
  final String? engineName;
  final VoidCallback onGranted;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final name = language.language.name;
    final consent = language.consent;
    final text = switch (language.mode) {
      ShareLanguageMode.engine => l10n.conversationShareLanguageEngine(
        name,
        engineName ?? '',
      ),
      ShareLanguageMode.onDevice => l10n.conversationShareLanguageOnDevice(
        name,
      ),
      ShareLanguageMode.unavailable =>
        l10n.conversationShareLanguageUnavailable(name),
      ShareLanguageMode.needsConsent => l10n.conversationShareLanguageConsent(
        name,
      ),
    };
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(text, style: theme.textTheme.bodyMedium),
          if (language.mode == ShareLanguageMode.needsConsent &&
              consent != null) ...[
            const SizedBox(height: 8),
            ConsentInlinePrompt(
              key: Key('conversation_share_consent_${language.language.code}'),
              consent: consent,
              requests: language.waiting < 1 ? 1 : language.waiting,
              onGranted: onGranted,
            ),
          ],
        ],
      ),
    );
  }
}
