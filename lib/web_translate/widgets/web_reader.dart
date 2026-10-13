import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/view/widgets/link_launcher.dart';
import 'package:mozhi/translate/widgets/output_card.dart';
import 'package:mozhi/web_translate/core/readable_extractor.dart';
import 'package:mozhi/web_translate/cubit/web_translate_cubit.dart';
import 'package:mozhi/web_translate/widgets/readable_block_view.dart';
import 'package:share_plus/share_plus.dart';

/// Sharing, replaceable in tests.
abstract final class WebTranslateShare {
  @visibleForTesting
  static Future<void> Function(ShareParams params) share = _share;

  static Future<void> _share(ShareParams params) async {
    await SharePlus.instance.share(params);
  }
}

/// The reader mode actually shown: side by side needs a wide window.
ReaderMode effectiveReaderMode(ReaderMode mode, {required bool wide}) =>
    mode == ReaderMode.sideBySide && !wide ? ReaderMode.translated : mode;

/// The loaded page as slivers: a header (title, source link, engine, mode
/// toggle, notices) followed by the blocks in the selected [ReaderMode].
class WebReaderSliver extends StatelessWidget {
  const new({required this.wide, super.key});

  /// Whether side by side is available.
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<WebTranslateCubit>().state;
    final page = state.page;
    if (page == null) return const SliverToBoxAdapter();
    final mode = effectiveReaderMode(state.mode, wide: wide);
    final selection = state.selection;
    final targetCode = selection == null || selection.target.isCustom
        ? null
        : selection.target.code;
    final source = selection?.source;
    final originalCode =
        state.detectedSource ??
        page.language ??
        (source == null || source.isAuto ? null : source.code);
    final translating = selection != null;

    Widget original(ReadableBlock block) => ReadableBlockView(
      block: block,
      text: block.text,
      languageCode: originalCode,
    );

    Widget translated(ReadableBlock block, String? translation) =>
        ReadableBlockView(
          block: block,
          text: translation ?? block.text,
          pending: translating && block.isTranslatable && translation == null,
          languageCode: translation == null ? originalCode : targetCode,
        );

    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: WebReaderHeader(mode: mode, wide: wide),
        ),
        SliverList.separated(
          itemCount: page.blocks.length,
          separatorBuilder: (context, index) => const SizedBox(height: 14),
          itemBuilder: (context, index) {
            final block = page.blocks[index];
            final translation = state.translationAt(index);
            return KeyedSubtree(
              key: ValueKey('web_translate_block_$index'),
              child: switch (mode) {
                ReaderMode.original => original(block),
                ReaderMode.translated => translated(block, translation),
                ReaderMode.sideBySide => Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: original(block)),
                    const SizedBox(width: 32),
                    Expanded(child: translated(block, translation)),
                  ],
                ),
              },
            );
          },
        ),
      ],
    );
  }
}

/// Title, source link, engine label, reader mode toggle and notices.
class WebReaderHeader extends StatelessWidget {
  const new({required this.mode, required this.wide, super.key});

  final ReaderMode mode;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final cubit = context.read<WebTranslateCubit>();
    final state = context.watch<WebTranslateCubit>().state;
    final page = state.page!;
    final uri = state.pageUri;
    final titleStyle = theme.textTheme.headlineSmall?.copyWith(
      fontWeight: FontWeight.w600,
    );

    Widget title(String text, {Key? key}) =>
        Text(text, key: key, style: titleStyle);

    final titles = switch (mode) {
      ReaderMode.original => title(
        page.title,
        key: const Key('web_translate_title'),
      ),
      ReaderMode.translated => title(
        state.displayTitle,
        key: const Key('web_translate_title'),
      ),
      ReaderMode.sideBySide => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: title(page.title)),
          const SizedBox(width: 32),
          Expanded(
            child: title(
              state.displayTitle,
              key: const Key('web_translate_title'),
            ),
          ),
        ],
      ),
    };
    final site = page.siteName ?? uri?.host ?? '';
    final engine = state.selection?.engine;

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (page.title.trim().isNotEmpty) titles,
          const SizedBox(height: 4),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            children: [
              if (uri != null)
                TextButton.icon(
                  key: const Key('web_translate_source_link'),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  onPressed: () => unawaited(LinkLauncher.open(context, uri)),
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: Text(
                    site.isEmpty ? uri.toString() : site,
                    semanticsLabel: '${l10n.webTranslateOpenOriginal}: $site',
                  ),
                ),
              if (engine != null && mode != ReaderMode.original)
                Text(
                  l10n.webTranslateTranslatedWith(engine.name),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          SegmentedButton<ReaderMode>(
            key: const Key('web_translate_mode_toggle'),
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: ReaderMode.translated,
                label: Text(l10n.webTranslateModeTranslated),
                icon: const Icon(Icons.translate),
              ),
              ButtonSegment(
                value: ReaderMode.original,
                label: Text(l10n.webTranslateModeOriginal),
                icon: const Icon(Icons.article_outlined),
              ),
              if (wide)
                ButtonSegment(
                  value: ReaderMode.sideBySide,
                  label: Text(l10n.webTranslateModeSideBySide),
                  icon: const Icon(Icons.vertical_split_outlined),
                ),
            ],
            selected: {mode},
            onSelectionChanged: (selected) => cubit.setMode(selected.first),
          ),
          if (state.truncated) ...[
            const SizedBox(height: 12),
            _Notice(l10n.webTranslateTruncated),
          ],
          if (state.unsupportedCharset case final charset?) ...[
            const SizedBox(height: 12),
            _Notice(l10n.webTranslateUnsupportedCharset(charset)),
          ],
          const SizedBox(height: 8),
          const Divider(),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const new(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.info_outline,
          size: 18,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

/// App bar actions for a loaded page: open the original, copy all, share.
class WebTranslateActions extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<WebTranslateCubit>().state;
    final uri = state.pageUri;
    if (!state.hasPage) return const SizedBox.shrink();
    final translated = state.mode != ReaderMode.original;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (uri != null)
          IconButton(
            key: const Key('web_translate_open_button'),
            tooltip: l10n.webTranslateOpenOriginal,
            icon: const Icon(Icons.open_in_browser),
            onPressed: () => unawaited(LinkLauncher.open(context, uri)),
          ),
        IconButton(
          key: const Key('web_translate_copy_button'),
          tooltip: l10n.webTranslateCopyAll,
          icon: const Icon(Icons.copy_all_outlined),
          onPressed: () => unawaited(
            copyToClipboard(context, state.plainText(translated: translated)),
          ),
        ),
        Builder(
          builder: (buttonContext) => IconButton(
            key: const Key('web_translate_share_button'),
            tooltip: l10n.commonShare,
            icon: const Icon(Icons.share_outlined),
            onPressed: () {
              final box = buttonContext.findRenderObject() as RenderBox?;
              final origin = box == null || !box.hasSize
                  ? null
                  : box.localToGlobal(Offset.zero) & box.size;
              final text = state.plainText(translated: translated);
              unawaited(
                WebTranslateShare.share(
                  ShareParams(
                    text: uri == null ? text : '$text\n\n$uri',
                    subject: translated
                        ? state.displayTitle
                        : state.page?.title,
                    sharePositionOrigin: origin,
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
