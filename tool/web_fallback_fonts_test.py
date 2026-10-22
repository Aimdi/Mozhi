#!/usr/bin/env python3
"""Tests tool/web_fallback_fonts.py on a fake Flutter SDK and web build (no
network).

  python3 tool/web_fallback_fonts_test.py
"""

from __future__ import annotations

import io
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

TOOL = Path(__file__).resolve().parent / "web_fallback_fonts.py"
ROOT = TOOL.parent.parent
sys.path.insert(0, str(TOOL.parent))

import web_fallback_fonts as fonts  # noqa: E402

ROBOTO = "roboto/v32/KFOmCnqEu92Fr1Me4GZLCzYlKw.woff2"
EMOJI = "notocoloremoji/v32/Yq6P-KqIXTD0t4D9z1ESnKM3-HpFabsE4tq3luCC7p-aXxcn.0.woff2"
SC = "notosanssc/v37/k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYxNbPzS5HE.97.woff2"

FALLBACK_DATA = f"""
import 'noto_font.dart';

List<NotoFont> getFallbackFontList() => <NotoFont>[
  NotoFont(
    'Noto Color Emoji 0',
    '{EMOJI}',
  ),
  NotoFont('Noto Sans SC 97', '{SC}'),
  NotoFont('Noto Color Emoji 0 again', '{EMOJI}'),
];
"""
CANVASKIT_FONTS = f"""
String _robotoUrl =
    '${{configuration.fontFallbackBaseUrl}}{ROBOTO}';
"""

CSP = (
    "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; "
    "font-src 'self' data: https://fonts.gstatic.com; connect-src 'self' https: http:"
)
INDEX = f"""<!DOCTYPE html>
<html><head>
<!-- fonts.gstatic.com serves the fallback fonts; font-src lists it. -->
<meta http-equiv="Content-Security-Policy" content="{CSP}">
</head><body><script src="flutter_bootstrap.js" async></script></body></html>
"""
BOOTSTRAP = """/* flutter.js */
const mozhiSelfHostedFonts = false;
_flutter.loader.load({config: mozhiSelfHostedFonts ? {fontFallbackBaseUrl: 'x'} : {}});
"""


def font_bytes(path: str) -> bytes:
    return b"wOF2" + path.encode() + bytes(64)


class FakeFetch:
    """Serves [font_bytes] (or [answers]) and records what was fetched."""

    def __init__(self, answers: dict[str, bytes] | None = None):
        self.answers = answers or {}
        self.fetched: list[str] = []

    def __call__(self, path: str) -> bytes:
        self.fetched.append(path)
        return self.answers.get(path, font_bytes(path))


