# Accessibility audit: Mozhi Flutter app

- **Standard:** WCAG 2.2, level AA. The house rule of 48 dp touch targets is also checked.
- **Platforms:** Android (TalkBack), iOS (VoiceOver), web (NVDA/VoiceOver + browser), desktop (macOS/Windows keyboard).
- **Scope:** every `lib/**/view/**` and `lib/**/widgets/**` file present on 2026-10-13, plus `lib/app/theme.dart`, `lib/app/view/*` and `web/index.html`.
- **Method:** static read of the code. Contrast ratios were computed with `material_color_utilities` 0.13 (the tonal-spot scheme `ColorScheme.fromSeed` uses) for the default indigo seed and the amber, green, red and teal seeds, light and dark. The results were the same within ±0.05 for every seed.
- **Mode:** read-only. Around 30 agents were editing at the same time, so **line numbers are a snapshot** taken at audit time. Each finding also names the widget or expression so you can find it again with grep.

## Summary

| Severity | Count | Meaning |
| --- | --- | --- |
| CRITICAL | 1 | Blocks screen-reader users from core functionality |
| MAJOR | 14 | Significant barrier; fails an AA criterion |
| MINOR | 12 | Polish, partial failures, or advisory (AAA / best practice) |

The top three fixes:

1. **A1:** the language picker buttons cannot be activated with TalkBack or on web.
2. **B1/B2:** nothing announces translation results or errors to assistive technology.
3. **B6–B8:** the tinted status badges, the proofread insertions and the selected chips and segments fail contrast or use colour alone.

---

## CRITICAL

### A1. Language buttons lose their tap action (`excludeSemantics` around a button)

- **WCAG:** 4.1.2 Name, Role, Value (A), 2.1.1 Keyboard (A, for switch access).
- **Platforms:** Android, web (iOS falls back to a simulated touch, so it usually still works there).
- **Where:**
  - `lib/translate/widgets/language_bar.dart:110-113` (`_LanguageButton`, the source and target pickers on the main screen)
  - `lib/image_translate/widgets/image_language_bar.dart:100-103` (copy of the same pattern)
  - `lib/settings/view/widgets/accent_color_picker.dart:73-78` (`_Swatch`; this one is MAJOR because accent colour is not core)

**Problem.** `Semantics(button: true, label: …, excludeSemantics: true, child: FilledButton(...))` drops all child semantics. This was verified in `RenderSemanticsAnnotations.visitChildrenForSemantics`, which returns early when `excludeSemantics` is set. What gets dropped is the button's `SemanticsAction.tap`, its `enabled` flag and its focusability. The outer node is announced as "button", but it has no tap action:

- TalkBack's double-tap sends `ACTION_CLICK`, which the node does not support.
- On web the semantic `<button>` gets no click handler.

**Fix.** Keep the button's own semantics and replace only its *content* label:

```dart
// before
Semantics(button: true, label: semanticLabel, excludeSemantics: true,
  child: FilledButton.tonal(onPressed: onPressed, child: Row(...)))

// after
FilledButton.tonal(
  onPressed: onPressed,
  child: Semantics(
    label: semanticLabel,
    excludeSemantics: true, // only hides the visible Row text
    child: Row(...),
  ),
)
```

For `_Swatch`, either do the same or add `onTap: onTap` to the outer `Semantics` (keep `selected` and `inMutuallyExclusiveGroup`).

**Lock it with a test:**

```dart
expect(tester.getSemantics(find.byKey(const Key('translate_source_button'))),
    matchesSemantics(isButton: true, hasTapAction: true, isEnabled: true,
        hasEnabledState: true, isFocusable: true, label: 'Source language: English'));
```

---

## MAJOR

### B1. Translation results are not announced (the live region never fires usefully)

- **WCAG:** 4.1.3 Status Messages (AA).
- **Platforms:** all.
- **Where:** `lib/translate/widgets/output_card.dart:203-218`

**Problem.** The output is wrapped in `Semantics(label: l10n.translateOutputLabel, liveRegion: complete, child: SelectableText(output))`. This fails in three ways:

- The live-region node's own label is the static string "Translation". The Android and iOS bridges send the live-region change event only when the node's label changes (or when the flag first appears). So the translated text is never part of what gets announced.
- `liveRegion` switches from `false` to `true` only at completion. That means streaming produces no feedback at all, and the single event that fires carries only "Translation".
- Instant translation (the default) re-translates while the user types, and nothing tells a screen-reader user that a result arrived.

