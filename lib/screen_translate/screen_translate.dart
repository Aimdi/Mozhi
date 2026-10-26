/// "Translate screen" (Android): the translucent window that takes one
/// screenshot after the system's consent, reads it on the device and draws
/// the translation over it (`ScreenTranslateHost`, `ScreenTranslatePage`),
/// and its settings: the Quick Settings tile and the opt-in bubble
/// (`ScreenTranslateSettingsSection`).
library;

export 'cubit/screen_translate_cubit.dart';
export 'cubit/screen_translate_settings_cubit.dart';
export 'data/screen_translate_controls.dart';
export 'data/screenshot_picker.dart';
export 'screen_translate_host.dart';
export 'view/screen_translate_page.dart';
export 'view/screen_translate_settings.dart';
