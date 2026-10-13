# Mozhi app – contributor notes for agents

Flutter app (Android first; also iOS, macOS, Windows, web) that is a client for
self-hostable **Mozhi** translation instances plus an **AI translator**
(OpenAI-compatible / Anthropic / Gemini / Ollama), modelled on Kagi Translate.

## Layout
- `packages/mozhi_api` – pure Dart client for the Mozhi REST API.
- `packages/llm_api` – pure Dart streaming LLM clients.
- `packages/translation_repository` – domain models, language catalogue,
  prompts, parsers, and `TranslationRepository` (unifies both backends).
- `lib/` – the app: `app/` (shell, router, theme), `settings/`, `history/`,
  `translate/`, `proofread/`, `speech/`, `platform/`, `core/`.
- Public APIs are defined contract-first; keep signatures stable. If a
  contract truly needs to change, change it minimally and say so in your
  final report.

## Toolchain
- Flutter 3.47 / Dart 3.13 (`flutter`, `dart`, `very_good` are on PATH).
- **Import Material from `package:material_ui/material_ui.dart`**, never
  `package:flutter/material.dart` (go_router and dynamic_color use
  material_ui; mixing them causes type mismatches).
- Dart 3.13 syntax: `very_good_analysis` 11 wants the new constructor syntax
  (`const new(...)`, `factory fromJson(...)`, primary constructors). Write
  normal code, then run `dart fix --apply <path>` (it accepts ONE file or
  directory per invocation – loop over your paths) and `dart format <paths>`.
- Analyze only what you own: `dart analyze <paths>`; zero errors/warnings,
  and fix infos too.
- **Tests:** shell `flutter test` / `dart test` are blocked by a hook. Use the
  Very Good CLI MCP test tool through the helper script:
  - Flutter app: `python3 /home/user/.tools/vgmcp.py call test '{"directory":"/home/user/Mozhi","paths":["test/translate"],"optimization":false}'`
  - Dart package: `python3 /home/user/.tools/vgmcp.py call test '{"directory":"/home/user/Mozhi/packages/llm_api","dart":true,"optimization":false}'`
  Add `"coverage":true` for coverage. Never run tests for directories you
  don't own while others are working.
- Never run `dart fix`, `dart format`, or codegen on the whole repo or on
  paths you don't own – other agents edit files concurrently.
- Do not edit `pubspec.yaml` files (dependencies are pinned centrally). If a
  dependency is truly missing, report it.
- Do not use `git` to commit, stash, checkout, or reset.

## Localisation
- All user-facing app strings go through `context.l10n.<key>`
  (`package:mozhi/l10n/l10n.dart`).
- Add keys with the lock-safe helper (it also regenerates the code):
  `python3 tool/l10n_add.py '{"translateSwap": "Swap languages"}'`
  Prefix keys by feature (`translate*`, `history*`, `settings*`,
  `proofread*`, `common*` for shared ones). ICU plurals/placeholders are
  supported (see the script docstring). Never edit `lib/l10n/gen/` by hand.

## Style
- State management: `flutter_bloc` Cubits + `equatable` states; Page/View
  split (`XPage` provides, `XView` builds).
- Routing: `go_router` (`lib/app/router.dart`).
- Material 3, adaptive layouts (phone: bottom nav; ≥ 840 dp: navigation rail
  and side-by-side panes), 48 dp touch targets, semantic labels on icon
  buttons, works in light/dark.
- Tests: `bloc_test` + `mocktail`; `package:http/testing.dart` `MockClient`
  for HTTP. Aim for full coverage of logic.
- No telemetry, no analytics, history stays on device.