**Fix.** Drop `liveRegion` here. Keep a named container, and announce once per *completed* result from a listener:

```dart
Semantics(container: true, label: l10n.translateOutputLabel, child: ...)

// in OutputCard's BlocConsumer.listener (separate listenWhen):
listenWhen: (p, c) => p.result?.isComplete != true && (c.result?.isComplete ?? false),
listener: (context, state) => SemanticsService.sendAnnouncement(
  View.of(context),
  state.output.length > 400 ? l10n.translateAnnounceReady : state.output,
  Directionality.of(context),
),
```

(`SemanticsService.announce` is deprecated in this SDK; use `sendAnnouncement`.) Also add `semanticsLabel: l10n.translateTranslating` to the 3 dp `LinearProgressIndicator` at `output_card.dart:134`.

### B2. Async results and errors are not announced elsewhere either

- **WCAG:** 4.1.3 Status Messages (AA).
- **Platforms:** all.

None of the following has a live region or an announcement. Copy the pattern that `lib/image_translate/widgets/image_translate_error_view.dart:51` and `lib/onboarding/widgets/provider_form.dart` (the "saved" note) already use: `Semantics(liveRegion: true, child: Text(message))`. The live region must sit on the node *whose label is the message*, so wrap the `Text` itself, not a container that has other children.

| File:line | Status that appears silently |
| --- | --- |
| `lib/translate/widgets/translate_error.dart:96-101` | every translation, insights, alternatives, dictionary and explain error (`TranslateErrorView`) |
| `lib/translate/widgets/compare_panel.dart:74-81` | compare results arriving one by one (announce "N of M engines done" when `comparing` flips to false) |
| `lib/translate/widgets/extras_section.dart:185-230` | alternatives loaded or empty |
| `lib/translate/widgets/dictionary_card.dart:38-50` | dictionary entry loaded |
| `lib/translate/widgets/explain_sheet.dart:90-118` | explanation finished streaming (announce on `explainStatus` → ready, never per token) |
| `lib/translate/widgets/output_card.dart:271-286` | insights ready / empty |
| `lib/translate/widgets/language_picker_sheet.dart:222-229` | "No results for …" while searching |
| `lib/history/view/history_page.dart:220-242` | "No matches" while searching |
| `lib/proofread/widgets/proofread_result_section.dart:41-56` | `_ErrorCard`, `_NoIssuesCard`, result card, and the "N of M applied" count (`:323`) after Accept/Reject all |
| `lib/settings/view/widgets/add_instance_dialog.dart:155-165` | instance test OK / failed |
| `lib/settings/view/provider_editor_page.dart:481-489` | "Couldn't load models" |
| `lib/settings/view/instances_page.dart:75` | ping results (announce once when all pings settle) |
| `lib/onboarding/widgets/provider_form.dart:255-273` | test OK / failed notes (only "saved" is live) |
| `lib/onboarding/widgets/service_step.dart:102-111, 218-237` | "No instance reachable", own-instance added / failed (`errorText`) |

### B3. Word insights can only be reached by tapping text spans

- **WCAG:** 2.1.1 Keyboard (A).
- **Platforms:** web, desktop, switch access.
- **Where:** `lib/translate/widgets/insight_sheet.dart:186-203` (`InsightText`)

**Problem.** Each insight is a `TextSpan` with a `TapGestureRecognizer`. Spans are not focusable, so a keyboard or switch user can never open an insight sheet. The span is also announced with no hint that it is actionable.

