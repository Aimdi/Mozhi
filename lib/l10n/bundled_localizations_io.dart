import 'package:mozhi/l10n/gen/app_localizations.dart';
import 'package:mozhi/l10n/gen/app_localizations_ar.dart';
import 'package:mozhi/l10n/gen/app_localizations_de.dart';
import 'package:mozhi/l10n/gen/app_localizations_en.dart';
import 'package:mozhi/l10n/gen/app_localizations_es.dart';
import 'package:mozhi/l10n/gen/app_localizations_fr.dart';
import 'package:mozhi/l10n/gen/app_localizations_hi.dart';
import 'package:mozhi/l10n/gen/app_localizations_id.dart';
import 'package:mozhi/l10n/gen/app_localizations_it.dart';
import 'package:mozhi/l10n/gen/app_localizations_ja.dart';
import 'package:mozhi/l10n/gen/app_localizations_ko.dart';
import 'package:mozhi/l10n/gen/app_localizations_nl.dart';
import 'package:mozhi/l10n/gen/app_localizations_pl.dart';
import 'package:mozhi/l10n/gen/app_localizations_pt.dart';
import 'package:mozhi/l10n/gen/app_localizations_ru.dart';
import 'package:mozhi/l10n/gen/app_localizations_ta.dart';
import 'package:mozhi/l10n/gen/app_localizations_tr.dart';
import 'package:mozhi/l10n/gen/app_localizations_uk.dart';
import 'package:mozhi/l10n/gen/app_localizations_vi.dart';
import 'package:mozhi/l10n/gen/app_localizations_zh.dart';

/// The localisations of every language, built synchronously. Native
/// platforms gain nothing from loading them on demand (they are all in the
/// app anyway), so the first frame never waits for them and widget tests
/// keep pumping it at once.
///
/// Keep in step with [AppLocalizations.supportedLocales] (a test checks
/// it); a language missing here still loads, only asynchronously.
AppLocalizations? bundledAppLocalizations(String languageCode) =>
    switch (languageCode) {
      'ar' => AppLocalizationsAr(),
      'de' => AppLocalizationsDe(),
      'en' => AppLocalizationsEn(),
      'es' => AppLocalizationsEs(),
      'fr' => AppLocalizationsFr(),
      'hi' => AppLocalizationsHi(),
      'id' => AppLocalizationsId(),
      'it' => AppLocalizationsIt(),
      'ja' => AppLocalizationsJa(),
      'ko' => AppLocalizationsKo(),
      'nl' => AppLocalizationsNl(),
      'pl' => AppLocalizationsPl(),
      'pt' => AppLocalizationsPt(),
      'ru' => AppLocalizationsRu(),
      'ta' => AppLocalizationsTa(),
      'tr' => AppLocalizationsTr(),
      'uk' => AppLocalizationsUk(),
      'vi' => AppLocalizationsVi(),
      'zh' => AppLocalizationsZh(),
      _ => null,
    };
