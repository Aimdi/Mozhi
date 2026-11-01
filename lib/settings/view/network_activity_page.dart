import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/network/network_session.dart';
import 'package:mozhi/core/privacy/egress/egress.dart';
import 'package:mozhi/core/widgets/app_bar_title.dart';
import 'package:mozhi/core/widgets/consent_prompt.dart' show upstreamEngineName;
import 'package:mozhi/core/widgets/decimal_format.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/platform/clipboard_service.dart'
    show systemShowsCopyConfirmation;
import 'package:mozhi/settings/view/widgets/delete_local_data.dart'
    show formatStoredSize;
import 'package:mozhi/settings/view/widgets/settings_section.dart';

/// Settings › Privacy › Network activity: where the app sent requests this
/// session, per destination and one by one, from the [EgressLedger] of
/// [NetworkSession.current] (or [ledger]). Nothing in it is stored.
class NetworkActivityPage extends StatelessWidget {
  const new({this.ledger, super.key});

  final EgressLedger? ledger;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) =>
          NetworkActivityCubit(ledger ?? NetworkSession.current.ledger),
      child: const NetworkActivityView(),
    );
  }
}

/// Builds the page from the [NetworkActivityCubit] above: the session's
/// headline, a summary per destination, the requests (newest first) and
/// what the log records. Side by side from [wideBreakpoint].
class NetworkActivityView extends StatelessWidget {
  const new({super.key});

  /// Width from which the summary and the requests are shown side by side.
  static const wideBreakpoint = 840.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<NetworkActivityCubit>().state;
    final hasEntries = state.entries.isNotEmpty || state.dropped > 0;
    return Scaffold(
      appBar: AppBar(
        title: AppBarTitle(l10n.settingsNetworkActivity),
        actions: [
          IconButton(
            key: const Key('network_activity_copy'),
            tooltip: l10n.settingsNetworkCopyTooltip,
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: () => unawaited(_copy(context, state)),
          ),
          IconButton(
            key: const Key('network_activity_clear'),
            tooltip: l10n.settingsNetworkClearTooltip,
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: hasEntries ? () => _clear(context) : null,
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final summary = [
            _Headline(state: state),
            if (state.summaries.isNotEmpty) ...[
              _SectionTitle(l10n.settingsNetworkDestinations),
              for (final summary in state.summaries) ...[
                _DestinationTile(summary: summary),
                const Hairline(),
              ],
            ],
          ];
          final log = [
            if (hasEntries) ...[
              _SectionTitle(l10n.settingsNetworkLog),
              if (state.dropped > 0)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    l10n.settingsNetworkDropped(state.dropped),
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: AppPalette.of(context).secondaryText),
                  ),
                ),
              for (final entry in state.entries) ...[
                _EntryTile(entry: entry),
                const Hairline(),
              ],
            ],
          ];
          const about = _AboutLog();
          if (constraints.maxWidth >= wideBreakpoint && hasEntries) {
            final gutter = math.max(0, (constraints.maxWidth - 1200) / 2);
            return Padding(
              padding: EdgeInsets.symmetric(horizontal: gutter.toDouble()),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: ListView(
                      key: const Key('network_activity_summary_pane'),
                      padding: const EdgeInsets.only(top: 8, bottom: 32),
                      children: [...summary, about],
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: ListView(
                      key: const Key('network_activity_log_pane'),
                      padding: const EdgeInsets.only(top: 8, bottom: 32),
                      children: log,
                    ),
                  ),
                ],
              ),
            );
          }
          // Rows run edge to edge on phones (their content keeps a 16 dp
          // inset); wide windows keep a centered column.
          final gutter = math.max(0, (constraints.maxWidth - 752) / 2);
          return ListView(
            key: const Key('network_activity_list'),
            padding: EdgeInsets.fromLTRB(
              gutter.toDouble(),
              8,
              gutter.toDouble(),
              32,
            ),
            children: [...summary, ...log, about],
          );
        },
      ),
    );
  }

  void _clear(BuildContext context) {
    context.read<NetworkActivityCubit>().clear();
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(context.l10n.settingsNetworkCleared)),
      );
  }

  Future<void> _copy(BuildContext context, NetworkActivityState state) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final text = networkActivitySummaryText(
      l10n,
      state,
      formatTime: (time) => formatActivityTime(context, time),
    );
    // Nothing private in it (no text, no addresses): the plain clipboard.
    await Clipboard.setData(ClipboardData(text: text));
    if (systemShowsCopyConfirmation) return;
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(l10n.commonCopied)));
  }
}

