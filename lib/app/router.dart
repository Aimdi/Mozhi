import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/shared_files.dart';
import 'package:mozhi/app/translate_link.dart';
import 'package:mozhi/app/view/app_shell.dart';
import 'package:mozhi/app/view/deferred_page.dart';
import 'package:mozhi/app/view/shared_file_loader.dart';
import 'package:mozhi/app/view/shared_image_picker.dart'
    deferred as shared_image;
import 'package:mozhi/app/view/top_level_actions.dart';
import 'package:mozhi/conversation/view/conversation_page.dart'
    deferred as conversation_page;
import 'package:mozhi/conversation/widgets/conversation_voice_mic.dart'
    deferred as conversation_mic;
import 'package:mozhi/dictionary/view/dictionary_page.dart'
    deferred as dictionary_page;
import 'package:mozhi/dictionary/view/dictionary_page.dart'
    show DictionaryLaunch;
import 'package:mozhi/documents/data/document_file_service.dart'
    deferred as document_files;
import 'package:mozhi/documents/view/document_translate_page.dart'
    deferred as documents_page;
import 'package:mozhi/history/view/history_page.dart';
import 'package:mozhi/image_translate/models/picked_image.dart';
import 'package:mozhi/image_translate/view/image_translate_page.dart'
    deferred as image_page;
import 'package:mozhi/image_translate/view/image_translate_page.dart'
    show ImageTranslatePage;
import 'package:mozhi/offline/view/offline_models_page.dart'
    deferred as offline_page;
import 'package:mozhi/onboarding/onboarding_redirect.dart';
import 'package:mozhi/onboarding/view/onboarding_page.dart'
    deferred as onboarding_page;
import 'package:mozhi/presets/view/glossaries_page.dart'
    deferred as glossaries_page;
import 'package:mozhi/presets/view/presets_page.dart' deferred as presets_page;
import 'package:mozhi/proofread/view/proofread_page.dart'
    deferred as proofread_page;
import 'package:mozhi/quick_translate/quick_translate_host.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/models/settings_category.dart';
import 'package:mozhi/settings/view/about_page.dart' deferred as about_page;
import 'package:mozhi/settings/view/instances_page.dart'
    deferred as instances_page;
import 'package:mozhi/settings/view/network_activity_page.dart'
    deferred as network_page;
import 'package:mozhi/settings/view/provider_editor_page.dart'
    deferred as provider_editor_page;
import 'package:mozhi/settings/view/providers_page.dart'
    deferred as providers_page;
import 'package:mozhi/settings/view/quality_modes_page.dart'
    deferred as quality_page;
import 'package:mozhi/settings/view/settings_page.dart'
    deferred as settings_page;
import 'package:mozhi/settings/view/tab_order_page.dart'
    deferred as tab_order_page;
import 'package:mozhi/settings/view/voice_input_settings_page.dart'
    deferred as voice_settings_page;
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/view/translate_page.dart';
import 'package:mozhi/usage/view/usage_summary_page.dart'
    deferred as usage_page;
import 'package:mozhi/voice/speech_input_service.dart';
import 'package:mozhi/voice/widgets/voice_input_button.dart'
    show VoiceInputButton;
import 'package:mozhi/web_translate/view/web_translate_page.dart'
    deferred as web_page;
import 'package:mozhi/web_translate/view/web_translate_route.dart';
import 'package:translation_repository/translation_repository.dart';

/// Every location the app can show.
abstract final class AppRoutes {
  /// The four tabs (in their default order; the user can reorder them,
  /// see [tab]).
  static const translate = '/translate';
  static const dictionary = '/dictionary';
  static const proofread = '/proofread';
  static const conversation = '/conversation';

  /// The location of [tab].
  static String tab(AppTab tab) => switch (tab) {
    AppTab.translate => translate,
    AppTab.dictionary => dictionary,
    AppTab.proofread => proofread,
    AppTab.conversation => conversation,
  };

  /// Full pages above the tabs, opened from every tab's app bar
  /// ([TopLevelActions]); the settings sub-pages stack above the settings.
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

  /// What the app sent over the network this session.
  static const networkActivity = '/settings/network';
  static const quality = '/settings/quality';

