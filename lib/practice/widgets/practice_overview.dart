import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/phrasebook/models/phrase_collection.dart';
import 'package:mozhi/practice/cubit/practice_cubit.dart';
import 'package:mozhi/practice/cubit/practice_speech_cubit.dart';
import 'package:mozhi/practice/data/fsrs.dart';
import 'package:mozhi/practice/data/practice_repository.dart';
import 'package:mozhi/practice/models/practice_card.dart';
import 'package:mozhi/practice/models/practice_settings.dart';
import 'package:mozhi/practice/widgets/practice_texts.dart';
import 'package:mozhi/settings/view/widgets/empty_state_view.dart';
import 'package:mozhi/voice/widgets/voice_input_button.dart'
    show VoiceInputButton;

/// The practice overview of the [PracticeCubit] above it: what is due and
/// Start; the collections practised (unless the page practises one), the
/// card directions, new cards per day, the desired retention, typed
/// answers and speaking practice; and Export to Anki ([onExport]).
/// Without any phrase, a way to the phrasebook ([phrasebookLocation]).
///
/// On wide screens (from 840 dp) the settings sit beside the summary.
class PracticeOverview extends StatelessWidget {
  const new({
    required this.onExport,
    this.phrasebookLocation = defaultPhrasebookLocation,
    super.key,
  });

  /// The phrasebook screen (contract: `/phrasebook`).
  static const defaultPhrasebookLocation = '/phrasebook';

