import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/proofread/cubit/proofread_cubit.dart';

/// Multiline input with paste/clear actions. Ctrl/Cmd+Enter proofreads.
class ProofreadInputCard extends StatefulWidget {
  const new({super.key});

  @override
  State<ProofreadInputCard> createState() => _ProofreadInputCardState();
}

class _ProofreadInputCardState extends State<ProofreadInputCard> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: context.read<ProofreadCubit>().state.input,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (!mounted || text == null || text.isEmpty) return;
    context.read<ProofreadCubit>().setInput(text);
  }

  void _proofread() {
    final cubit = context.read<ProofreadCubit>();
    if (cubit.state.canProofread) cubit.proofread();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final input = context.select((c) => c.state.input);

    return BlocListener<ProofreadCubit, ProofreadState>(
      listenWhen: (previous, current) => previous.input != current.input,
      listener: (context, state) {
        if (_controller.text == state.input) return;
        _controller.value = TextEditingValue(
          text: state.input,
          selection: TextSelection.collapsed(offset: state.input.length),
        );
      },
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.enter, control: true):
                    _proofread,
                const SingleActivator(LogicalKeyboardKey.enter, meta: true):
                    _proofread,
              },
              child: TextField(
                key: const Key('proofread_input'),
                controller: _controller,
                onChanged: context.read<ProofreadCubit>().setInput,
                minLines: 6,
                maxLines: null,
                keyboardType: TextInputType.multiline,
                textCapitalization: TextCapitalization.sentences,
                style: theme.textTheme.bodyLarge,
                decoration: InputDecoration(
                  hintText: l10n.proofreadInputHint,
                  border: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  filled: false,
                  contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(16, 0, 4, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.proofreadCharacterCount(input.characters.length),
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: l10n.proofreadPaste,
                    onPressed: _paste,
                    icon: const Icon(Icons.content_paste),
                  ),
                  if (input.isNotEmpty)
                    IconButton(
                      tooltip: l10n.commonClear,
                      onPressed: context.read<ProofreadCubit>().clear,
                      icon: const Icon(Icons.clear),
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
