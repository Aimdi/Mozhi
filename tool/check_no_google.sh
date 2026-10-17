#!/bin/sh
# Fails when an Android APK (or app bundle) contains classes from Google ML
# Kit, Google Play services, Firebase or Google's data transport (Firelog)
# library: the closed-source / tracking code the default build (GitHub
# releases, F-Droid) must not ship (docs/audit/2026-audit.md,
# docs/contributing.md "Build variants").
#
#   tool/check_no_google.sh [options] <app.apk|app.aab>
#
# No Android SDK needed (no apkanalyzer, dexdump or aapt): python3 reads the
# APK as a zip, parses the string, type and class tables of every
# classes*.dex and reports each type descriptor under
#
#   Lcom/google/mlkit/  Lcom/google/android/gms/  Lcom/google/firebase/
#   Lcom/google/android/datatransport/
#
# both classes defined in the APK and classes its code only refers to.
# Without python3 it falls back to a byte scan of the dex files (unzip and
# grep), which cannot tell the two apart.
#
# CI runs it on every APK of the default build (job "Build Android APKs" in
# .github/workflows/main.yaml, and the release workflow). It also fails on
# zip entries that look like ML Kit's native libraries or models (mlkit,
# translate_jni, language_id, text_recognition). Mentions of
# those packages in AndroidManifest.xml (for example image_picker's disabled
# com.google.android.gms.metadata.ModuleDependencies service) are only
# reported as warnings: a manifest entry is not code.
#
# Limitation: R8 can rename classes that have no keep rule, and renamed
# classes no longer carry their package name. ML Kit, Play services and
# Firebase keep the names their native code, manifest entries and reflection
# need, so a build that pulls them in still shows many matches; for a full
# picture also check the Gradle runtime classpath.
#
# Exit status: 0 nothing found, 1 Google classes (or ML Kit files) found,
# 2 usage error or unreadable input.
set -eu

me=check_no_google

usage() {
  cat <<'EOF'
usage: tool/check_no_google.sh [options] <app.apk|app.aab>

Fails (exit 1) when a classes*.dex of the APK or app bundle contains a class
descriptor under com/google/mlkit, com/google/android/gms,
com/google/firebase or com/google/android/datatransport, and prints them.

options:
  --defined-only  fail only for classes defined in the APK; classes that
                  are merely referenced become warnings
  --dex-only      skip the check for ML Kit native libraries and models
                  among the zip entries
  --max N         list at most N classes per package (default 50; 0 = all)
  -h, --help      show this help

Exit status: 0 clean, 1 found, 2 usage error or unreadable input.
EOF
}

defined_only=0
dex_only=0
max=50
while [ "$#" -gt 0 ]; do
  case $1 in
    -h | --help)
      usage
      exit 0
      ;;
    --defined-only) defined_only=1 ;;
    --dex-only) dex_only=1 ;;
    --max)
      [ "$#" -ge 2 ] || {
        echo "$me: --max needs a number" >&2
        exit 2
      }
      max=$2
      shift
      ;;
    --max=*) max=${1#--max=} ;;
    --)
      shift
      break
      ;;
    -?*)
      echo "$me: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *) break ;;
  esac
  shift
done

if [ "$#" -ne 1 ]; then
  usage >&2
  exit 2
fi
case $max in
  '' | *[!0-9]*)
    echo "$me: --max needs a number, got '$max'" >&2
    exit 2
    ;;
esac
apk=$1
if [ ! -f "$apk" ]; then
  echo "$me: no such file: $apk" >&2
  exit 2
fi

if command -v python3 >/dev/null 2>&1; then
  # -I: isolated mode, so nothing next to the APK or in PYTHON* variables
  # is imported.
  exec python3 -I - "$apk" "$defined_only" "$dex_only" "$max" <<'PY'
import os
import re
import struct
import sys
import zipfile