class Case(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        base = Path(self.temp.name)
        self.sdk = base / "flutter"
        engine = self.sdk / "bin/cache/flutter_web_sdk/lib/_engine/engine"
        (engine / "canvaskit").mkdir(parents=True)
        (engine / fonts.FALLBACK_DATA).write_text(FALLBACK_DATA)
        (engine / "canvaskit/fonts.dart").write_text(CANVASKIT_FONTS)
        self.engine = engine
        self.build = base / "build/web"
        self.build.mkdir(parents=True)
        (self.build / "index.html").write_text(INDEX)
        (self.build / "flutter_bootstrap.js").write_text(BOOTSTRAP)
        self.cache = base / "cache"

    def tearDown(self):
        self.temp.cleanup()

    def mirror(self, **kwargs):
        return fonts.mirror(
            self.build,
            fonts.font_paths(self.sdk),
            cache=self.cache,
            workers=2,
            **kwargs,
        )


class FontPathsTest(Case):
    def test_reads_the_noto_fonts_and_roboto_once_each(self):
        self.assertEqual(fonts.font_paths(self.sdk), [ROBOTO, EMOJI, SC])

    def test_falls_back_to_the_ui_sources(self):
        other = self.sdk / "bin/cache/flutter_web_sdk/lib/ui/src/engine"
        other.parent.mkdir(parents=True)
        self.engine.rename(other)
        self.assertEqual(fonts.font_paths(self.sdk), [ROBOTO, EMOJI, SC])

    def test_fails_without_the_font_data(self):
        (self.engine / fonts.FALLBACK_DATA).unlink()
        with self.assertRaisesRegex(fonts.SetupError, "precache"):
            fonts.font_paths(self.sdk)

    def test_fails_when_no_font_is_found(self):
        (self.engine / fonts.FALLBACK_DATA).write_text("List<NotoFont> f() => [];")
        with self.assertRaisesRegex(fonts.SetupError, "No fonts found"):
            fonts.font_paths(self.sdk)

    def test_fails_without_roboto(self):
        (self.engine / "canvaskit/fonts.dart").write_text("// nothing")
        with self.assertRaisesRegex(fonts.SetupError, "Roboto"):
            fonts.font_paths(self.sdk)

    def test_rejects_paths_outside_the_font_folder(self):
        for bad in ["../etc/passwd.woff2", "/abs/v1/x.woff2", "a/../../x.woff2", "a/v1/x.js", "A/v1/x.woff2"]:
            (self.engine / fonts.FALLBACK_DATA).write_text(f"NotoFont('x', '{bad}'),")
            with self.subTest(bad), self.assertRaisesRegex(fonts.SetupError, "Unexpected font path"):
                fonts.font_paths(self.sdk)

    def test_finds_the_flutter_root(self):
        self.assertEqual(fonts.flutter_root("/x/flutter"), Path("/x/flutter"))

    def test_real_sdk(self):
        try:
            root = fonts.flutter_root()
            paths = fonts.font_paths(root)
        except fonts.SetupError as error:
            self.skipTest(str(error))
        self.assertIn(ROBOTO, paths)
        self.assertGreater(len(paths), 500)


class CheckFontTest(unittest.TestCase):
    def test_accepts_fonts_of_their_type(self):
        fonts.check_font("a/v1/x.woff2", b"wOF2....")
        fonts.check_font("a/v1/x.woff", b"wOFF....")
        fonts.check_font("a/v1/x.ttf", b"\x00\x01\x00\x00....")
        fonts.check_font("a/v1/x.otf", b"OTTO....")

    def test_rejects_anything_else(self):
        for data in [b"", b"<html>error</html>", b"wOFF...."]:
            with self.subTest(data), self.assertRaises(fonts.FontError):
                fonts.check_font("a/v1/x.woff2", data)
        with self.assertRaisesRegex(fonts.FontError, "more than"):
            fonts.check_font("a/v1/x.woff2", b"wOF2" + bytes(fonts.MAX_BYTES))


class MirrorTest(Case):
    def test_copies_every_font_at_its_path_and_patches_the_build(self):
        fetch = FakeFetch()

        result = self.mirror(fetch=fetch)

        self.assertEqual(sorted(fetch.fetched), sorted([ROBOTO, EMOJI, SC]))
        for path in [ROBOTO, EMOJI, SC]:
            self.assertEqual((self.build / "fallback_fonts" / path).read_bytes(), font_bytes(path))
        self.assertEqual(result.fonts, 3)
        self.assertEqual(result.downloaded, 3)
        self.assertEqual(result.total_bytes, sum(len(font_bytes(p)) for p in [ROBOTO, EMOJI, SC]))
        bootstrap = (self.build / "flutter_bootstrap.js").read_text()
        self.assertIn("const mozhiSelfHostedFonts = true;", bootstrap)
        self.assertNotIn("= false;", bootstrap)
        index = (self.build / "index.html").read_text()
        self.assertIn("font-src 'self' data:; connect-src 'self' https: http:", index)
        self.assertNotIn("https://fonts.gstatic.com", index)
        # Only the policy changes, not the comment.
        self.assertIn("<!-- fonts.gstatic.com serves the fallback fonts; font-src lists it. -->", index)

    def test_reuses_the_cache_and_is_idempotent(self):
        self.mirror(fetch=FakeFetch())
        first = (self.build / "index.html").read_text()
        fetch = FakeFetch()

        result = self.mirror(fetch=fetch)

        self.assertEqual(fetch.fetched, [])
        self.assertEqual(result.downloaded, 0)
        self.assertEqual((self.build / "index.html").read_text(), first)
        self.assertIn("= true;", (self.build / "flutter_bootstrap.js").read_text())

    def test_replaces_a_broken_cached_file(self):
        (self.cache / ROBOTO).parent.mkdir(parents=True)
        (self.cache / ROBOTO).write_bytes(b"<html>")
        fetch = FakeFetch()

        self.mirror(fetch=fetch)

        self.assertIn(ROBOTO, fetch.fetched)
        self.assertEqual((self.cache / ROBOTO).read_bytes(), font_bytes(ROBOTO))

    def test_fails_on_a_file_that_is_not_a_font(self):
        with self.assertRaisesRegex(fonts.FontError, "not a woff2 font"):
            self.mirror(fetch=FakeFetch({SC: b"<html>blocked</html>"}))
        self.assertFalse((self.cache / SC).exists())
        self.assertIn("= false;", (self.build / "flutter_bootstrap.js").read_text())

    def test_offline_uses_only_the_cache(self):
        with self.assertRaisesRegex(fonts.FontError, "--offline"):
            self.mirror(offline=True, fetch=FakeFetch())
        self.mirror(fetch=FakeFetch())
        fetch = FakeFetch()
        self.mirror(offline=True, fetch=fetch)
        self.assertEqual(fetch.fetched, [])

    def test_needs_a_web_build(self):
        (self.build / "index.html").unlink()
        with self.assertRaisesRegex(fonts.SetupError, "not a web build"):
            self.mirror(fetch=FakeFetch())

    def test_needs_the_bootstrap_marker(self):
        (self.build / "flutter_bootstrap.js").write_text("_flutter.loader.load();")
        with self.assertRaisesRegex(fonts.SetupError, "web/flutter_bootstrap.js"):
            self.mirror(fetch=FakeFetch())
        (self.build / "flutter_bootstrap.js").unlink()
        with self.assertRaisesRegex(fonts.SetupError, "missing"):
            self.mirror(fetch=FakeFetch())

    def test_needs_a_content_security_policy(self):
        (self.build / "index.html").write_text("<html></html>")
        with self.assertRaisesRegex(fonts.SetupError, "Content Security Policy"):
            self.mirror(fetch=FakeFetch())


class RepositoryFilesTest(unittest.TestCase):
    """The markers this script patches are in the files it patches."""

    def test_web_bootstrap_has_the_marker(self):
        self.assertIn(fonts.BOOTSTRAP_OFF, (ROOT / "web/flutter_bootstrap.js").read_text())

    def test_web_index_allows_gstatic_until_patched(self):
        html = (ROOT / "web/index.html").read_text()
        policy = fonts.CSP_META.search(html)[2]
        self.assertIn("https://fonts.gstatic.com", policy)
        self.assertNotIn("https://fonts.gstatic.com", fonts.strip_gstatic(policy))
        self.assertIn("font-src 'self' data:;", fonts.strip_gstatic(policy))


class CommandLineTest(Case):
    def run_tool(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(TOOL), *args, "--flutter-root", str(self.sdk)],
            capture_output=True,
            text=True,
        )

    def test_lists_the_fonts(self):
        result = self.run_tool("--list")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.split(), [ROBOTO, EMOJI, SC])

    def test_mirrors_from_the_cache(self):
        self.mirror(fetch=FakeFetch())
        result = self.run_tool(str(self.build), "--cache", str(self.cache), "--offline")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Self-hosted 3 fallback fonts", result.stdout)

    def test_exit_status(self):
        missing = self.run_tool(str(self.build), "--cache", str(self.cache), "--offline")
        self.assertEqual(missing.returncode, 1)
        self.assertIn("--offline", missing.stderr)
        (self.build / "index.html").unlink()
        broken = self.run_tool(str(self.build), "--cache", str(self.cache), "--offline")
        self.assertEqual(broken.returncode, 2)
        usage = self.run_tool()
        self.assertEqual(usage.returncode, 2)

    def test_main_in_process(self):
        self.mirror(fetch=FakeFetch())
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            status = fonts.main(
                [str(self.build), "--cache", str(self.cache), "--offline", "--flutter-root", str(self.sdk)]
            )
        self.assertEqual(status, 0, err.getvalue())
        self.assertIn("0 downloaded", out.getvalue())


if __name__ == "__main__":
    unittest.main()
