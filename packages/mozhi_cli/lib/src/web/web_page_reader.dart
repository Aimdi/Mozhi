import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:mason_logger/mason_logger.dart';
import 'package:mozhi_cli/src/errors.dart';
import 'package:translation_repository/translation_repository.dart'
    show AiProviderConfig, TailnetHosts;

/// A downloaded web page.
class FetchedPage {
  const new({required this.url, required this.body, this.contentType});

  final Uri url;
  final String body;
  final String? contentType;

  bool get isPlainText =>
      contentType != null &&
      contentType!.toLowerCase().startsWith('text/plain');
}

/// Kind of extracted readable block.
enum ReadableBlockKind { heading, paragraph, listItem, quote }

/// A single readable block extracted from an HTML page.
class ReadableBlock {
  const new({required this.kind, required this.text, this.level = 0});

  final ReadableBlockKind kind;
  final String text;
  final int level;

  String formatMarkdown(String content) => switch (kind) {
    ReadableBlockKind.heading => '${'#' * level.clamp(1, 6)} $content',
    ReadableBlockKind.listItem => '- $content',
    ReadableBlockKind.quote => '> $content',
    ReadableBlockKind.paragraph => content,
  };
}

/// Extracted readable title and blocks from an HTML or plain-text page.
class ExtractedArticle {
  const new({required this.blocks, this.title});

  final String? title;
  final List<ReadableBlock> blocks;
}