ME = "check_no_google"
PREFIXES = (
    "com/google/mlkit/",
    "com/google/android/gms/",
    "com/google/firebase/",
    "com/google/android/datatransport/",
)
DEX_ENTRY = re.compile(r"(^|/)classes\d*\.dex$")
MANIFEST_ENTRY = re.compile(r"(^|/)AndroidManifest\.xml$")
# Zip entries of ML Kit's native libraries and bundled models (the same
# pattern as the CI job).
MLKIT_ENTRY = re.compile(r"mlkit|translate_jni|language_id|text_recognition", re.I)
BYTE_PATTERN = re.compile(
    rb"L(com/google/(?:mlkit|android/gms|firebase|android/datatransport)/"
    rb"[A-Za-z0-9_$/\-]*);"
)
MANIFEST_NEEDLES = ("com.google.mlkit", "com.google.android.gms",
                    "com.google.firebase", "com.google.android.datatransport")
DEX_MAGIC = re.compile(rb"dex\n0[0-9]{2}\x00")
ENDIAN_CONSTANT = 0x12345678
HEADER_SIZE = 0x70


class DexError(Exception):
    pass


def u32(data, offset):
    if offset < 0 or offset + 4 > len(data):
        raise DexError("offset 0x%x out of range" % offset)
    return struct.unpack_from("<I", data, offset)[0]


def uleb128(data, pos):
    result = shift = 0
    while True:
        if pos >= len(data):
            raise DexError("truncated string data")
        byte = data[pos]
        pos += 1
        result |= (byte & 0x7F) << shift
        if byte < 0x80:
            return result, pos
        shift += 7
        if shift > 28:
            raise DexError("malformed uleb128")


def check_table(data, base, size, offset, item_size, what):
    if size == 0:
        return
    start = base + offset
    if offset == 0 or start + size * item_size > len(data):
        raise DexError("%s table out of range" % what)


def read_string(data, base, index, string_ids_off):
    data_off = u32(data, base + string_ids_off + 4 * index)
    _, pos = uleb128(data, base + data_off)
    end = data.find(b"\x00", pos)
    if end < 0:
        raise DexError("unterminated string")
    # MUTF-8; descriptors of the packages we look for are plain ASCII.
    return data[pos:end].decode("utf-8", "replace")


def parse_one(data, start, base):
    """Type descriptors and defined classes of the dex whose header is at
    start; table offsets are relative to base."""
    if data[start + 40:start + 44] != struct.pack("<I", ENDIAN_CONSTANT):
        raise DexError("not a little-endian dex file")
    header = struct.unpack_from("<26I", data, start + 8)
    # Fields after magic: checksum, signature (5 words), file_size,
    # header_size, endian_tag, link_size, link_off, map_off,
    # string_ids_size/off, type_ids_size/off, proto_ids, field_ids,
    # method_ids, class_defs_size/off, data_size/off.
    file_size = header[6]
    string_ids_size, string_ids_off = header[12], header[13]
    type_ids_size, type_ids_off = header[14], header[15]
    class_defs_size, class_defs_off = header[22], header[23]
    check_table(data, base, string_ids_size, string_ids_off, 4, "string_ids")
    check_table(data, base, type_ids_size, type_ids_off, 4, "type_ids")
    check_table(data, base, class_defs_size, class_defs_off, 32, "class_defs")
    types = []
    for i in range(type_ids_size):
        string_index = u32(data, base + type_ids_off + 4 * i)
        if string_index >= string_ids_size:
            raise DexError("type %d names string %d of %d"
                           % (i, string_index, string_ids_size))
        types.append(read_string(data, base, string_index, string_ids_off))
    defined = set()
    for i in range(class_defs_size):
        type_index = u32(data, base + class_defs_off + 32 * i)
        if type_index >= len(types):
            raise DexError("class %d names type %d of %d"
                           % (i, type_index, len(types)))
        defined.add(types[type_index])
    return set(types), defined, file_size


