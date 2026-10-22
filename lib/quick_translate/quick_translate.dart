/// Compact quick-translate UI for text handed over by other apps (Android
/// `PROCESS_TEXT` "Translate with Mozhi" / share) and desktop hotkeys.
///
/// Entry point: `showQuickTranslate(context, text: ...)` (or
/// `QuickTranslateSheet` to embed the content in a window). On Android,
/// selections are shown in a translucent window of their own
/// (`QuickTranslateHost`).
library;

export 'cubit/quick_translate_cubit.dart';
export 'models/quick_languages.dart';
export 'quick_translate_host.dart';
export 'view/quick_translate_sheet.dart';
export 'widgets/widgets.dart';
