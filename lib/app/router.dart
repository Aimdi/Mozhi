import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/translate_link.dart';
import 'package:mozhi/app/view/app_shell.dart';
import 'package:mozhi/conversation/view/conversation_page.dart';
import 'package:mozhi/conversation/widgets/conversation_voice_mic.dart';
import 'package:mozhi/dictionary/view/dictionary_page.dart';
import 'package:mozhi/documents/view/document_translate_page.dart';
import 'package:mozhi/history/view/history_page.dart';
import 'package:mozhi/image_translate/models/picked_image.dart';
import 'package:mozhi/image_translate/view/image_translate_page.dart';
import 'package:mozhi/offline/view/offline_models_page.dart';
import 'package:mozhi/onboarding/onboarding_redirect.dart';
import 'package:mozhi/onboarding/view/onboarding_page.dart';
import 'package:mozhi/presets/view/glossaries_page.dart';
import 'package:mozhi/presets/view/presets_page.dart';
import 'package:mozhi/proofread/view/proofread_page.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/view/about_page.dart';
import 'package:mozhi/settings/view/instances_page.dart';
import 'package:mozhi/settings/view/provider_editor_page.dart';
import 'package:mozhi/settings/view/providers_page.dart';
import 'package:mozhi/settings/view/quality_modes_page.dart';
import 'package:mozhi/settings/view/settings_page.dart';
import 'package:mozhi/translate/view/translate_page.dart';
import 'package:mozhi/usage/view/usage_summary_page.dart';
import 'package:mozhi/web_translate/view/web_translate_page.dart';
import 'package:mozhi/web_translate/view/web_translate_route.dart';
import 'package:translation_repository/translation_repository.dart';

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

  /// On-device (offline) language models.
  static const offline = '/settings/offline';

  /// Translation presets.
  static const presets = '/settings/presets';

  /// Glossaries.
  static const glossaries = '/settings/glossaries';

  /// AI provider usage this and last month.
  static const usage = '/settings/usage';
  static const quality = '/settings/quality';

  /// First-run flow (full screen, outside the tabs).
  static const String onboarding = onboardingLocation;

  /// Full-screen translators pushed above the tabs.
  static const image = '/image';
  static const documents = '/documents';
  static const web = '/web';
  static const conversation = '/conversation';

  /// The AI dictionary (full screen).
  static const dictionary = '/dictionary';

  /// Scheme of the app's deep links, `mozhi://<screen>[/<path>][?<query>]`
  /// (see [deepLinkLocation]).
  static const deepLinkScheme = 'mozhi';

  /// Location of the provider editor: edit [id], or create a new provider
  /// (prefilled from [preset] when given).
  static String editProvider({String? id, String? preset}) =>
      _location(providerEditor, {'id': ?id, 'preset': ?preset});

  /// Kagi-style translate link, e.g. `/translate?text=hola&from=es&to=en`.
  static String translateText({String? text, String? from, String? to}) =>
      _location(translate, {'text': ?text, 'from': ?from, 'to': ?to});

  /// The proofreading tab with [text] in its input (nothing is sent until
  /// the user asks), e.g. `/proofread?text=I%20has%20a%20cat`.
  static String proofreadText({String? text}) =>
      _location(proofread, {'text': ?text});

  /// The dictionary showing [word] (`from`: the word's language, `to`: the
  /// language of the translations), e.g. `/dictionary?word=gato&from=es`.
  ///
  /// Pass [DictionaryLaunch.lookUp] as the navigation's `extra` to look the
  /// word up right away; links from outside the app never do that on
  /// their own (see [DictionaryPage]).
  static String dictionaryWord({String? word, String? from, String? to}) =>
      _location(dictionary, {'word': ?word, 'from': ?from, 'to': ?to});

  /// The image translator, opening the picker for [source] on arrival.
  static String imageTranslate({ImagePickSource? source}) =>
      _location(image, {ImageTranslatePage.sourceParameter: ?source?.name});

  /// The web page translator with [url] in its address field.
  ///
  /// Pass [WebPageLaunch.load] as the navigation's `extra` to load and
  /// translate it right away; links from outside the app only fill in the
  /// address (the user presses Translate).
  static String webPage({String? url}) {
    final trimmed = url?.trim() ?? '';
    return _location(web, {
      if (trimmed.isNotEmpty) WebTranslateRoute.urlParameter: trimmed,
    });
  }

  /// Older locations some features link to, and where they live now.
  static const Map<String, String> aliases = {
    ImageTranslatePage.location: image,
    WebTranslateRoute.path: web,
  };

  static String _location(String path, Map<String, String> query) =>
      Uri(path: path, queryParameters: query.isEmpty ? null : query).toString();
}