/// Downloads [uri] with redirect, SSRF, timeout, and size guards.
Future<FetchedPage> fetchWebPage(
  Uri uri, {
  Duration timeout = const Duration(seconds: 25),
  int maxBytes = 2 * 1024 * 1024,
  int maxRedirects = 5,
}) async {
  if ((uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
    throw CliException.usage(
      'Invalid URL "$uri". Expected an http:// or https:// address.',
    );
  }

  final startedPublic = !_isLocalHost(uri);
  final client = io.HttpClient()..connectionTimeout = timeout;
  var current = uri;

  try {
    for (var hop = 0; hop <= maxRedirects; hop++) {
      final request = await client.getUrl(current).timeout(timeout);
      request
        ..followRedirects = false
        ..headers.set(
          io.HttpHeaders.userAgentHeader,
          'Mozilla/5.0 (compatible; MozhiCLI/1.0)',
        )
        ..headers.set(
          io.HttpHeaders.acceptHeader,
          'text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.1',
        );
      final response = await request.close().timeout(timeout);

      final location = response.headers.value(io.HttpHeaders.locationHeader);
      if (response.statusCode >= 300 &&
          response.statusCode < 400 &&
          location != null) {
        await response.drain<void>();
        if (hop == maxRedirects) {
          throw CliException.unavailable(
            'Too many redirects while fetching $uri.',
          );
        }
        final next = current.resolve(location);
        if ((next.scheme != 'http' && next.scheme != 'https') ||
            next.host.isEmpty) {
          throw CliException.unavailable(
            'Blocked redirect to unsupported URL "$next".',
          );
        }
        if (startedPublic && _isLocalHost(next)) {
          throw CliException.unavailable(
            'Blocked redirect from public URL to local/private host '
            '"${next.host}".',
          );
        }
        current = next;
        continue;
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.drain<void>();
        throw CliException.unavailable(
          'HTTP ${response.statusCode} while fetching $current.',
        );
      }

      final contentType = response.headers.contentType?.mimeType;
      if (contentType != null &&
          !contentType.startsWith('text/') &&
          contentType != 'application/xhtml+xml' &&
          contentType != 'application/xml') {
        await response.drain<void>();
        throw CliException(
          'Unsupported content type "$contentType" at $current '
          '(expected HTML or plain text).',
          exitCode: ExitCode.data,
        );
      }

      final bytes = <int>[];
      await for (final chunk in response.timeout(timeout)) {
        final remaining = maxBytes - bytes.length;
        if (remaining <= 0) break;
        if (chunk.length <= remaining) {
          bytes.addAll(chunk);
        } else {
          bytes.addAll(chunk.sublist(0, remaining));
          break;
        }
      }

      final charset = response.headers.contentType?.charset?.toLowerCase();
      final body = _decodeBytes(bytes, charset: charset);
      return FetchedPage(url: current, body: body, contentType: contentType);
    }
    throw CliException.unavailable('Too many redirects while fetching $uri.');
  } on CliException {
    rethrow;
  } on TimeoutException {
    throw CliException.unavailable('Timed out while fetching $current.');
  } on io.SocketException catch (error) {
    throw CliException.unavailable(
      'Cannot reach ${current.host}: ${error.message}',
    );
  } on io.HttpException catch (error) {
    throw CliException.unavailable(
      'HTTP error fetching $current: ${error.message}',
    );
  } finally {
    client.close(force: true);
  }
}

bool _isLocalHost(Uri uri) =>
    AiProviderConfig.isLocalHost(uri.host) ||
    TailnetHosts.isTailnetName(uri.host);

String _decodeBytes(List<int> bytes, {String? charset}) {
  if (charset == 'iso-8859-1' ||
      charset == 'latin1' ||
      charset == 'windows-1252') {
    return latin1.decode(bytes);
  }
  return utf8.decode(bytes, allowMalformed: true);
}

final _titlePattern = RegExp(
  r'<title\b[^>]*>([\s\S]*?)</title>',
  caseSensitive: false,
);
final _mainContainer = RegExp(
  r'<(article|main)\b[^>]*>([\s\S]*?)</\1>',
  caseSensitive: false,
);
final _bodyContainer = RegExp(
  r'<body\b[^>]*>([\s\S]*?)</body>',
  caseSensitive: false,
);
final _stripNoise = RegExp(
  r'<!--[\s\S]*?-->'
  r'|<(script|style|nav|footer|aside|noscript|template|svg|iframe|form)\b[^>]*>[\s\S]*?</\1>',
  caseSensitive: false,
);
final _blockPattern = RegExp(
  r'<(h[1-6]|p|li|blockquote)\b[^>]*>([\s\S]*?)</\1>',
  caseSensitive: false,
);
final _tagPattern = RegExp('<[^>]+>');
final _whitespacePattern = RegExp(r'\s+');
final _numericEntity = RegExp('&#(x?)([0-9a-fA-F]+);');

/// Extracts readable title and content blocks from [page].
ExtractedArticle extractReadableArticle(FetchedPage page) {
  if (page.isPlainText) {
    final blocks = [
      for (final para in page.body.split(RegExp(r'\r?\n\s*\r?\n')))
        if (para.trim().isNotEmpty)
          ReadableBlock(
            kind: ReadableBlockKind.paragraph,
            text: para.trim().replaceAll(_whitespacePattern, ' '),
          ),
    ];
    return ExtractedArticle(blocks: blocks);
  }

  final rawTitle = _titlePattern.firstMatch(page.body)?.group(1);
  final title = rawTitle == null ? null : _cleanText(rawTitle);

  final container =
      _pickSubstantialMain(page.body) ??
      _bodyContainer.firstMatch(page.body)?.group(1) ??
      page.body;

  final cleaned = container.replaceAll(_stripNoise, ' ');
  final blocks = <ReadableBlock>[];

  for (final match in _blockPattern.allMatches(cleaned)) {
    final tag = match.group(1)!.toLowerCase();
    final text = _cleanText(match.group(2)!);
    if (text.isEmpty) continue;
    if (tag.startsWith('h') && tag.length == 2) {
      final level = int.tryParse(tag[1]) ?? 1;
      blocks.add(
        ReadableBlock(
          kind: ReadableBlockKind.heading,
          level: level,
          text: text,
        ),
      );
    } else if (tag == 'li') {
      blocks.add(ReadableBlock(kind: ReadableBlockKind.listItem, text: text));
    } else if (tag == 'blockquote') {
      blocks.add(ReadableBlock(kind: ReadableBlockKind.quote, text: text));
    } else {
      blocks.add(ReadableBlock(kind: ReadableBlockKind.paragraph, text: text));
    }
  }

  // Fallback for pages that put text directly inside divs without <p>.
  if (blocks.isEmpty) {
    final fallback = _cleanText(cleaned);
    if (fallback.isNotEmpty) {
      blocks.add(
        ReadableBlock(kind: ReadableBlockKind.paragraph, text: fallback),
      );
    }
  }

  return ExtractedArticle(
    title: title != null && title.isNotEmpty ? title : null,
    blocks: blocks,
  );
}

String? _pickSubstantialMain(String html) {
  String? best;
  var bestLen = 0;
  for (final match in _mainContainer.allMatches(html)) {
    final inner = match.group(2)!;
    final plain = _cleanText(inner.replaceAll(_stripNoise, ' '));
    if (plain.length > bestLen) {
      bestLen = plain.length;
      best = inner;
    }
  }
  return bestLen >= 40 ? best : null;
}

String _cleanText(String raw) {
  final withoutTags = raw.replaceAll(_tagPattern, ' ');
  final decoded = _decodeHtmlEntities(withoutTags);
  return decoded.replaceAll(_whitespacePattern, ' ').trim();
}

String _decodeHtmlEntities(String text) => text
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&#39;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&mdash;', '—')
    .replaceAll('&ndash;', '–')
    .replaceAll('&hellip;', '…')
    .replaceAllMapped(_numericEntity, (m) {
      final isHex = m.group(1)!.isNotEmpty;
      final cp = int.tryParse(m.group(2)!, radix: isHex ? 16 : 10);
      if (cp == null || cp <= 0 || cp > 0x10FFFF) return m.group(0)!;
      return String.fromCharCode(cp);
    })
    .replaceAll('&amp;', '&');