  /// The order of the tabs.
  static const tabOrder = '/settings/tabs';

  /// Voice input settings (the offline speech models).
  static const String voiceSettings = VoiceInputButton.settingsLocation;

  /// First-run flow (full screen, outside the tabs).
  static const String onboarding = onboardingLocation;

  /// Full-screen translators pushed above the tabs.
  static const image = '/image';
  static const documents = '/documents';
  static const web = '/web';

  /// The only page of the translucent quick translate window on Android
  /// (see [QuickTranslateHost]); never shown in the main window.
  static const String quickTranslate = QuickTranslateHost.location;

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
  /// their own (see [dictionary_page.DictionaryPage]).
  static String dictionaryWord({String? word, String? from, String? to}) =>
      _location(dictionary, {'word': ?word, 'from': ?from, 'to': ?to});

  /// The image translator, opening the picker for [source] on arrival.
  static String imageTranslate({ImagePickSource? source}) =>
      _location(image, {ImageTranslatePage.sourceParameter: ?source?.name});

  /// The image translator with the image shared from another app under
  /// [token] ([SharedFiles]).
  static String sharedImage(String token) =>
      _location(image, {SharedFiles.parameter: token});

  /// The document translator with the file shared from another app under
  /// [token] ([SharedFiles]).
  static String sharedDocument(String token) =>
      _location(documents, {SharedFiles.parameter: token});

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

/// The screens that are only loaded when first opened (separate downloads
/// on the web, keeping them out of the startup bundle).
abstract final class DeferredFeatures {
  static final onboarding = DeferredLibrary(onboarding_page.loadLibrary);
  static final image = DeferredLibrary(
    () => Future.wait<void>([
      image_page.loadLibrary(),
      shared_image.loadLibrary(),
    ]),
  );
  static final documents = DeferredLibrary(
    () => Future.wait<void>([
      documents_page.loadLibrary(),
      document_files.loadLibrary(),
    ]),
  );
  static final web = DeferredLibrary(web_page.loadLibrary);
  static final conversation = DeferredLibrary(
    () => Future.wait<void>([
      conversation_page.loadLibrary(),
      conversation_mic.loadLibrary(),
    ]),
  );
  static final dictionary = DeferredLibrary(dictionary_page.loadLibrary);
  static final offline = DeferredLibrary(offline_page.loadLibrary);
  static final presets = DeferredLibrary(presets_page.loadLibrary);
  static final glossaries = DeferredLibrary(glossaries_page.loadLibrary);
  static final usage = DeferredLibrary(usage_page.loadLibrary);
  static final proofread = DeferredLibrary(proofread_page.loadLibrary);

  /// The settings and their pages (but the offline languages, presets,
  /// glossaries and usage, which are loaded on their own).
  static final settings = DeferredLibrary(
    () => Future.wait<void>([
      settings_page.loadLibrary(),
      instances_page.loadLibrary(),
      providers_page.loadLibrary(),
      provider_editor_page.loadLibrary(),
      quality_page.loadLibrary(),
      tab_order_page.loadLibrary(),
      voice_settings_page.loadLibrary(),
      about_page.loadLibrary(),
      network_page.loadLibrary(),
    ]),
  );

