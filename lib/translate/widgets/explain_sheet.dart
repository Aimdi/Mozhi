import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/markdown_lite.dart';
import 'package:mozhi/translate/widgets/translate_error.dart';

/// Opens the streaming explanation of the current translation.
Future<void> showExplainSheet(BuildContext context) {
  final cubit = context.read<TranslateCubit>();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) =>
        BlocProvider.value(value: cubit, child: const ExplainSheet()),
  );
}

/// Shows `state.explanation` as it streams, with a follow-up question box.
class ExplainSheet extends StatefulWidget {
  const new({super.key});

  @override
  State<ExplainSheet> createState() => _ExplainSheetState();
}

class _ExplainSheetState extends State<ExplainSheet> {
  final _question = TextEditingController();
  String? _asked;

  @override
  void dispose() {
    _question.dispose();
    super.dispose();
  }

  void _send() {
    final question = _question.text.trim();
    if (question.isEmpty) return;
    setState(() => _asked = question);
    _question.clear();
    unawaited(context.read<TranslateCubit>().explain(question: question));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        minChildSize: 0.3,
        builder: (context, controller) =>
            BlocBuilder<TranslateCubit, TranslateState>(
              buildWhen: (previous, current) =>
                  previous.explanation != current.explanation ||
                  previous.explainStatus != current.explainStatus,
              builder: (context, state) {
                final loading = state.explainStatus == ExtraStatus.loading;
                return Column(
                  children: [
                    Expanded(
                      child: ListView(
                        controller: controller,
                        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  l10n.translateExplainTitle,
                                  style: theme.textTheme.titleLarge,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  l10n.translateAiGenerated,
                                  textAlign: TextAlign.end,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: muted,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if (_asked != null) ...[
                            const SizedBox(height: 12),
                            Text(
                              l10n.translateExplainYouAsked(_asked!),
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: muted,
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ],
                          const SizedBox(height: 16),
                          if (loading && state.explanation.isEmpty)
                            const LinearProgressIndicator(
                              key: Key('translate_explain_progress'),
                            ),
                          SelectionArea(child: MarkdownLite(state.explanation)),
                          if (loading && state.explanation.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            const Align(
                              alignment: AlignmentDirectional.centerStart,
                              child: SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            ),
                          ],
                          if (state.explainStatus == ExtraStatus.failure)
                            TranslateErrorView(
                              error: state.extraError,
                              dense: true,
                              onRetry: () => unawaited(
                                context.read<TranslateCubit>().explain(
                                  question: _asked,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              key: const Key('translate_explain_question'),
                              controller: _question,
                              textInputAction: TextInputAction.send,
                              onSubmitted: (_) => _send(),
                              minLines: 1,
                              maxLines: 4,
                              decoration: InputDecoration(
                                hintText: l10n.translateExplainFollowUpHint,
                                border: InputBorder.none,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: l10n.translateExplainSend,
                            icon: const Icon(Icons.send),
                            onPressed: loading ? null : _send,
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
      ),
    );
  }
}
