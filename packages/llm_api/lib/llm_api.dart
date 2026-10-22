/// Streaming chat clients for OpenAI-compatible, Anthropic, Gemini and
/// Ollama LLM APIs, with retries of transient failures, helpers for
/// SSE/NDJSON parsing and stripping `<think>` reasoning blocks.
library;

export 'src/llm_client.dart';
export 'src/llm_exception.dart';
export 'src/models.dart';
export 'src/providers/anthropic_client.dart';
export 'src/providers/gemini_client.dart';
export 'src/providers/ollama_client.dart';
export 'src/providers/openai_compatible_client.dart';
export 'src/retry_policy.dart';
export 'src/streaming/ndjson_decoder.dart';
export 'src/streaming/sse_decoder.dart';
export 'src/think_filter.dart';
