import 'dart:async';

/// Removes `<think>...</think>` / `<thinking>...</thinking>` /
/// `<reasoning>...</reasoning>` blocks that reasoning models (DeepSeek-R1,
/// Qwen3, QwQ, some LM Studio / llama.cpp setups) emit inline in the
/// content stream.
///
/// Works on *streamed* text where tags may be split across chunks: text
/// that might be the beginning of an opening tag is held back until it can
/// be decided. An unterminated block at end of stream is dropped. Also
/// drops a leading run of whitespace that follows a removed block.
class ThinkTagFilter extends StreamTransformerBase<String, String> {
  const new();

  /// Convenience for complete strings.
  static String strip(String text) {
    throw UnimplementedError('TODO(llm_api)');
  }

  @override
  Stream<String> bind(Stream<String> stream) {
    throw UnimplementedError('TODO(llm_api)');
  }
}