/// The plain-text summary that "Copy summary" puts on the clipboard: the
/// headline, one line per destination and what the log records.
String networkActivitySummaryText(
  AppLocalizations l10n,
  NetworkActivityState state, {
  required String Function(DateTime time) formatTime,
}) {
  final lines = [l10n.settingsNetworkCopyHeader(formatTime(state.since))];
  if (state.nothingLeft) {
    lines.add(l10n.settingsNetworkNothingTitle);
  }
  for (final summary in state.summaries) {
    final line = l10n.settingsNetworkCopyLine(
      egressDestinationTitle(summary.destination),
      egressKindLabel(l10n, summary.destination.kind),
      l10n.settingsNetworkRequestCount(summary.requests),
      l10n.settingsNetworkSent(formatStoredSize(l10n, summary.bytesSent)),
      l10n.settingsNetworkReceived(
        formatStoredSize(l10n, summary.bytesReceived),
      ),
      summary.receivedContent
          ? l10n.settingsNetworkContentSent
          : l10n.settingsNetworkNoContent,
    );
    lines.add('• $line');
  }
  if (state.dropped > 0) lines.add(l10n.settingsNetworkDropped(state.dropped));
  lines.add(l10n.settingsNetworkCopyFooter);
  return lines.join('\n');
}

/// [time] as a time of day ("9:41 AM"), with the date when it is not today.
String formatActivityTime(
  BuildContext context,
  DateTime time, {
  DateTime? now,
}) {
  final localizations = MaterialLocalizations.of(context);
  final clock = localizations.formatTimeOfDay(
    TimeOfDay.fromDateTime(time),
    alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
  );
  final today = now ?? DateTime.now();
  final sameDay =
      time.year == today.year &&
      time.month == today.month &&
      time.day == today.day;
  if (sameDay) return clock;
  return context.l10n.settingsNetworkDateTime(
    localizations.formatShortMonthDay(time),
    clock,
  );
}

/// The name a destination is shown with: the service's name, else its
/// host (and port).
String egressDestinationTitle(EgressDestination destination) =>
    destination.name ?? destination.authority;

/// The translation engine [entry] asked its server to use, by name
/// ("DuckDuckGo", "Google, DeepL"), or null when it named none
/// ([EgressEntry.engine]).
String? egressEngineLabel(EgressEntry entry) {
  final engine = entry.engine;
  if (engine == null || engine.isEmpty) return null;
  return engine.split(',').map(upstreamEngineName).join(', ');
}

/// "Cloud provider", "Your local network", ...
String egressKindLabel(
  AppLocalizations l10n,
  EgressDestinationKind kind,
) => switch (kind) {
  EgressDestinationKind.thisDevice => l10n.settingsNetworkKindThisDevice,
  EgressDestinationKind.localNetwork => l10n.settingsNetworkKindLocalNetwork,
  EgressDestinationKind.hiddenService => l10n.settingsNetworkKindHiddenService,
  EgressDestinationKind.cloudProvider => l10n.settingsNetworkKindCloudProvider,
  EgressDestinationKind.publicServer => l10n.settingsNetworkKindPublicServer,
  EgressDestinationKind.modelHost => l10n.settingsNetworkKindModelHost,
  EgressDestinationKind.website => l10n.settingsNetworkKindWebsite,
};