(Proofread's `ProofreadDiffText`, `proofread_diff_text.dart:61`, uses the same technique, but `ProofreadEditsList` offers every edit as a focusable `CheckboxListTile`, so it passes.)

**Fix.** When `insightsReady`, render a focusable list under the text as well:

```dart
Wrap(spacing: 8, children: [
  for (final i in state.insights)
    ActionChip(label: Text(i.targetText),
        tooltip: i.type, onPressed: () => showInsightSheet(context, i)),
])
```

Also give each span `semanticsLabel: l10n.translateInsightSemantics(word)` (for example "‘word’, insight, double tap for details").

### B4. History entries can only be deleted by swiping

- **WCAG:** 2.5.7 Dragging Movements (AA), 2.1.1 Keyboard (A).
- **Platforms:** all pointer and keyboard users.
- **Where:** `lib/history/view/widgets/history_entry_tile.dart:34-54`

**Problem.** Delete is a `Dismissible` swipe. The `customSemanticsActions` entry helps TalkBack and VoiceOver users only. Mouse, keyboard and switch users have no way to delete a single entry.

**Fix.** Add a trailing `PopupMenuButton` (Favorite / Delete) or a delete `IconButton` next to the star, as `lib/presets/view/presets_page.dart:395-437` already does. Optionally bind the `Delete` key with `CallbackShortcuts` on the tile.

### B5. Instance latency can only be refreshed with pull-to-refresh

- **WCAG:** 2.5.7 Dragging Movements (AA), 2.1.1 Keyboard (A).
- **Platforms:** all. On desktop and web a mouse cannot drag to refresh at all.
- **Where:** `lib/settings/view/instances_page.dart:205-206`

**Fix.** Add `IconButton(tooltip: l10n.settingsInstancesRefresh, icon: const Icon(Icons.refresh), onPressed: _refresh)` to the `AppBar.actions` at `:191`. Keep the `RefreshIndicator` as a shortcut.

### B6. Tinted status badges fail text contrast

- **WCAG:** 1.4.3 Contrast (Minimum) (AA).
- **Platforms:** all.
- **Where:** the shared pattern `color` text on `color.withValues(alpha: 0.12)`:
  - `StatusBadge`, `lib/settings/view/widgets/settings_section.dart:60-95`
  - `OnboardingBadge`, `lib/onboarding/widgets/onboarding_badge.dart:23-50`
  - `UsageLevelBadge`, `lib/usage/widgets/usage_card.dart:236-262`

The text is `labelSmall`/`labelMedium` (11–12 sp) at w600, so it counts as *normal* text and needs 4.5:1.

Computed ratios (default indigo seed; other seeds within ±0.05):

| Badge (where) | Light | Dark |
| --- | --- | --- |
| success (`StatusColors.success`) on `surfaceContainerLow` (providers "Local", offline "Downloaded", latency < 500 ms) | **4.18** | 7.47 |
| any badge on the **preferred instance card** (`instances_page.dart:372-374` uses `secondaryContainer`): success / warning / error / primary "Preferred" | **3.62 / 3.95 / 4.13 / 4.29** | **4.14** / 4.71 / **4.34 / 4.30** |
| "Checking…" (`onSurfaceVariant`) on the preferred card | 6.04 | **4.31** |
| onboarding test-OK note: success text on success@12% (`provider_form.dart:255-262`) | **4.28** | — |
| `add_instance_dialog.dart:157-160`: success text on dialog `surfaceContainerHigh` | **4.42** | — |

**Fix.** Use container role pairs, which Material 3 guarantees at ≥ 7:1, instead of tinting with the foreground colour. For success, derive a scheme as `ProofreadDiffColors` already does (it measured 7.23:1):

```dart
final green = ColorScheme.fromSeed(seedColor: const Color(0xFF2E7D32), brightness: scheme.brightness);
// background: green.primaryContainer, foreground: green.onPrimaryContainer
// error: scheme.errorContainer / onErrorContainer; primary: primaryContainer / onPrimaryContainer
```

Change `StatusBadge` and `OnboardingBadge` to take a `(background, foreground)` pair. Also render the preferred-instance card on `surfaceContainerLow` with a `BorderSide(color: scheme.primary, width: 2)` instead of `secondaryContainer`.

### B7. Proofread insertions are shown by colour alone

- **WCAG:** 1.4.1 Use of Color (A), 1.4.11 Non-text Contrast (AA).
- **Platforms:** all.
- **Where:** `lib/proofread/widgets/proofread_diff_colors.dart:47-48` (`insertedStyle`)

**Problem.** Removed text has a line-through, but inserted text differs only by a green background. The measured ratios:

| Comparison | Light | Dark |
| --- | --- | --- |
| Green background vs the card | 1.17:1 | 1.83:1 |
| Inserted text colour vs normal text | 1.83:1 | 1.00:1 |

So users with red/green colour blindness, or anyone looking at a dim screen, cannot see what was inserted.

**Fix.**

```dart
TextStyle get insertedStyle => TextStyle(
  color: insertedForeground, backgroundColor: insertedBackground,
  decoration: TextDecoration.underline,
  decorationColor: insertedForeground, decorationThickness: 2,
);
```

### B8. Selected chips and segments are shown by a near-invisible fill

- **WCAG:** 1.4.1 Use of Color (A), 1.4.11 Non-text Contrast (AA).
- **Platforms:** all.
- **Where:**
  - `lib/app/theme.dart:137` (`chipTheme.showCheckmark: false`), which affects every `ChoiceChip`: `translate/widgets/options_sheet.dart:392`, `history/view/history_page.dart:149,156`, `settings/view/provider_editor_page.dart:642`, `onboarding/widgets/provider_form.dart:216`
  - `showSelectedIcon: false` on `SegmentedButton` at `options_sheet.dart:162`, `settings/view/settings_page.dart:270` and `proofread/widgets/proofread_controls.dart:54`

**Problem.** The selected state is only the `secondaryContainer` fill. Against the unselected `surfaceContainerLow` that is **1.16:1** in light mode and 1.84:1 in dark mode; 3:1 is required. The History "Favorites" chip even *removes* its star avatar when selected (`history_page.dart:157-159`).

**Fix.** Delete `showCheckmark: false` from the theme (or set it to `true`). Delete every `showSelectedIcon: false` (the default draws a check). In `history_page.dart:157`, keep `avatar` null only so that the checkmark can show.

### B9. Text clips or overflows at 200 % text size

- **WCAG:** 1.4.4 Resize Text (AA).
- **Platforms:** all (iOS reaches about 310 %).

| File:line | Problem | Fix |
| --- | --- | --- |
| `lib/settings/view/about_page.dart:74-75` | `SizedBox(height: 24)` around the version `Text`; bodyMedium line height is 19.6 dp, so it clips from about 1.25× | `ConstrainedBox(constraints: const BoxConstraints(minHeight: 24), child: …)` |
| `lib/translate/widgets/engine_selector.dart:39-68` inside `translate_page.dart:120` (`kToolbarHeight` 56) | two-line title (titleMedium + labelSmall subtitle) in a fixed 56 dp app bar: 40 dp at 1×, 60 dp at 1.5×, 80 dp at 2× → RenderFlex overflow | hide the subtitle when `MediaQuery.textScalerOf(context).scale(1) > 1.3` (it is already in the sheet), or give `_TranslateAppBar` a `preferredSize` scaled by the text scaler |
| `lib/translate/widgets/dictionary_card.dart:184-187` | sense number in `SizedBox(width: 24)`; "10." at 2× bodyLarge is about 45 dp and wraps or clips | `ConstrainedBox(constraints: const BoxConstraints(minWidth: 24), child: Padding(padding: const EdgeInsetsDirectional.only(end: 4), child: Text('$number.')))` |
| `lib/translate/widgets/markdown_lite.dart:78` | same problem for list markers (`SizedBox(width: 24, child: Text(marker))`) | same fix |
| `lib/settings/view/provider_editor_page.dart:697-702` | temperature value in `SizedBox(width: 40)`; "0.3" at 2× is about 50 dp | `ConstrainedBox(minWidth: 40)` |
| `lib/settings/view/settings_page.dart:335-343`, `lib/proofread/widgets/proofread_controls.dart:62` | segment labels `maxLines: 1, overflow: ellipsis` with icons, 3 segments in about 300 dp → "Sy…", "Compr…" at 2× | when the text scale is > 1.3, drop the segment `icon`s and use `maxLines: 2`, or fall back to a `DropdownMenu` / `RadioListTile`s below about 400 dp |

### B10. Translated text has no text direction, so RTL languages render wrongly

- **WCAG:** 1.3.2 Meaningful Sequence (A).
- **Platforms:** all. This matters more now that an Arabic UI is being added.

**Problem.** No `textDirection` is set anywhere for user or translated text:

- `lib/translate/widgets/output_card.dart:214` (`SelectableText(output)`)
- `lib/translate/widgets/input_card.dart:103` (`TextField`)
- `lib/translate/widgets/compare_panel.dart:144`
- `lib/history/view/widgets/history_entry_tile.dart:75-88` (`entry.text`, `entry.translation`)
- `lib/translate/widgets/insight_sheet.dart:62`

In an LTR UI, Arabic or Hebrew output is left-aligned with sentence punctuation on the wrong end ("؟مرحبا" instead of "مرحبا؟"). In the coming Arabic UI, English output will be right-aligned with the same problem.

**Fix.** `QuickSourceCard` already does this right (`lib/quick_translate/widgets/quick_source_card.dart:42-44,122`). Move `isRtlLanguage` (`lib/quick_translate/models/quick_languages.dart:121`) to `translation_repository` or `lib/core`, and pass:

```dart
textDirection: isRtlLanguage(code) ? TextDirection.rtl : TextDirection.ltr,
```

- For output, use the target code (or `result.detectedSource` for the input).
- For the input `TextField`, use the effective source code. When it is `auto`, use `Bidi.detectRtlDirectionality(text)` from `package:intl`.
- For the history tile, use `entry.source` and `entry.target`.

### B11. Translations and native names are read in the UI language

- **WCAG:** 3.1.2 Language of Parts (AA).
- **Platforms:** Android (LocaleSpan), iOS, web (`lang`).
- **Where:**
  - `output_card.dart:214`, `compare_panel.dart:144`, `history_entry_tile.dart:83` (translations)
  - `lib/translate/widgets/language_picker_sheet.dart:413` (`Text(native)`, for example "日本語", "العربية")
  - `dictionary_card.dart` (examples and translations)

**Problem.** These are spoken with the UI-language TTS voice. For example, Japanese output is read by an English voice, which is close to useless for a translator app. The wrong locale also makes CJK text fall back to the wrong Han glyphs.

**Fix.** Attach the locale to the span. `TextSpan.locale` both drives font selection and emits a `LocaleStringAttribute` into semantics:

```dart
Text.rich(TextSpan(text: native, locale: Locale(language.code)))
SelectableText.rich(TextSpan(text: output, locale: Locale(state.target.code)))
```

Skip this for custom or `auto` languages. Verify with TalkBack that a Japanese output switches voice.

### B12. Form controls are named only by placeholder hints, or not at all

- **WCAG:** 3.3.2 Labels or Instructions (A), 4.1.2 Name, Role, Value (A).
- **Platforms:** all.

**Problem.** Flutter fades `hintText` out with `AnimatedOpacity` once the field has text, and an opacity of 0 removes it from semantics. After typing or pasting, these fields are announced as just "edit box, <content>":

- `input_card.dart:117`, the main source text field
- `proofread/widgets/proofread_input_card.dart:86`
- `language_picker_sheet.dart:114`
- `explain_sheet.dart:134`
- `options_sheet.dart:239`, the context field (the `_Label` header above it is not associated)
- `settings/view/widgets/history_data_actions.dart:172`
- `presets/widgets/import_text_dialog.dart:121`
- `settings/view/widgets/model_picker_sheet.dart:43`
- `quick_translate/widgets/quick_language_panel.dart:91`
- `image_translate/widgets/image_language_picker.dart:90`
- `conversation/widgets/conversation_language_picker.dart:116`

Worse, the reading-level `DropdownButton` at `options_sheet.dart:186-211` has no label at all. It is read only as its value ("Standard · …"). Likewise, the formality and gender `ChoiceChip` groups and the style `SegmentedButton` are not grouped under their visible `_Label`.

**Fix.**

- Prefer `labelText:` (keep the hint).
- Where a floating label is unwanted, wrap the field with `Semantics(label: l10n.translateInputLabel, textField: true, child: TextField(...))`.
- For the dropdown, use `InputDecorator(decoration: InputDecoration(labelText: l10n.translateOptionsReadingLevel, ...))`.
- For the chip and segment groups, use `Semantics(container: true, label: l10n.translateOptionsFormality, child: _Choices(...))`. `proofread_controls.dart:50-53` already does this for the correction level.

### B13. The language picker's pinned search header can hide the focused row

- **WCAG:** 2.4.11 Focus Not Obscured (Minimum) (AA).
- **Platforms:** web, desktop, keyboard on Android.
- **Where:** `lib/translate/widgets/language_picker_sheet.dart:90-137`

**Problem.** The title and search field sit in a `PinnedHeaderSliver` that is about 130 dp tall, inside the same scroll view as rows that are 56–72 dp tall. When focus moves upward (Shift+Tab or arrow up), `Scrollable.ensureVisible` aligns the row to the top of the viewport, which is underneath the pinned header. The focused row is then hidden completely.

**Fix.** Take the header out of the scroll view:

```dart
builder: (context, controller) => Column(children: [
  ColoredBox(color: background, child: header),
  Expanded(child: CustomScrollView(controller: controller, slivers: [SliverList.list(children: items), ...])),
]),
```

### B14. Onboarding step changes are silent and drop focus

- **WCAG:** 2.4.3 Focus Order (A), 4.1.3 Status Messages (AA).
- **Platforms:** all screen readers and keyboard users.
- **Where:** `lib/onboarding/view/onboarding_page.dart:62-74`; `lib/onboarding/widgets/progress_dots.dart:21`

**Problem.** `_showStep` calls `primaryFocus?.unfocus()` and then jumps or animates the `PageView`. TalkBack and VoiceOver focus stays on the Next button (or is lost), the new step's heading is not read, and the "Step x of y" label does not update live.

**Fix.** After the page change:

```dart
WidgetsBinding.instance.addPostFrameCallback((_) => SemanticsService.sendAnnouncement(
  View.of(context), '${_titleFor(step)}. ${l10n.onboardingStepProgress(step.index + 1, OnboardingStep.values.length)}',
  Directionality.of(context)));
```

Better still, give `OnboardingStepLayout`'s header `Semantics` a `FocusNode` and `requestFocus()` it, so keyboard users start at the top of the new step.

---

## MINOR

### C1. Physical (LTR) insets and icons in directional layouts

- **WCAG:** 1.3.2 (A). This is visual polish for the Arabic UI.

`EdgeInsets.fromLTRB` / `only(right:)` with asymmetric values does not mirror. The 20 dp text padding ends up on the wrong side, and the 8 dp side ends up next to the text instead of next to the action buttons. Replace each with `EdgeInsetsDirectional.fromSTEB(...)` / `only(end: …)`:

- `translate/widgets/input_card.dart:93,141`
- `translate/widgets/output_card.dart:141,160,172,202,223,233,288`
- `translate/widgets/compare_panel.dart:114,119,142`
- `translate/widgets/explain_sheet.dart:122`
- `proofread/view/proofread_page.dart:119,133`
- `proofread/widgets/proofread_result_section.dart:142,166,183,369`
- `history/view/history_page.dart:316`

Also:

- `lib/app/view/app_shell.dart:86-87`: `SafeArea(right: false)`. In RTL the `NavigationRail` sits on the right edge, so it needs `left: !isRtl, right: isRtl` with `isRtl = Directionality.of(context) == TextDirection.rtl`.
- `lib/translate/widgets/extras_section.dart:226`: `Icons.north_west` has no `matchTextDirection`. Pick `Icons.north_east` in RTL.
- `lib/translate/widgets/options_sheet.dart:266`: the literal `'$key → $value'` points the wrong way in RTL and is read as "right arrow". Use an ARB string, for example `translateGlossaryEntry(term, translation)` → "{term} → {translation}", with `semanticsLabel` "{term} translates to {translation}".

### C2. Proofread menus don't expose the selected option

- **WCAG:** 4.1.2 (A).
- **Where:** `lib/proofread/widgets/proofread_controls.dart:176-180`

The current option is marked by a check icon that is `Colors.transparent` on the other options. The icon has no semantics, so a screen reader cannot tell which option is selected. The trigger at `:189` also has no expanded state.

**Fix.** Use `RadioMenuButton<T>(value: option, groupValue: value, onChanged: (v) => onSelected(v as T), child: …)`, or wrap the child in `Semantics(selected: option == value, inMutuallyExclusiveGroup: true)`. Wrap the trigger in `Semantics(expanded: controller.isOpen, ...)`.

### C3. Missing heading semantics on visible section titles

- **WCAG:** 1.3.1 (A), 2.4.6 (AA).

Wrap these in `Semantics(header: true, …)`:

- `translate/widgets/compare_panel.dart:49` ("Compare")
- `translate/widgets/engine_selector.dart:128` (sheet title)
- `translate/widgets/options_sheet.dart:147` (sheet title)
- `translate/widgets/language_picker_sheet.dart:100` (sheet title)
- `translate/widgets/explain_sheet.dart` (title row)
- `translate/widgets/dictionary_card.dart` ("Examples", "Synonyms", "Etymology")
- `translate/widgets/word_choices_panel.dart:100` ("Synonyms")
- `proofread/widgets/proofread_result_section.dart:150,319`
- the `NoEnginesView`, history `_EmptyState`, presets `_Message` and providers `_EmptyState` titles

### C4. Indeterminate progress indicators with no name

- **WCAG:** 1.1.1 / 4.1.2 (A).

Add `semanticsLabel: l10n.commonLoading` (or a specific string) to each:

- `proofread/view/proofread_page.dart:62`
- `history/view/history_page.dart:201`
- `presets/view/presets_page.dart:245`
- `offline/view/offline_models_page.dart:84`
- `translate/widgets/extras_section.dart:96,188`
- `translate/widgets/dictionary_card.dart:41`
- `translate/widgets/explain_sheet.dart` (both indicators)
- `proofread/widgets/proofread_button.dart`

### C5. Information available only in tooltips on non-focusable widgets

- **WCAG:** 1.4.13 (AA), 2.1.1 (A).

Keyboard users cannot reach these tooltips:

- `lib/onboarding/widgets/instance_tile.dart:97-98` holds the ping error detail. When `ping.error` is null it builds a tooltip with an empty message.
- `lib/offline/widgets/offline_engine_badge.dart:19` has the same problem.

**Fix.** Show the error as visible secondary text (the `RadioListTile.subtitle`). Build the `Tooltip` only when the message is not empty.

### C6. Latency quality is conveyed only by colour

- **WCAG:** 1.4.1 (A).
- **Where:** `settings/view/instances_page.dart:491-498` and `onboarding/widgets/instance_tile.dart:73-85`

Fast, OK and slow use the same icon and differ only in green, amber or red. The number is present, so this is minor.

**Fix.** Vary the icon (`Icons.speed` / `Icons.timelapse` / `Icons.hourglass_bottom`), or append a word through l10n ("{ms} ms · fast").

### C7. Compare latency uses a hard-coded unit

- **WCAG:** 3.2.4 Consistent Identification (AA).
- **Where:** `lib/translate/widgets/compare_panel.dart:132`

`'${formatSeconds(elapsed)} s'` is not localised and is read as "zero point eight s". The output footer, by contrast, uses `l10n.translateEngineElapsed`.

**Fix.** Use a new l10n key, with a `semanticsLabel` that spells out "seconds".

### C8. Filled text fields have no visible boundary

- **WCAG:** 1.4.11 Non-text Contrast (AA).
- **Where:** `lib/app/theme.dart:85-96`

`enabledBorder` is `BorderSide.none` and the field is identified only by a `surfaceContainerHighest` fill: 1.23:1 against `surface`, and about 1.1:1 against the dialog `surfaceContainerHigh`. This affects every field that does not override `border`, for example `add_instance_dialog.dart:126-152` and `language_picker_sheet.dart:126-130`.

**Fix.** Use `enabledBorder: inputBorder.copyWith(borderSide: BorderSide(color: scheme.outline))` (`outline` measures 4.06:1 against `surfaceContainerLow`), or an `UnderlineInputBorder` in `onSurfaceVariant`.

### C9. Invalid provider form gives no feedback beyond inline errors

- **WCAG:** 3.3.1 (A), 4.1.3 (AA).
- **Where:** `lib/settings/view/provider_editor_page.dart:237-238` (`_save`, same in `_testConnection`)

When `validate()` fails, nothing is announced and focus stays on Save. The inline `errorText` is read only when the user navigates back to each field.

**Fix.** Give each `TextFormField` a `FocusNode`. On failure, `requestFocus()` the first invalid one and announce `l10n.settingsProviderFixErrors`.

### C10. Web page title and document language

- **WCAG:** 2.4.2 (A), 3.1.1 (A).
- **Platform:** web only.
- **Where:** `lib/app/router.dart`, `web/index.html:2`

Every route reports the same title, "Mozhi" (`onGenerateTitle`). The page also ships `<html>` with no `lang`.

**Fix.** Wrap each page's `Scaffold` in `Title(title: '${l10n.historyTitle} · ${l10n.appTitle}', color: scheme.primary, child: …)`. Set `<html lang="en">` as the fallback, and check that the engine updates it when the locale changes (add a small `web` interop update in `App` if it does not).

### C11. Animations not gated on `disableAnimations`

- **WCAG:** 2.3.3 is AAA, so this is advisory only at AA.
- **Where:** `settings/view/widgets/accent_color_picker.dart:87` (`AnimatedContainer`, 150 ms) and `quick_translate/widgets/quick_source_card.dart:113` (`AnimatedSize`, 200 ms)

**Fix.** `duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : …`. These already do it correctly: `SkeletonBox` (`skeleton.dart:27`), the voice `_LevelRing`, `OnboardingProgressDots` and `OnboardingView._showStep`.

### C12. Image preview needs pinch and drag to zoom and pan

- **WCAG:** 2.5.1 Pointer Gestures (A).
- **Where:** `lib/image_translate/widgets/image_translate_preview.dart:41-55`

`InteractiveViewer` zooms and pans only with multipoint or path gestures.

**Fix.** Add zoom in, zoom out and reset `IconButton`s that drive a `TransformationController`. Also make sure the translated *text* is shown as text next to the image, not only inside it (1.4.5; `semanticLabel` alone says only "Translated image").

---

## What passes

- **Icon buttons:** every `IconButton` in the audited files has a `tooltip`, and toggles use `isSelected` with matching tooltips. This covers copy, share, listen, favourite, insights, pin, compare, options, clear, paste, swap, password visibility and voice.
- **Touch targets:** buttons, chips and segments rely on Material's padded `materialTapTargetSize` (48 dp). Custom targets are explicitly 48 dp: swatches, drag handles, the language buttons' `minimumSize`, the voice button and the onboarding buttons. Nothing interactive is below 24 dp.
- **Pointer-only gestures:** no bare `GestureDetector` is used for taps anywhere. Reordering has Move up/down menu items (`instances_page.dart:445-454`, `presets_page.dart:421-432`), and `ReorderableListView` adds its own semantic move actions.
- **Reduced motion:** the skeleton pulse, the voice level ring, the onboarding dots and the page transition all honour `MediaQuery.disableAnimations`.
- **Images:** the only `Image` (`image_translate_preview.dart:45`) has a `semanticLabel`. Decorative illustration icons are excluded (`step_layout.dart:44`).
- **Charts and composite controls:** `UsageHistoryChart` exposes a full text summary, `TranslateSkeleton` exposes a single "Loading engines" live label, and `OnboardingProgressDots` reads "Step x of y".
- **Grouped list items:** semantic custom actions and the open hint on history tiles, labelled switches on provider tiles, `RadioGroup` in the assist-engine dialog and the onboarding instance list, and `Semantics(selected:, inMutuallyExclusiveGroup:)` on provider cards.
- **Errors in text:** form errors are identified in text through `errorText` and `validator`, and API-key fields allow paste (3.3.8).
- **Keyboard shortcuts:** Ctrl/Cmd+Enter translates or proofreads and Ctrl/Cmd+Shift+S swaps languages. There are no single-key shortcuts (2.1.4).
- **Snackbars:** `SnackBar`s are live regions, and those with an action persist (`material_ui` 1.6.0 `persist = action != null`), so there is no timing problem (2.2.1).
- **Orientation:** the app is not locked to one orientation (1.3.4).

## Unfinished or not yet audited

These modules were landing while the audit ran. Re-run the checks above on them once they are finished, especially for the copied `excludeSemantics` button pattern (A1), hint-only fields (B12) and tinted badges (B6).

- **Voice:** `VoiceInputButton` exists and is fine (live "Listening" label, gated ring), but it is not wired into `InputCard` yet. When it is, make sure partial results update the field without stealing screen-reader focus.
- **Conversation:** only models, side colours and a language picker exist so far; there is no view yet. `ConversationSideColors` tells the speakers apart by primary vs tertiary colour, so each turn must also carry a text or semantic label naming the side (1.4.1).
- **Image translate:** the view landed during the audit and only its widgets were pattern-scanned. A1 applies to `image_language_bar.dart:100-103`.
- **Quick translate and web translate:** views landed during the audit and were only pattern-scanned.
- **Routing:** onboarding, presets, offline and usage pages exist but are not routed in `lib/app/router.dart` yet, so page titles (C10) and focus on entry still need checking once they are wired.
