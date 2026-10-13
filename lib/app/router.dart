import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/translate_link.dart';
import 'package:mozhi/app/view/app_shell.dart';
import 'package:mozhi/history/view/history_page.dart';
import 'package:mozhi/proofread/view/proofread_page.dart';
import 'package:mozhi/settings/view/about_page.dart';
import 'package:mozhi/settings/view/instances_page.dart';
import 'package:mozhi/settings/view/provider_editor_page.dart';
import 'package:mozhi/settings/view/providers_page.dart';
import 'package:mozhi/settings/view/settings_page.dart';
import 'package:mozhi/translate/view/translate_page.dart';

/// Every location the app can show.
abstract final class AppRoutes {
  static const translate = '/translate';
  static const proofread = '/proofread';
  static const history = '/history';
  static const settings = '/settings';
  static const instances = '/settings/instances';
  static const providers = '/settings/providers';
  static const providerEditor = '/settings/providers/edit';
  static const about = '/settings/about';

  /// Location of the provider editor: edit [id], or create a new provider
  /// (prefilled from [preset] when given).
  static String editProvider({String? id, String? preset}) => Uri(
    path: providerEditor,
    queryParameters: {'id': ?id, 'preset': ?preset},
  ).toString();

  /// Kagi-style translate link, e.g. `/translate?text=hola&from=es&to=en`.
  static String translateText({String? text, String? from, String? to}) => Uri(
    path: translate,
    queryParameters: {'text': ?text, 'from': ?from, 'to': ?to},
  ).toString();
}

/// Called when a location carries a [TranslateLink].
typedef TranslateLinkCallback = void Function(TranslateLink link);

/// Builds the app's router.
///
/// Four tabs are kept alive in a [StatefulShellRoute.indexedStack] with an
/// adaptive [AppShell]. Translate links (`/translate?text=…&from=…&to=…`
/// or the same query on `/`) are handed to [onTranslateLink] and the URL
/// is cleaned up to `/translate`.
GoRouter createAppRouter({
  TranslateLinkCallback? onTranslateLink,
  String initialLocation = AppRoutes.translate,
  GlobalKey<NavigatorState>? navigatorKey,
}) {
  return GoRouter(
    navigatorKey: navigatorKey,
    initialLocation: initialLocation,
    redirect: (context, state) => appRedirect(state.uri, onTranslateLink),
    onException: (context, state, router) => router.go(AppRoutes.translate),
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) => AppShell(
          selectedIndex: navigationShell.currentIndex,
          onDestinationSelected: (index) => navigationShell.goBranch(
            index,
            // Tapping the active tab returns to its first page.
            initialLocation: index == navigationShell.currentIndex,
          ),
          child: navigationShell,
        ),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.translate,
                builder: (context, state) => const TranslatePage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.proofread,
                builder: (context, state) => const ProofreadPage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.history,
                builder: (context, state) => const HistoryPage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.settings,
                builder: (context, state) => const SettingsPage(),
                routes: [
                  GoRoute(
                    path: 'instances',
                    builder: (context, state) => const InstancesPage(),
                  ),
                  GoRoute(
                    path: 'providers',
                    builder: (context, state) => const ProvidersPage(),
                    routes: [
                      GoRoute(
                        path: 'edit',
                        builder: (context, state) => ProviderEditorPage(
                          providerId: state.uri.queryParameters['id'],
                          presetId: state.uri.queryParameters['preset'],
                        ),
                      ),
                    ],
                  ),
                  GoRoute(
                    path: 'about',
                    builder: (context, state) => const AboutPage(),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ],
  );
}

/// Top-level redirect: `/` goes to `/translate`; translate links are
/// reported to [onTranslateLink] and stripped from the location so that
/// returning to the tab does not translate again.
String? appRedirect(Uri uri, TranslateLinkCallback? onTranslateLink) {
  final path = uri.path;
  final isRoot = path.isEmpty || path == '/';
  if (!isRoot && path != AppRoutes.translate) return null;

  final link = uri.hasQuery ? TranslateLink.fromUri(uri) : null;
  if (link != null) onTranslateLink?.call(link);
  return (isRoot || link != null) ? AppRoutes.translate : null;
}