/// Who can read what a destination of [kind] receives, in plain language.
String egressKindDescription(
  AppLocalizations l10n,
  EgressDestinationKind kind,
) => switch (kind) {
  EgressDestinationKind.thisDevice => l10n.settingsNetworkKindThisDeviceBody,
  EgressDestinationKind.localNetwork =>
    l10n.settingsNetworkKindLocalNetworkBody,
  EgressDestinationKind.hiddenService =>
    l10n.settingsNetworkKindHiddenServiceBody,
  EgressDestinationKind.cloudProvider =>
    l10n.settingsNetworkKindCloudProviderBody,
  EgressDestinationKind.publicServer =>
    l10n.settingsNetworkKindPublicServerBody,
  EgressDestinationKind.modelHost => l10n.settingsNetworkKindModelHostBody,
  EgressDestinationKind.website => l10n.settingsNetworkKindWebsiteBody,
};

/// The icon of a destination of [kind] (as in the "who receives the text"
/// chips: a phone, a server, a globe, a cloud).
IconData egressKindIcon(EgressDestinationKind kind) => switch (kind) {
  EgressDestinationKind.thisDevice => Icons.phone_android,
  EgressDestinationKind.localNetwork => Icons.dns_outlined,
  EgressDestinationKind.hiddenService => Icons.vpn_lock_outlined,
  EgressDestinationKind.cloudProvider => Icons.cloud_outlined,
  EgressDestinationKind.publicServer => Icons.public,
  EgressDestinationKind.modelHost => Icons.download_outlined,
  EgressDestinationKind.website => Icons.language,
};

/// "Translation", "AI request", ...
String egressPurposeLabel(AppLocalizations l10n, EgressPurpose purpose) =>
    switch (purpose) {
      EgressPurpose.translation => l10n.settingsNetworkPurposeTranslation,
      EgressPurpose.aiModel => l10n.settingsNetworkPurposeAi,
      EgressPurpose.speech => l10n.settingsNetworkPurposeSpeech,
      EgressPurpose.image => l10n.settingsNetworkPurposeImage,
      EgressPurpose.catalog => l10n.settingsNetworkPurposeCatalog,
      EgressPurpose.modelDownload => l10n.settingsNetworkPurposeModel,
      EgressPurpose.webPage => l10n.settingsNetworkPurposeWebPage,
      EgressPurpose.sync => l10n.settingsNetworkPurposeSync,
      EgressPurpose.other => l10n.settingsNetworkPurposeOther,
    };

IconData egressPurposeIcon(EgressPurpose purpose) => switch (purpose) {
  EgressPurpose.translation => Icons.translate,
  EgressPurpose.aiModel => Icons.auto_awesome_outlined,
  EgressPurpose.speech => Icons.volume_up_outlined,
  EgressPurpose.image => Icons.image_outlined,
  EgressPurpose.catalog => Icons.list_alt_outlined,
  EgressPurpose.modelDownload => Icons.download_outlined,
  EgressPurpose.webPage => Icons.language,
  EgressPurpose.sync => Icons.cloud_sync_outlined,
  EgressPurpose.other => Icons.swap_vert,
};

/// How [entry] ended: "Answered (200)", "Error 401", "Timed out", ...
String egressStatusLabel(AppLocalizations l10n, EgressEntry entry) =>
    switch (entry.outcome) {
      EgressOutcome.pending => l10n.settingsNetworkStatusPending,
      EgressOutcome.succeeded => l10n.settingsNetworkStatusOk(
        entry.statusCode ?? 200,
      ),
      EgressOutcome.httpError => l10n.settingsNetworkStatusHttpError(
        entry.statusCode ?? 0,
      ),
      EgressOutcome.failed => switch (entry.failure) {
        EgressFailure.timeout => l10n.settingsNetworkStatusTimeout,
        EgressFailure.connection => l10n.settingsNetworkStatusConnection,
        EgressFailure.secureConnection =>
          l10n.settingsNetworkStatusSecureConnection,
        EgressFailure.other || null => l10n.settingsNetworkStatusFailed,
      },
      EgressOutcome.cancelled => l10n.settingsNetworkStatusCancelled,
      EgressOutcome.notSent => l10n.settingsNetworkStatusNotSent,
    };