def parse_dex(data):
    """[(types, defined)] for a dex file; DEX 041 containers may hold
    several dex files one after another."""
    if not DEX_MAGIC.match(data[:8]):
        raise DexError("bad magic %r" % data[:8])
    version = int(data[4:7])
    if version < 41:
        types, defined, _ = parse_one(data, 0, 0)
        return [(types, defined)]
    results = []
    start = 0
    while start + HEADER_SIZE <= len(data):
        if not DEX_MAGIC.match(data[start:start + 8]):
            raise DexError("bad magic at 0x%x" % start)
        last_error = None
        for base in (0, start):  # container- or header-relative offsets
            try:
                types, defined, size = parse_one(data, start, base)
                break
            except DexError as error:
                last_error = error
        else:
            raise last_error
        results.append((types, defined))
        if size <= 0:
            break
        start += size
    return results


def flagged(descriptor):
    name = descriptor.lstrip("[")
    if not (name.startswith("L") and name.endswith(";")):
        return None
    for prefix in PREFIXES:
        if name.startswith("L" + prefix):
            return prefix, name
    return None


def main(argv):
    # Keep the report (stdout) and the warnings/verdict (stderr) in order.
    sys.stdout.reconfigure(line_buffering=True)
    path, defined_only, dex_only, max_shown = (
        argv[1], argv[2] == "1", argv[3] == "1", int(argv[4]))
    annotate = os.environ.get("GITHUB_ACTIONS") == "true"
    try:
        archive = zipfile.ZipFile(path)
    except (zipfile.BadZipFile, OSError) as error:
        print("%s: %s is not an APK or app bundle: %s" % (ME, path, error),
              file=sys.stderr)
        return 2
    # descriptor -> {"defined": bool, "where": set of dex entries}
    found = {}
    scanned = []
    fallbacks = []
    type_count = 0
    with archive:
        names = archive.namelist()
        dex_names = [n for n in names if DEX_ENTRY.search(n)]
        if not dex_names:
            print("%s: %s contains no classes*.dex" % (ME, path),
                  file=sys.stderr)
            return 2
        for name in dex_names:
            data = archive.read(name)
            scanned.append(name)
            try:
                for types, defined in parse_dex(data):
                    type_count += len(types)
                    for descriptor in types:
                        hit = flagged(descriptor)
                        if hit is None:
                            continue
                        entry = found.setdefault(
                            hit[1], {"defined": False, "where": set()})
                        entry["where"].add(name)
                        if descriptor in defined:
                            entry["defined"] = True
            except (DexError, struct.error, ValueError) as error:
                # Unparsable dex: fall back to the byte scan, counting
                # every match as a class of the APK.
                fallbacks.append((name, str(error)))
                for match in BYTE_PATTERN.finditer(data):
                    descriptor = "L%s;" % match.group(1).decode("ascii")
                    entry = found.setdefault(
                        descriptor, {"defined": True, "where": set()})
                    entry["defined"] = True
                    entry["where"].add(name + " (byte scan)")
        entries = [] if dex_only else [
            n for n in names
            if MLKIT_ENTRY.search(n) and not DEX_ENTRY.search(n)]
        manifest_hits = set()
        for name in names:
            if not MANIFEST_ENTRY.search(name):
                continue
            data = archive.read(name)
            for needle in MANIFEST_NEEDLES:
                if (needle.encode("utf-16-le") in data
                        or needle.encode("ascii") in data):
                    manifest_hits.add((name, needle))

    for name, error in fallbacks:
        print("%s: warning: could not parse %s (%s); used a byte scan"
              % (ME, name, error), file=sys.stderr)
    for name, needle in sorted(manifest_hits):
        print("%s: warning: %s mentions %s (not code; check the merged "
              "manifest)" % (ME, name, needle), file=sys.stderr)

    failing = 0
    for prefix in PREFIXES:
        group = sorted(d for d in found if d.startswith("L" + prefix))
        if not group:
            continue
        defined = [d for d in group if found[d]["defined"]]
        referenced = [d for d in group if not found[d]["defined"]]
        fatal = len(defined) + (0 if defined_only else len(referenced))
        failing += fatal
        label = "error" if fatal else "warning"
        print("%s: %s: %s: %d defined, %d referenced only"
              % (ME, label, prefix.rstrip("/").replace("/", "."),
                 len(defined), len(referenced)))
        listed = defined + referenced
        shown = listed if max_shown == 0 else listed[:max_shown]
        for descriptor in shown:
            kind = "defined   " if found[descriptor]["defined"] else "referenced"
            print("  %s %s  [%s]" % (kind, descriptor,
                                     ", ".join(sorted(found[descriptor]["where"]))))
        if len(shown) < len(listed):
            print("  ... and %d more (--max 0 lists all)"
                  % (len(listed) - len(shown)))
    if entries:
        failing += len(entries)
        print("%s: error: ML Kit native libraries or models:" % ME)
        for name in entries:
            print("  " + name)

    if failing:
        message = ("%s contains Google ML Kit / Play services / Firebase / "
                   "data transport code (%d findings)" % (path, failing))
        if annotate:
            print("::error::" + message)
        print("%s: FAILED: %s" % (ME, message), file=sys.stderr)
        return 1
    print("%s: OK: %s: %d dex file(s), %d types, no class under %s"
          % (ME, path, len(scanned), type_count,
             ", ".join(p.rstrip("/") for p in PREFIXES)))
    return 0


