import 'package:mozhi/web_translate/core/readable_extractor.dart';
import 'package:mozhi/web_translate/data/web_page_fetcher.dart';

/// Turns a downloaded page into its readable content: HTML through
/// [ReadableExtractor], plain text split into paragraphs.
///
/// A top-level function so that it can run in a background isolate
/// (`compute(extractFetchedPage, page)`).
ReadablePage extractFetchedPage(FetchedWebPage page) {
  if (page.isPlainText) {
    final segments = page.url.pathSegments.where((s) => s.isNotEmpty);
    return ReadableExtractor.fromPlainText(
      page.body,
      title: segments.isEmpty
          ? page.url.host
          : Uri.decodeComponent(segments.last),
    );
  }
  return const ReadableExtractor().extract(page.body, baseUri: page.url);
}
