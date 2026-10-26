#!/usr/bin/env python3
"""Tests tool/web_shell_manifest.py on a fake web build (no network), and
that web/mozhi_sw.js reads what it writes (with Node.js, when installed).

  python3 tool/web_shell_manifest_test.py
"""

from __future__ import annotations

import hashlib
import io
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

TOOL = Path(__file__).resolve().parent / "web_shell_manifest.py"
ROOT = TOOL.parent.parent
WORKER = ROOT / "web" / "mozhi_sw.js"
sys.path.insert(0, str(TOOL.parent))

import web_shell_manifest as shell  # noqa: E402

INDEX = """<!DOCTYPE html>
<html><head>
  <base href="/">
  <meta charset="UTF-8">
</head><body><script src="flutter_bootstrap.js" async></script></body></html>
"""

DART2JS = (
    '_flutter.buildConfig = {"engineRevision":"x","builds":[{"compileTarget":"dart2js",'
    '"renderer":"canvaskit","mainJsPath":"main.dart.js"},{}],"useLocalCanvasKit":true};'
)
DART2WASM = (
    '_flutter.buildConfig = {"builds":[{"compileTarget":"dart2wasm","renderer":"skwasm",'
    '"mainWasmPath":"main.dart.wasm"},{"compileTarget":"dart2js","renderer":"canvaskit"}]};'
)
BOOTSTRAP = """/* flutter.js */
if (!window._flutter) {{
  window._flutter = {{}};
}}
{config}

const mozhiSelfHostedFonts = true;
_flutter.loader.load({{}});
"""

# The build's files (path -> contents).
FILES = {
    "index.html": INDEX,
    "main.dart.js": "main();",
    "main.dart.js_1.part.js": "part();",
    "flutter.js": "loader();",
    "manifest.json": "{}",
    "version.json": '{"version": "1"}',
    "assets/AssetManifest.bin.json": '"x"',
    "assets/fonts/MaterialIcons-Regular.otf": "OTTO",
    "canvaskit/canvaskit.js": "ck();",
    "canvaskit/canvaskit.wasm": "\0asm full",
    "canvaskit/chromium/canvaskit.wasm": "\0asm chromium",
    "canvaskit/skwasm.wasm": "\0asm skwasm",
    "canvaskit/skwasm_heavy.js": "heavy();",
    "canvaskit/wimp.wasm": "\0asm wimp",
    "canvaskit/webparagraph/canvaskit.wasm": "\0asm paragraph",
    "bergamot/worker.js": "worker();",
    "bergamot/bergamot-translator.wasm": "\0asm bergamot",
    "fallback_fonts/notosanssc/v37/a.woff2": "wOF2 sc",
    "icons/Icon 192.png": "png",
    # Left out:
    "flutter_service_worker.js": "unregister();",
    ".last_build_id": "abc",
    "main.dart.js.map": "{}",
    "canvaskit/canvaskit.js.symbols": "symbols",
    "models/bergamot/de-en/v1/model.deen.intgemm.alphas.bin.gz": "model",
    "bergamot/de-en/v1/vocab.deen.spm.gz": "model",
    "assets/.DS_Store": "finder",
}

LISTED = [
    "assets/AssetManifest.bin.json",
    "assets/fonts/MaterialIcons-Regular.otf",
    "bergamot/bergamot-translator.wasm",
    "bergamot/worker.js",
    "canvaskit/canvaskit.js",
    "canvaskit/canvaskit.wasm",
    "canvaskit/chromium/canvaskit.wasm",
    "canvaskit/skwasm.wasm",
    "canvaskit/skwasm_heavy.js",
    "canvaskit/webparagraph/canvaskit.wasm",
    "canvaskit/wimp.wasm",
    "fallback_fonts/notosanssc/v37/a.woff2",
    "flutter.js",
    "icons/Icon%20192.png",
    "index.html",
    "main.dart.js",
    "main.dart.js_1.part.js",
    "manifest.json",
    "version.json",
]

LAZY = {
    "fallback_fonts/notosanssc/v37/a.woff2",
    "canvaskit/webparagraph/canvaskit.wasm",
    "canvaskit/skwasm.wasm",
    "canvaskit/skwasm_heavy.js",
    "canvaskit/wimp.wasm",
}