/// Pass as the navigation's `extra` (`context.push(AppRoutes.webPage(url:
/// …), extra: WebPageLaunch.load)`) to load and translate the address right
/// away. Links from outside the app cannot carry it: they only fill in the
/// address, so a link never fetches a page or sends it to a (paid)
/// translation engine on its own.
enum WebPageLaunch { load }

/// Called when a location carries a [TranslateLink].
typedef TranslateLinkCallback = void Function(TranslateLink link);

/// Decides where the app goes instead of the plain start location it was
/// launched at (e.g. the first-run onboarding); null keeps it.
typedef LaunchRedirect = String? Function(String location);

/// Builds the app's router.
///
/// Four tabs are kept alive in a [StatefulShellRoute.indexedStack] with an
/// adaptive [AppShell]. The settings sub-pages stay inside the settings
/// tab; the onboarding, the image, document, web page and conversation
/// translators and the dictionary are full-screen routes on the root
/// navigator ([navigatorKey]) above the tabs.
///
/// Translate links (`/translate?text=…&from=…&to=…` or the same query on
/// `/`, including Kagi's option parameters, see [TranslateLink.fromUri])
/// are handed to [onTranslateLink] and the URL is cleaned up to
/// `/translate`. `/proofread?text=…` fills the proofreading input,
/// `/dictionary?word=…&from=…&to=…` opens the dictionary and
/// `/web?url=…` fills in the web page translator's address; none of them
/// fetches or sends anything on its own (the in-app `extra`s
/// [DictionaryLaunch.lookUp] and [WebPageLaunch.load] do). Deep links
/// (`mozhi://translate?…`, `mozhi://dictionary?…`, ...) open the same
/// locations ([deepLinkLocation]).
///
/// [launchRedirect] is consulted once, for the location the app starts at,
/// and only when that is a plain start location (`/` or `/translate`
/// without a query, see [isLaunchLocation]): deep links and shared text
/// are never redirected.
GoRouter createAppRouter({
  TranslateLinkCallback? onTranslateLink,
  LaunchRedirect? launchRedirect,
  String initialLocation = AppRoutes.translate,
  GlobalKey<NavigatorState>? navigatorKey,
}) {
  final rootKey = navigatorKey ?? GlobalKey<NavigatorState>();
  var launched = false;

  GoRoute fullScreen(String path, GoRouterWidgetBuilder builder) =>
      GoRoute(path: path, parentNavigatorKey: rootKey, builder: builder);

  return GoRouter(
    navigatorKey: rootKey,
    initialLocation: initialLocation,
    redirect: (context, state) {
      final uri = state.uri;
      if (!launched) {
        launched = true;
        if (launchRedirect != null && isLaunchLocation(uri)) {
          final target = launchRedirect(AppRoutes.translate);
          if (target != null) return target;
        }
      }
      return appRedirect(uri, onTranslateLink);
    },
    onException: (context, state, router) => router.go(AppRoutes.translate),
    routes: [
      fullScreen(
        AppRoutes.onboarding,
        (context, state) => const OnboardingPage(),
      ),
      fullScreen(
        AppRoutes.image,
        (context, state) => ImageTranslatePage(
          initialSource: ImagePickSource.tryParse(
            state.uri.queryParameters[ImageTranslatePage.sourceParameter],
          ),
        ),
      ),
      fullScreen(
        AppRoutes.documents,
        (context, state) => const DocumentTranslatePage(),
      ),
      fullScreen(AppRoutes.web, (context, state) {
        final url =
            state.uri.queryParameters[WebTranslateRoute.urlParameter]?.trim() ??
            '';
        if (url.isEmpty || state.extra == WebPageLaunch.load) {
          return WebTranslatePage(initialUrl: url);
        }
        // A link only fills in the address; a new address (another link
        // while the page is open) starts afresh.
        return WebTranslatePage(
          key: ValueKey(url),
          initialUrl: url,
          autoLoad: false,
        );
      }),
      fullScreen(
        AppRoutes.conversation,
        (context, state) =>
            const ConversationPage(micBuilder: conversationVoiceMicBuilder),
      ),
      fullScreen(AppRoutes.dictionary, (context, state) {
        final query = state.uri.queryParameters;
        return DictionaryPage(
          // A new word (another link while the page is open) starts afresh.
          key: ValueKey(state.uri.query),
          word: query['word'],
          from: query['from'],
          to: query['to'],
          autoLookUp: state.extra == DictionaryLaunch.lookUp,
        );
      }),
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
                builder: (context, state) => ProofreadPage(
                  initialText: state.uri.queryParameters['text'],
                ),
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
                    path: 'offline',
                    builder: (context, state) => const OfflineModelsPage(),
                  ),
                  GoRoute(
                    path: 'presets',
                    builder: (context, state) => PresetsPage(
                      onOpenGlossaries: () =>
                          unawaited(context.push<void>(AppRoutes.glossaries)),
                    ),
                  ),
                  GoRoute(
                    path: 'glossaries',
                    builder: (context, state) => const GlossariesPage(),
                  ),
                  GoRoute(
                    path: 'quality',
                    builder: (context, state) => const QualityModesPage(),
                  ),
                  GoRoute(
                    path: 'usage',
                    builder: (context, state) => const _UsageRoute(),
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

/// Whether [uri] is a plain start location: `/` (or empty) or `/translate`
/// without a query. Only these may be replaced by a [LaunchRedirect]; deep
/// links (`mozhi://…`) never are.
bool isLaunchLocation(Uri uri) {
  if (uri.hasQuery || uri.hasScheme || uri.host.isNotEmpty) return false;
  final path = uri.path;
  return path.isEmpty || path == '/' || path == AppRoutes.translate;
}

/// Top-level redirect: deep links (`mozhi://<screen>…`) go to their
/// location ([deepLinkLocation]); `/` goes to `/translate`; translate links
/// are reported to [onTranslateLink] and stripped from the location so
/// that returning to the tab does not translate again; [AppRoutes.aliases]
/// are sent to their current location (keeping the query).
String? appRedirect(Uri uri, TranslateLinkCallback? onTranslateLink) {
  final deepLink = deepLinkLocation(uri);
  if (deepLink != null) return deepLink;

  final path = uri.path;
  final alias = AppRoutes.aliases[path];
  if (alias != null) return uri.replace(path: alias).toString();

  final isRoot = path.isEmpty || path == '/';
  if (!isRoot && path != AppRoutes.translate) return null;

  final link = uri.hasQuery ? TranslateLink.fromUri(uri) : null;
  if (link != null) onTranslateLink?.call(link);
  return (isRoot || link != null) ? AppRoutes.translate : null;
}

/// The location a deep link `mozhi://<screen>[/<path>][?<query>]` opens:
/// `/<screen>[/<path>][?<query>]`, e.g. `mozhi://dictionary?word=gato` ->
/// `/dictionary?word=gato` (`mozhi:///<path>` opens `/<path>`). Null for
/// anything else.
///
/// Android rewrites these links before Flutter sees them (MainActivity),
/// but iOS hands the whole URL to the router, with the screen as the host.
String? deepLinkLocation(Uri uri) {
  if (!uri.isScheme(AppRoutes.deepLinkScheme)) return null;
  final host = uri.host.toLowerCase();
  final segments = uri.pathSegments.where((s) => s.isNotEmpty);
  final path = Uri(pathSegments: [if (host.isNotEmpty) host, ...segments]);
  return Uri(
    path: '/${path.path}',
    query: uri.hasQuery && uri.query.isNotEmpty ? uri.query : null,
  ).toString();
}

/// [UsageSummaryPage] for the configured providers; tapping a provider
/// opens its editor.
class _UsageRoute extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final providers = context.select<SettingsCubit, List<AiProviderConfig>>(
      (cubit) => cubit.state.providers,
    );
    return UsageSummaryPage(
      providers: providers,
      onOpenProvider: (id) =>
          unawaited(context.push<void>(AppRoutes.editProvider(id: id))),
    );
  }
}
