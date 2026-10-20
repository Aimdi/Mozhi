import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:translation_repository/translation_repository.dart';

/// Whether [uri] is plain `http://` to a host outside this device and the
/// local network ([AiProviderConfig.isLocalHost]): text sent there travels
/// unencrypted over the internet (security N5).
bool isInsecureHttp(Uri? uri) {
  if (uri == null || uri.scheme.toLowerCase() != 'http' || uri.host.isEmpty) {
    return false;
  }
  return !AiProviderConfig.isLocalHost(uri.host);
}

/// Prominent banner for plain http to a non-local host (security N5): an
/// error-container card with a "no encryption" icon, a [title] and [text],
/// announced as a live region when it appears.
class InsecureHttpWarning extends StatelessWidget {
  const new({required this.title, required this.text, super.key});

  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Card.filled(
      margin: EdgeInsets.zero,
      color: colors.errorContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: AppRadius.cardBorderRadius,
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.no_encryption_outlined, color: colors.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Semantics(
                container: true,
                liveRegion: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: colors.onErrorContainer,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      text,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.onErrorContainer,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