sys.exit(main(sys.argv))
PY
fi

# Fallback without python3: unzip the dex files and grep their bytes.
command -v unzip >/dev/null 2>&1 || {
  echo "$me: python3 or unzip is required" >&2
  exit 2
}
echo "$me: warning: python3 not found; byte scan of the dex files only" >&2
work=$(mktemp -d "${TMPDIR:-/tmp}/$me.XXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 2' HUP INT TERM
if ! unzip -l "$apk" >"$work/entries" 2>/dev/null; then
  echo "$me: $apk is not an APK or app bundle" >&2
  exit 2
fi
unzip -qq -o "$apk" 'classes*.dex' '*/classes*.dex' -d "$work/dex" \
  >/dev/null 2>&1 || true
dex_files=$(find "$work/dex" -type f -name 'classes*.dex' 2>/dev/null || true)
if [ -z "$dex_files" ]; then
  echo "$me: $apk contains no classes*.dex" >&2
  exit 2
fi
failed=0
# shellcheck disable=SC2086 # dex paths come from mktemp and contain no spaces
if matches=$(LC_ALL=C grep -a -o -h -E \
  'Lcom/google/(mlkit|android/gms|firebase|android/datatransport)/[A-Za-z0-9_$/-]*;' \
  $dex_files | sort -u); then
  if [ -n "$matches" ]; then
    echo "$me: error: Google classes (byte scan):"
    if [ "$max" -gt 0 ]; then
      printf '%s\n' "$matches" | head -n "$max" | sed 's/^/  /'
    else
      printf '%s\n' "$matches" | sed 's/^/  /'
    fi
    failed=1
  fi
fi
if [ "$dex_only" = 0 ] &&
  entries=$(grep -i -E 'mlkit|translate_jni|language_id|text_recognition' "$work/entries"); then
  echo "$me: error: ML Kit native libraries or models:"
  printf '%s\n' "$entries" | sed 's/^/  /'
  failed=1
fi
if [ "$failed" = 1 ]; then
  echo "$me: FAILED: $apk contains Google ML Kit / Play services / Firebase / data transport code" >&2
  exit 1
fi
echo "$me: OK: $apk: no class under com/google/mlkit, com/google/android/gms, com/google/firebase, com/google/android/datatransport (byte scan)"