  final VoidCallback onExport;
  final String phrasebookLocation;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final deck = context.select<PracticeCubit, PracticeDeck?>(
      (cubit) => cubit.state.deck,
    );
    if (deck == null) return const Center(child: CircularProgressIndicator());
    if (deck.collections.isEmpty) {
      return EmptyStateView(
        icon: Icons.school_outlined,
        title: l10n.practiceEmptyTitle,
        body: l10n.practiceEmptyBody,
        action: FilledButton(
          key: const Key('practice_open_phrasebook'),
          onPressed: () => unawaited(context.push<void>(phrasebookLocation)),
          child: Text(l10n.practiceOpenPhrasebook),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 840;
        const summary = _Summary();
        final options = _Options(onExport: onExport);
        if (wide) {
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1100),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Expanded(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.all(24),
                      child: summary,
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      children: [options],
                    ),
                  ),
                ],
              ),
            ),
          );
        }
        return ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: summary,
                    ),
                    options,
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// What is due, and Start.
class _Summary extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final cubit = context.watch<PracticeCubit>();
    final deck = cubit.state.deck!;
    final now = DateTime.now();
    final due = deck.due(now).length;
    final fresh = deck.newCards().length;
    final nothing = due + fresh == 0;
    final next = deck.nextDue(now);
    final only = cubit.onlyCollection;
    final collection = only == null
        ? null
        : deck.collections.where((c) => c.id == only).firstOrNull;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (collection != null) ...[
              Text(
                practiceCollectionName(l10n, collection),
                style: theme.textTheme.titleMedium?.copyWith(
                  color: colors.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
            ],
            Semantics(
              header: true,
              child: Text(
                nothing ? l10n.practiceCaughtUp : l10n.practiceOverviewDue(due),
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              nothing && next != null
                  ? l10n.practiceNextDue(
                      practiceIntervalText(l10n, next.difference(now)),
                    )
                  : l10n.practiceOverviewNew(fresh),
              style: theme.textTheme.bodyLarge?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const Key('practice_start'),
                style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
                onPressed: nothing
                    ? null
                    : () => unawaited(context.read<PracticeCubit>().start()),
                icon: const Icon(Icons.play_arrow_rounded),
                label: Text(l10n.practiceStart),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The collections, directions and settings, speaking practice and the
/// export.
class _Options extends StatelessWidget {
  const new({required this.onExport});

  final VoidCallback onExport;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final cubit = context.watch<PracticeCubit>();
    final state = cubit.state;
    final deck = state.deck!;
    final settings = state.settings;
    void update(PracticeSettings next) => unawaited(cubit.updateSettings(next));
    Widget header(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Semantics(
        header: true,
        child: Text(
          text,
          style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (cubit.onlyCollection == null) ...[
          header(l10n.practiceCollectionsTitle),
          for (final collection in deck.collections)
            _CollectionTile(
              collection: collection,
              size: deck.collectionSizes[collection.id] ?? 0,
              selected: settings.includes(collection.id),
              onChanged: (selected) => update(
                _withCollection(deck, settings, collection.id, selected),
              ),
            ),
        ],
        header(l10n.practiceDirectionsTitle),
        for (final direction in CardDirection.values)
          CheckboxListTile(
            key: ValueKey('practice_direction_${direction.name}'),
            value: settings.directions.contains(direction),
            title: Text(switch (direction) {
              CardDirection.recognize => l10n.practiceDirectionRecognize,
              CardDirection.produce => l10n.practiceDirectionProduce,
            }),
            subtitle: Text(switch (direction) {
              CardDirection.recognize =>
                l10n.practiceDirectionRecognizeSubtitle,
              CardDirection.produce => l10n.practiceDirectionProduceSubtitle,
            }),
            // At least one direction stays.
            onChanged:
                settings.directions.contains(direction) &&
                    settings.directions.length == 1
                ? null
                : (on) => update(
                    settings.copyWith(
                      directions: on ?? false
                          ? {...settings.directions, direction}
                          : ({...settings.directions}..remove(direction)),
                    ),
                  ),
          ),
        header(l10n.practiceSettingsTitle),
        _SliderTile(
          key: const Key('practice_new_per_day'),
          title: l10n.practiceNewPerDay,
          value: settings.newCardsPerDay.toDouble(),
          min: 0,
          max: PracticeSettings.maxNewCardsPerDay.toDouble(),
          divisions: PracticeSettings.maxNewCardsPerDay ~/ 5,
          format: (value) =>
              NumberFormat.decimalPattern(l10n.localeName)
                  .format(value.round()),
          onChanged: (value) =>
              update(settings.copyWith(newCardsPerDay: value.round())),
        ),
        _SliderTile(
          key: const Key('practice_retention'),
          title: l10n.practiceRetention,
          subtitle: l10n.practiceRetentionSubtitle,
          value: settings.desiredRetention,
          min: FsrsScheduler.minDesiredRetention,
          max: FsrsScheduler.maxDesiredRetention,
          divisions:
              ((FsrsScheduler.maxDesiredRetention -
                          FsrsScheduler.minDesiredRetention) *
                      100)
                  .round(),
          format: (value) =>
              NumberFormat.percentPattern(l10n.localeName).format(value),
          onChanged: (value) => update(
            settings.copyWith(
              desiredRetention: (value * 100).roundToDouble() / 100,
            ),
          ),
        ),
        SwitchListTile(
          key: const Key('practice_type_answers'),
          value: settings.typeAnswers,
          title: Text(l10n.practiceTypeAnswers),
          subtitle: Text(l10n.practiceTypeAnswersSubtitle),
          onChanged: (value) => update(settings.copyWith(typeAnswers: value)),
        ),
        const _SpeakingTile(),
        const Divider(height: 24),
        ListTile(
          key: const Key('practice_export'),
          leading: const Icon(Icons.ios_share),
          title: Text(l10n.practiceExport),
          onTap: onExport,
        ),
      ],
    );
  }

  /// [settings] with [id] practised or not ([PracticeSettings
  /// .collectionIds] null again once all are).
  static PracticeSettings _withCollection(
    PracticeDeck deck,
    PracticeSettings settings,
    String id,
    bool selected,
  ) {
    final all = {for (final collection in deck.collections) collection.id};
    final current = {...settings.collectionIds ?? all};
    if (selected) {
      current.add(id);
    } else {
      current.remove(id);
    }
    final everything = all.every(current.contains);
    return settings.copyWith(collectionIds: () => everything ? null : current);
  }
}

class _CollectionTile extends StatelessWidget {
  const new({
    required this.collection,
    required this.size,
    required this.selected,
    required this.onChanged,
  });

  final PhraseCollection collection;
  final int size;
  final bool selected;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final pair = practicePairText(collection, uiLocale: l10n.localeName);
    return CheckboxListTile(
      key: ValueKey('practice_collection_${collection.id}'),
      value: selected,
      secondary: Icon(
        collection.isFavorites
            ? Icons.favorite_outline
            : collection.starter
            ? Icons.travel_explore_outlined
            : Icons.collections_bookmark_outlined,
      ),
      title: Text(practiceCollectionName(l10n, collection)),
      subtitle: Text([l10n.practiceCollectionPhrases(size), ?pair].join(' · ')),
      onChanged: (value) => onChanged(value ?? false),
    );
  }
}

/// A slider setting that is stored when let go (not at every step).
class _SliderTile extends StatefulWidget {
  const new({
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.format,
    required this.onChanged,
    this.subtitle,
    super.key,
  });

  final String title;
  final String? subtitle;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String Function(double value) format;
  final ValueChanged<double> onChanged;

  @override
  State<_SliderTile> createState() => _SliderTileState();
}

class _SliderTileState extends State<_SliderTile> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final value = (_dragging ?? widget.value).clamp(widget.min, widget.max);
    final shown = widget.format(value);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(widget.title, style: theme.textTheme.titleMedium),
              ),
              ExcludeSemantics(
                child: Text(
                  shown,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          if (widget.subtitle case final subtitle?)
            Text(
              subtitle,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          Slider(
            value: value,
            min: widget.min,
            max: widget.max,
            divisions: widget.divisions,
            label: shown,
            semanticFormatterCallback: widget.format,
            onChanged: (value) => setState(() => _dragging = value),
            onChangeEnd: (value) {
              setState(() => _dragging = null);
              if (value != widget.value) widget.onChanged(value);
            },
          ),
        ],
      ),
    );
  }
}

/// Whether speaking practice runs here, and the way to a speech model.
class _SpeakingTile extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final status = context.select<PracticeSpeechCubit, PracticeSpeechStatus>(
      (cubit) => cubit.state.status,
    );
    if (status == PracticeSpeechStatus.checking) return const SizedBox();
    final missing = status == PracticeSpeechStatus.modelMissing;
    return ListTile(
      key: const Key('practice_speaking'),
      leading: Icon(
        status == PracticeSpeechStatus.unsupported
            ? Icons.mic_off_outlined
            : Icons.mic_none_outlined,
      ),
      title: Text(l10n.practiceSpeakingTitle),
      subtitle: Text(switch (status) {
        PracticeSpeechStatus.unsupported => l10n.practiceSpeakingUnsupported,
        PracticeSpeechStatus.modelMissing => l10n.practiceSpeakingModelMissing,
        _ => l10n.practiceSpeakingReady,
      }),
      isThreeLine: true,
      trailing: missing
          ? TextButton(
              key: const Key('practice_voice_settings'),
              onPressed: () async {
                final speech = context.read<PracticeSpeechCubit>();
                await context.push<void>(VoiceInputButton.settingsLocation);
                // A model may have been downloaded meanwhile.
                await speech.load();
              },
              child: Text(l10n.practiceVoiceSettings),
            )
          : null,
    );
  }
}