class Case(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.build = Path(self.temp.name) / "build" / "web"
        for path, text in FILES.items():
            file = self.build / path
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text(text, encoding="utf-8")
        (self.build / "flutter_bootstrap.js").write_text(BOOTSTRAP.format(config=DART2JS))
        shutil.copyfile(WORKER, self.build / shell.WORKER)

    def tearDown(self):
        self.temp.cleanup()

    def manifest(self) -> dict:
        return json.loads((self.build / shell.MANIFEST).read_text(encoding="utf-8"))

    def entries(self) -> dict[str, dict]:
        return {entry["path"]: entry for entry in self.manifest()["files"]}

    def worker(self) -> str:
        return (self.build / shell.WORKER).read_text(encoding="utf-8")


class ManifestTest(Case):
    def test_lists_the_files_of_the_build_with_sizes_and_hashes(self):
        result = shell.write(self.build)

        manifest = self.manifest()
        self.assertEqual(manifest["schemaVersion"], 1)
        self.assertEqual(manifest["version"], result.version)
        self.assertEqual(sorted(self.entries()), sorted(LISTED + ["flutter_bootstrap.js"]))
        self.assertEqual([e["path"] for e in manifest["files"]], sorted(e["path"] for e in manifest["files"]))
        main = self.entries()["main.dart.js"]
        self.assertEqual(main["size"], len(b"main();"))
        self.assertEqual(main["sha256"], hashlib.sha256(b"main();").hexdigest())
        self.assertNotIn("lazy", main)
        self.assertEqual(result.files, len(LISTED) + 1)

    def test_marks_fonts_and_unused_renderers_lazy(self):
        result = shell.write(self.build)

        lazy = {path for path, entry in self.entries().items() if entry.get("lazy")}
        self.assertEqual(lazy, LAZY)
        sizes = {path: entry["size"] for path, entry in self.entries().items()}
        self.assertEqual(result.lazy_bytes, sum(sizes[path] for path in LAZY))
        self.assertEqual(result.precached_bytes, sum(sizes.values()) - result.lazy_bytes)

    def test_keeps_the_skwasm_renderer_of_a_webassembly_build(self):
        (self.build / "flutter_bootstrap.js").write_text(BOOTSTRAP.format(config=DART2WASM))
        shell.write(self.build)

        lazy = {path for path, entry in self.entries().items() if entry.get("lazy")}
        self.assertEqual(lazy, {"fallback_fonts/notosanssc/v37/a.woff2", "canvaskit/webparagraph/canvaskit.wasm"})

    def test_keeps_every_renderer_when_the_build_config_is_unreadable(self):
        for config in ["", "_flutter.buildConfig = {not json};", '_flutter.buildConfig = ["x"];']:
            with self.subTest(config):
                (self.build / "flutter_bootstrap.js").write_text(BOOTSTRAP.format(config=config))
                self.assertTrue(shell.wasm_build(self.build))
        (self.build / "flutter_bootstrap.js").unlink()
        self.assertTrue(shell.wasm_build(self.build))

    def test_hashes_index_html_without_its_base_href(self):
        shell.write(self.build)
        first = self.entries()["index.html"]
        self.assertTrue(first["base"])
        expected = INDEX.replace('<base href="/"', '<base href=""').encode()
        self.assertEqual(first["sha256"], hashlib.sha256(expected).hexdigest())
        self.assertEqual(first["size"], len(expected))
        version = self.manifest()["version"]

        # Served from a sub-path: the manifest stays valid.
        index = self.build / "index.html"
        index.write_text(INDEX.replace('href="/"', 'href="/mozhi/app/"'))
        shell.write(self.build)
        self.assertEqual(self.entries()["index.html"], first)
        self.assertEqual(self.manifest()["version"], version)

    def test_without_base_href_empties_only_the_first(self):
        html = b'<BASE  href="/a/"><base href="/b/">'
        self.assertEqual(shell.without_base_href(html), b'<base href=""><base href="/b/">')
        self.assertEqual(shell.without_base_href(b"<p>no base</p>"), b"<p>no base</p>")

    def test_stamps_the_version_and_the_paths_into_the_worker(self):
        result = shell.write(self.build)

        script = self.worker()
        self.assertIn(f'const SHELL_VERSION = "{result.version}";', script)
        files_line = next(line for line in script.splitlines() if line.startswith("const SHELL_FILES = "))
        paths = json.loads(files_line[len("const SHELL_FILES = ") : -1])
        self.assertEqual(paths, [entry["path"] for entry in self.manifest()["files"]])
        # The rest of the worker is unchanged.
        template = WORKER.read_text(encoding="utf-8")
        self.assertEqual(
            [line for line in script.splitlines() if not line.startswith("const SHELL_")],
            [line for line in template.splitlines() if not line.startswith("const SHELL_")],
        )

    def test_is_idempotent(self):
        shell.write(self.build)
        manifest = (self.build / shell.MANIFEST).read_bytes()
        worker = (self.build / shell.WORKER).read_bytes()

        shell.write(self.build)

        self.assertEqual((self.build / shell.MANIFEST).read_bytes(), manifest)
        self.assertEqual((self.build / shell.WORKER).read_bytes(), worker)

    def test_a_changed_file_is_a_new_version(self):
        first = shell.write(self.build).version
        (self.build / "main.dart.js_1.part.js").write_text("part(2);")
        second = shell.write(self.build).version
        self.assertNotEqual(first, second)
        self.assertIn(f'"{second}"', self.worker())
        (self.build / "fallback_fonts/notosanssc/v37/b.woff2").write_text("wOF2 more")
        self.assertNotEqual(shell.write(self.build).version, second)

    def test_needs_a_web_build_with_the_worker(self):
        (self.build / shell.WORKER).unlink()
        with self.assertRaisesRegex(shell.SetupError, "mozhi_sw.js is missing"):
            shell.write(self.build)
        (self.build / "index.html").unlink()
        with self.assertRaisesRegex(shell.SetupError, "not a web build"):
            shell.write(self.build)

    def test_needs_the_lines_to_stamp(self):
        for script in ["self.addEventListener('fetch', () => {});", WORKER.read_text() * 2]:
            with self.subTest(len(script)):
                (self.build / shell.WORKER).write_text(script)
                with self.assertRaisesRegex(shell.SetupError, "web/mozhi_sw.js"):
                    shell.write(self.build)
        self.assertFalse((self.build / shell.MANIFEST).exists())

    def test_listed(self):
        for path in ["index.html", "bergamot/worker.js", "assets/packages/a/b.json", "fallback_fonts/a/v1/x.woff2"]:
            with self.subTest(path):
                self.assertTrue(shell.listed(path))
        for path in [
            "mozhi_sw.js",
            "mozhi_sw_manifest.json",
            "flutter_service_worker.js",
            ".last_build_id",
            "assets/.hidden/x.json",
            "main.dart.js.map",
            "canvaskit/skwasm.js.symbols",
            "models/whisper/ggml-tiny.bin",
            "bergamot/en-de/v1/model.ende.intgemm.alphas.bin.gz",
        ]:
            with self.subTest(path):
                self.assertFalse(shell.listed(path))


class MainTest(Case):
    def test_prints_what_it_wrote(self):
        out = io.StringIO()
        with redirect_stdout(out):
            self.assertEqual(shell.main([str(self.build)]), 0)
        self.assertRegex(out.getvalue(), r"App shell [0-9a-f]{12}: 20 files, .* MB kept at the install")

    def test_reports_setup_errors(self):
        (self.build / "index.html").unlink()
        err = io.StringIO()
        with redirect_stderr(err):
            self.assertEqual(shell.main([str(self.build)]), 2)
        self.assertIn("not a web build", err.getvalue())

    def test_runs_as_a_script(self):
        run = subprocess.run(
            [sys.executable, str(TOOL), str(self.build)],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertTrue((self.build / shell.MANIFEST).is_file())


# Runs the worker's own manifest and index.html checks on what the tool
# wrote: the stamped script (with stand-ins for the worker's globals) and
# the files, from Node.js.
NODE_CHECK = r"""
const fs = require('node:fs');
const [script, manifestPath, indexPath] = process.argv.slice(1);
globalThis.self = {
  registration: { scope: 'https://example.org/mozhi/' },
  addEventListener() {},
};
const source = fs.readFileSync(script, 'utf8');
const worker = new Function(
  `${source}\nreturn { SHELL_VERSION, SHELL_FILES, FILES, CACHE, parseManifest, verified };`,
)();
(async () => {
  const text = fs.readFileSync(manifestPath, 'utf8');
  const manifest = worker.parseManifest(text);
  const index = manifest.files.find((entry) => entry.path === 'index.html');
  const kept = await worker.verified(index, new Response(fs.readFileSync(indexPath)));
  const wrong = await worker.verified(index, new Response('<html>'));
  let rejected = false;
  try {
    worker.parseManifest(JSON.stringify({ schemaVersion: 1, files: [{ path: '../x', size: 1, sha256: '0'.repeat(64) }] }));
  } catch (_) {
    rejected = true;
  }
  console.log(JSON.stringify({
    version: worker.SHELL_VERSION,
    manifestVersion: manifest.version,
    files: worker.SHELL_FILES.length,
    known: worker.FILES.has('main.dart.js') && !worker.FILES.has('mozhi_sw.js'),
    cache: worker.CACHE,
    kept: kept !== null && (await kept.text()) === fs.readFileSync(indexPath, 'utf8'),
    type: kept && kept.headers.get('Content-Type'),
    wrong: wrong === null,
    rejected,
  }));
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
"""


@unittest.skipIf(shutil.which("node") is None, "Node.js is not installed")
class WorkerReadsTheManifestTest(Case):
    def test_the_worker_accepts_the_manifest_and_checks_index_html(self):
        result = shell.write(self.build)
        # An index.html edited for a sub-path still passes the worker's check.
        (self.build / "index.html").write_text(INDEX.replace('href="/"', 'href="/mozhi/"'))
        run = subprocess.run(
            [
                "node",
                "-e",
                NODE_CHECK,
                str(self.build / shell.WORKER),
                str(self.build / shell.MANIFEST),
                str(self.build / "index.html"),
            ],
            capture_output=True,
            text=True,
            check=False,
            timeout=60,
        )
        self.assertEqual(run.returncode, 0, run.stderr)
        report = json.loads(run.stdout)
        self.assertEqual(
            report,
            {
                "version": result.version,
                "manifestVersion": result.version,
                "files": result.files,
                "known": True,
                "cache": f"mozhi-shell:/mozhi/:{result.version}",
                "kept": True,
                "type": "text/html",
                "wrong": True,
                "rejected": True,
            },
        )


if __name__ == "__main__":
    unittest.main()