  /// All of them.
  static List<DeferredLibrary> get all => [
    onboarding,
    image,
    documents,
    web,
    conversation,
    dictionary,
    offline,
    presets,
    glossaries,
    usage,
    proofread,
    settings,
  ];
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
///
/// `location` is `/` for a plain launch (the launcher icon, a fresh visit
/// of the web app) and [AppRoutes.translate] when the translate tab was
/// asked for explicitly (the home-screen widget's Type button,
/// `mozhi://translate`, a reload of the web app at `#/translate`).
typedef LaunchRedirect = String? Function(String location);

/// Builds the app's router.
///
/// Four tabs (Translate, Dictionary, Proofread, Conversation) are kept
/// alive in a [StatefulShellRoute.indexedStack] with an adaptive
/// [AppShell] (which shows them in the user's order, `AppSettings.tabOrder`;
/// the branches and their locations never move); the Dictionary and
/// Conversation tabs are deferred (loaded when first opened). History and
/// Settings (with the settings sub-pages nested below it), the onboarding
/// and the image, document and web page
/// translators are full-screen routes on the root navigator
/// ([navigatorKey]) outside the tabs: pushed (see [TopLevelActions]) they
/// sit above the tabs and go back to them. Opened on their own (a link, an
/// app shortcut or a `go`), History and Settings go back to the first tab
/// of the user's order ([TopLevelPageScope], `topLevelBackButton`).
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
/// are never redirected. The app uses it for the onboarding and to open on
/// the first tab of the user's order ([homeRedirect]); the onboarding
/// finishes on that tab too.
///
/// [initialLocation] is where a plain launch starts: `/` (which shows the
/// translate tab). The platform's own start location wins over it (the
/// route of a deep link, the address of a reloaded web page), so `/` is
/// only seen for a plain launch and an explicit `/translate` (the
/// home-screen widget's Type button) can be told apart from it.
///
/// Files shared from other apps open `/image?shared=<token>` and
/// `/documents?shared=<token>` ([SharedFiles]): the document is loaded
/// into the document translator (which waits for Translate); the image is
/// shown on the image screen and only translated right away when the
/// translator's engine is not an AI model (as for shared text, see
/// [mayAutoTranslateShared]); otherwise it waits for Translate.
///
/// In the quick translate window ([quickTranslateWindow], default
/// [QuickTranslateHost.isActive] of [QuickTranslateHost.instance]) every
/// location shows [AppRoutes.quickTranslate], a transparent page under the
/// quick translate sheet; the main window never shows that page.
GoRouter createAppRouter({
  TranslateLinkCallback? onTranslateLink,
  LaunchRedirect? launchRedirect,
  String initialLocation = '/',
  GlobalKey<NavigatorState>? navigatorKey,
  bool? quickTranslateWindow,
}) {
  final rootKey = navigatorKey ?? GlobalKey<NavigatorState>();
  final inQuickWindow =
      quickTranslateWindow ?? QuickTranslateHost.instance.isActive;
  var launched = false;

  /// A route whose page lives in a deferred [library] (a separate download
  /// on the web, see [DeferredPage]).
  GoRoute deferredRoute(
    String path,
    DeferredLibrary library,
    GoRouterWidgetBuilder builder, {
    GlobalKey<NavigatorState>? parentNavigatorKey,
    List<RouteBase> routes = const [],
  }) => GoRoute(
    path: path,
    parentNavigatorKey: parentNavigatorKey,
    routes: routes,
    builder: (context, state) => DeferredPage(
      library: library,
      builder: (context) => builder(context, state),
    ),
  );
  GoRoute fullScreenDeferred(
    String path,
    DeferredLibrary library,
    GoRouterWidgetBuilder builder,
  ) => deferredRoute(path, library, builder, parentNavigatorKey: rootKey);

  return GoRouter(
    navigatorKey: rootKey,
    initialLocation: initialLocation,
    redirect: (context, state) {
      final uri = state.uri;
      if (inQuickWindow) {
        return uri.path == AppRoutes.quickTranslate
            ? null
            : AppRoutes.quickTranslate;
      }
      if (uri.path == AppRoutes.quickTranslate) return AppRoutes.translate;
      if (!launched) {
        launched = true;
        if (launchRedirect != null && isLaunchLocation(uri)) {
          final target = launchRedirect(uri.path.isEmpty ? '/' : uri.path);
          if (target != null) return target;
        }
      }
      return appRedirect(uri, onTranslateLink);
    },
    onException: (context, state, router) => router.go(AppRoutes.translate),
    routes: [
      GoRoute(
        path: AppRoutes.quickTranslate,
        pageBuilder: (context, state) =>
            const NoTransitionPage(child: QuickTranslateHostView()),
      ),
      fullScreenDeferred(
        AppRoutes.onboarding,
        DeferredFeatures.onboarding,
        (context, state) => onboarding_page.OnboardingPage(
          finishLocation: _homeLocation(context),
        ),
      ),
      fullScreenDeferred(AppRoutes.image, DeferredFeatures.image, (
        context,
        state,
      ) {
        final token = state.uri.queryParameters[SharedFiles.parameter];
        if (SharedFiles.isToken(token)) {
          return SharedFileLoader(
            key: ValueKey(token),
            token: token!,
            // On-device text recognition reads the file.
            keep: true,
            builder: (context, file) => file == null
                ? image_page.ImageTranslatePage()
                : image_page.ImageTranslatePage(
                    picker: shared_image.SharedImagePicker(file),
                    autoTranslate: mayAutoTranslateShared(context),
                  ),
          );
        }
        return image_page.ImageTranslatePage(
          initialSource: ImagePickSource.tryParse(
            state.uri.queryParameters[ImageTranslatePage.sourceParameter],
          ),
        );
      }),
      fullScreenDeferred(AppRoutes.documents, DeferredFeatures.documents, (
        context,
        state,
      ) {
        final token = state.uri.queryParameters[SharedFiles.parameter];
        if (!SharedFiles.isToken(token)) {
          return documents_page.DocumentTranslatePage();
        }
        return SharedFileLoader(
          key: ValueKey(token),
          token: token!,
          builder: (context, file) => documents_page.DocumentTranslatePage(
            initialFile: file == null
                ? null
                : document_files.PickedFile(name: file.name, bytes: file.bytes),
          ),
        );
      }),
      fullScreenDeferred(AppRoutes.web, DeferredFeatures.web, (context, state) {
        final url =
            state.uri.queryParameters[WebTranslateRoute.urlParameter]?.trim() ??
            '';
        if (url.isEmpty || state.extra == WebPageLaunch.load) {
          return web_page.WebTranslatePage(initialUrl: url);
        }
        // A link only fills in the address; a new address (another link
        // while the page is open) starts afresh.
        return web_page.WebTranslatePage(
          key: ValueKey(url),
          initialUrl: url,
          autoLoad: false,
        );
      }),
      // Not deferred: in the VM, deferred libraries share one load, and a
      // test that opens History before another deferred page would leave
      // that load to a finished test's zone (test/app/view/app_test.dart).
      GoRoute(
        path: AppRoutes.history,
        builder: (context, state) => TopLevelPageScope(
          child: HistoryPage(
            initialTab: HistoryTab.tryParse(
              state.uri.queryParameters[HistoryPage.tabParameter],
            ),
          ),
        ),
      ),
      GoRoute(
        path: AppRoutes.settings,
        builder: (context, state) => DeferredPage(
          library: DeferredFeatures.settings,
          builder: (context) =>
              // A deferred class cannot be const (the lint does not know).
              // ignore: prefer_const_constructors
              TopLevelPageScope(child: settings_page.SettingsPage()),
        ),
        routes: [
          deferredRoute(
            'instances',
            DeferredFeatures.settings,
            (context, state) => instances_page.InstancesPage(),
          ),
          deferredRoute(
            'providers',
            DeferredFeatures.settings,
            (context, state) => providers_page.ProvidersPage(),
            routes: [
              deferredRoute(
                'edit',
                DeferredFeatures.settings,
                (context, state) => provider_editor_page.ProviderEditorPage(
                  providerId: state.uri.queryParameters['id'],
                  presetId: state.uri.queryParameters['preset'],
                ),
              ),
            ],
          ),
          deferredRoute(
            'offline',
            DeferredFeatures.offline,
            (context, state) => offline_page.OfflineModelsPage(),
          ),
          deferredRoute(
            'presets',
            DeferredFeatures.presets,
            (context, state) => presets_page.PresetsPage(
              onOpenGlossaries: () =>
                  unawaited(context.push<void>(AppRoutes.glossaries)),
            ),
          ),
          deferredRoute(
            'glossaries',
            DeferredFeatures.glossaries,
            (context, state) => glossaries_page.GlossariesPage(),
          ),
          deferredRoute(
            'quality',
            DeferredFeatures.settings,
            (context, state) => quality_page.QualityModesPage(),
          ),
          deferredRoute(
            'tabs',
            DeferredFeatures.settings,
            (context, state) => tab_order_page.TabOrderPage(),
          ),
          deferredRoute(
            'voice',
            DeferredFeatures.settings,
            (context, state) => voice_settings_page.VoiceInputSettingsPage(),
          ),
          deferredRoute(
            'usage',
            DeferredFeatures.usage,
            (context, state) => const _UsageRoute(),
          ),
          deferredRoute(
            'network',
            DeferredFeatures.settings,
            (context, state) => network_page.NetworkActivityPage(),
          ),
          deferredRoute(
            'about',
            DeferredFeatures.settings,
            (context, state) => about_page.AboutPage(
              highlight:
                  state.uri.queryParameters[SettingsCategory.rowParameter],
            ),
          ),
          // The settings categories (`/settings/privacy?row=incognito`
          // scrolls to a row).
          for (final category in SettingsCategory.routed)
            deferredRoute(
              category.path,
              DeferredFeatures.settings,
              (context, state) => settings_page.SettingsCategoryPage(
                category: category,
                highlight:
                    state.uri.queryParameters[SettingsCategory.rowParameter],
              ),
            ),
        ],
      ),
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
              deferredRoute(AppRoutes.dictionary, DeferredFeatures.dictionary, (
                context,
                state,
              ) {
                final query = state.uri.queryParameters;
                return dictionary_page.DictionaryPage(
                  // A new word (another link while the tab is open) starts
                  // afresh.
                  key: ValueKey(state.uri.query),
                  word: query['word'],
                  from: query['from'],
                  to: query['to'],
                  autoLookUp: state.extra == DictionaryLaunch.lookUp,
                );
              }),
            ],
          ),
          StatefulShellBranch(
            routes: [
              deferredRoute(
                AppRoutes.proofread,
                DeferredFeatures.proofread,
                (context, state) => proofread_page.ProofreadPage(
                  initialText: state.uri.queryParameters['text'],
                ),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              deferredRoute(
                AppRoutes.conversation,
                DeferredFeatures.conversation,
                (context, state) => conversation_page.ConversationPage(
                  // No microphones where speech recognition is unavailable.
                  micBuilder: _speechInputSupported(context)
                      ? conversation_mic.conversationVoiceMicBuilder
                      : null,
                ),
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

/// Whether something shared from another app may be translated without the
/// user pressing Translate: only by the translator's engine when it is not
/// an AI model, outside compare mode (the rule of shared text, see
/// `TranslateCubit.setExternalInput`). False without a [TranslateCubit].
bool mayAutoTranslateShared(BuildContext context) {
  final TranslateState state;
  try {
    state = context.read<TranslateCubit>().state;
  } on ProviderNotFoundException {
    return false;
  }
  final engine = state.engine;
  return engine != null && !engine.isAi && !state.compareMode;
}

/// [LaunchRedirect] to the first tab of the user's order
/// ([AppSettings.tabOrder]) for a plain launch ([location] `/`): that
/// tab's location. Null for any other location: a start at `/translate`
/// asked for it explicitly (the home-screen widget's Type button, a reload
/// of the web app at `#/translate`) and stays there.
String? homeRedirect(AppSettings settings, String location) {
  if (location.isNotEmpty && location != '/') return null;
  return AppRoutes.tab(settings.tabOrder.first);
}

/// The location of the first tab of the user's order (read from the
/// [SettingsCubit], which the onboarding needs anyway).
String _homeLocation(BuildContext context) =>
    AppRoutes.tab(context.read<SettingsCubit>().state.tabOrder.first);

/// Whether the app-wide [SpeechInputService] can recognise speech on this
/// platform (false without one).
bool _speechInputSupported(BuildContext context) {
  try {
    return context.read<SpeechInputService>().isPlatformSupported;
  } on ProviderNotFoundException {
    return false;
  }
}

/// [usage_page.UsageSummaryPage] for the configured providers; tapping a
/// provider opens its editor.
class _UsageRoute extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final providers = context.select<SettingsCubit, List<AiProviderConfig>>(
      (cubit) => cubit.state.providers,
    );
    return usage_page.UsageSummaryPage(
      providers: providers,
      onOpenProvider: (id) =>
          unawaited(context.push<void>(AppRoutes.editProvider(id: id))),
    );
  }
}