/// "320 ms", "4.2 s".
String egressDurationLabel(AppLocalizations l10n, Duration duration) {
  final ms = duration.inMilliseconds;
  if (ms < 1000) return l10n.settingsNetworkDurationMs(ms);
  return l10n.settingsNetworkDurationSeconds(
    formatDecimal(ms / 1000, l10n.localeName),
  );
}

class _SectionTitle extends StatelessWidget {
  const new(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 24, 16, 8),
      child: Semantics(
        header: true,
        child: Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

/// "Nothing has left this device", or how many requests went out since the
/// log started and how many destinations got the user's text.
class _Headline extends StatelessWidget {
  const new({required this.state});

  final NetworkActivityState state;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = AppPalette.of(context);
    final since = formatActivityTime(context, state.since);
    final nothingLeft = state.nothingLeft;
    final onDevice = state.onDeviceRequestCount;
    final secondary = theme.textTheme.bodyLarge?.copyWith(
      color: palette.secondaryText,
    );

    final (icon, background, foreground) = nothingLeft
        ? (
            Icons.phonelink_lock_outlined,
            colors.primaryContainer,
            colors.onPrimaryContainer,
          )
        : (
            Icons.swap_vert,
            colors.secondaryContainer,
            colors.onSecondaryContainer,
          );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Semantics(
        container: true,
        explicitChildNodes: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ExcludeSemantics(
              child: SizedBox.square(
                dimension: 56,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: background,
                    shape: AppLook.of(context).isTerminal
                        ? BoxShape.rectangle
                        : BoxShape.circle,
                  ),
                  child: Icon(icon, size: 28, color: foreground),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Semantics(
              header: true,
              // Announced when the first request goes out (or on Clear).
              liveRegion: true,
              child: Text(
                nothingLeft
                    ? l10n.settingsNetworkNothingTitle
                    : l10n.settingsNetworkHeadline(state.requestCount, since),
                key: const Key('network_activity_headline'),
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  height: 1.2,
                ),
              ),
            ),
            const SizedBox(height: 8),
            if (nothingLeft)
              Text(l10n.settingsNetworkNothingBody(since), style: secondary)
            else ...[
              Text(
                l10n.settingsNetworkContentSummary(
                  state.contentDestinationCount,
                ),
                style: secondary,
              ),
              const SizedBox(height: 4),
              Text(
                l10n.settingsNetworkTotals(
                  formatStoredSize(l10n, state.bytesSent),
                  formatStoredSize(l10n, state.bytesReceived),
                ),
                style: secondary,
              ),
            ],
            if (onDevice > 0) ...[
              const SizedBox(height: 4),
              Text(
                l10n.settingsNetworkStayedOnDevice(onDevice),
                style: secondary,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One destination: its name and kind, what it received and who can read
/// it.
class _DestinationTile extends StatelessWidget {
  const new({required this.summary});

  final EgressDestinationSummary summary;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = AppPalette.of(context);
    final destination = summary.destination;
    final kind = egressKindLabel(l10n, destination.kind);
    final subtitle = destination.name == null
        ? kind
        : '$kind · ${destination.authority}';
    final small = theme.textTheme.bodySmall?.copyWith(
      color: palette.secondaryText,
    );
    final purposes = [
      for (final purpose in EgressPurpose.values)
        if (summary.purposes.contains(purpose))
          egressPurposeLabel(l10n, purpose),
    ].join(' · ');
    return MergeSemantics(
      child: Padding(
        key: Key('network_destination_${destination.authority}'),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: SettingsIcon(egressKindIcon(destination.kind)),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    egressDestinationTitle(destination),
                    style: theme.textTheme.titleMedium,
                  ),
                  Text(subtitle, style: small),
                  const SizedBox(height: 6),
                  Text(
                    [
                      l10n.settingsNetworkRequestCount(summary.requests),
                      l10n.settingsNetworkSent(
                        formatStoredSize(l10n, summary.bytesSent),
                      ),
                      l10n.settingsNetworkReceived(
                        formatStoredSize(l10n, summary.bytesReceived),
                      ),
                    ].join(' · '),
                    style: theme.textTheme.bodyMedium,
                  ),
                  if (purposes.isNotEmpty) Text(purposes, style: small),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      if (summary.receivedContent)
                        StatusBadge(
                          label: l10n.settingsNetworkContentSent,
                          color: colors.primary,
                          icon: Icons.text_snippet_outlined,
                        )
                      else
                        StatusBadge(
                          label: l10n.settingsNetworkNoContent,
                          color: colors.success,
                          icon: Icons.check,
                        ),
                      if (summary.viaProxy)
                        StatusBadge(
                          label: l10n.settingsNetworkViaProxy,
                          color: colors.tertiary,
                          icon: Icons.vpn_lock_outlined,
                        ),
                      if (summary.unencrypted)
                        StatusBadge(
                          label: l10n.settingsNetworkUnencrypted,
                          color: colors.warning,
                          icon: Icons.lock_open_outlined,
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    egressKindDescription(l10n, destination.kind),
                    style: small,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One request: when, where, why, how much and how it ended.
class _EntryTile extends StatelessWidget {
  const new({required this.entry});

  final EgressEntry entry;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = AppPalette.of(context);
    final small = theme.textTheme.bodySmall?.copyWith(
      color: palette.secondaryText,
    );
    final sent = entry.bytesSent;
    final details = [
      formatActivityTime(context, entry.startedAt),
      entry.method,
      if (sent != null) l10n.settingsNetworkSent(formatStoredSize(l10n, sent)),
      if (!entry.isPending || entry.bytesReceived > 0)
        l10n.settingsNetworkReceived(
          formatStoredSize(l10n, entry.bytesReceived),
        ),
      if (entry.duration case final duration?)
        egressDurationLabel(l10n, duration),
    ].join(' · ');
    final flags = [
      if (entry.viaProxy) l10n.settingsNetworkViaProxy,
      if (entry.scheme == 'http') l10n.settingsNetworkUnencrypted,
      if (entry.redirectedTo case final host?)
        l10n.settingsNetworkRedirected(host),
    ];
    final failed = switch (entry.outcome) {
      EgressOutcome.httpError || EgressOutcome.failed => true,
      _ => false,
    };
    final status = egressStatusLabel(l10n, entry);
    return MergeSemantics(
      child: Padding(
        key: Key('network_entry_${entry.id}'),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: SettingsIcon(egressPurposeIcon(entry.purpose)),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    egressDestinationTitle(entry.destination),
                    style: theme.textTheme.bodyLarge,
                  ),
                  Text(
                    [
                      egressPurposeLabel(l10n, entry.purpose),
                      egressKindLabel(l10n, entry.destination.kind),
                      if (egressEngineLabel(entry) case final engine?)
                        l10n.settingsNetworkEngine(engine),
                    ].join(' · '),
                    style: small,
                  ),
                  Text(details, style: small),
                  if (flags.isNotEmpty) Text(flags.join(' · '), style: small),
                ],
              ),
            ),
            const SizedBox(width: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 140),
              child: entry.isPending
                  ? Text(status, style: small, textAlign: TextAlign.end)
                  : StatusBadge(
                      label: status,
                      color: failed
                          ? colors.error
                          : entry.outcome == EgressOutcome.succeeded
                          ? colors.success
                          : palette.secondaryText,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What the log records and for how long, in plain language.
class _AboutLog extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final rows = [
      (Icons.fact_check_outlined, l10n.settingsNetworkAboutRecorded),
      (Icons.visibility_off_outlined, l10n.settingsNetworkAboutNotRecorded),
      (Icons.timer_outlined, l10n.settingsNetworkAboutSession),
      (Icons.block_outlined, l10n.settingsNetworkAboutRefused),
      if (defaultTargetPlatform == TargetPlatform.android && !kIsWeb)
        (Icons.text_fields, l10n.settingsNetworkAboutQuick),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle(l10n.settingsNetworkAboutTitle),
        for (final (icon, text) in rows)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExcludeSemantics(
                  child: Icon(icon, size: 20, color: palette.secondaryText),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    text,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: palette.secondaryText,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
