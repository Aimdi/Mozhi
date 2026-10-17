#!/bin/sh
# Tests for tool/check_no_google.sh on synthetic APKs: minimal dex files
# (header, string, type and class tables) zipped like an APK or app bundle.
# Needs python3 (and unzip for the byte-scan fallback case).
#
#   sh tool/check_no_google_test.sh
set -eu
# Keep GitHub Actions annotations of the checker out of CI logs.
unset GITHUB_ACTIONS || :

here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
script="$here/check_no_google.sh"
command -v python3 >/dev/null 2>&1 || {
  echo "check_no_google_test: python3 is required" >&2
  exit 2
}

work=$(mktemp -d "${TMPDIR:-/tmp}/check_no_google_test.XXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 2' HUP INT TERM

# Fixtures: <name>.apk / .aab in $work.
python3 -I - "$work" <<'PY'
import hashlib
import struct
import sys
import zipfile
import zlib

work = sys.argv[1]


def uleb128(value):
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def make_dex(defined=(), referenced=(), strings=(), version=b"035"):
    """A dex file defining the classes in `defined` and referring to the
    types in `referenced` (descriptors), with extra constant `strings`."""
    types = sorted(set(defined) | set(referenced))
    all_strings = sorted(set(types) | set(strings))
    index = {s: i for i, s in enumerate(all_strings)}
    header_size = 0x70
    string_ids_off = header_size
    type_ids_off = string_ids_off + 4 * len(all_strings)
    class_defs_off = type_ids_off + 4 * len(types)
    data_off = class_defs_off + 32 * len(defined)
    data = bytearray()
    string_offsets = []
    for s in all_strings:
        string_offsets.append(data_off + len(data))
        raw = s.encode("utf-8")
        data += uleb128(len(s)) + raw + b"\x00"
    body = bytearray()
    for offset in string_offsets:
        body += struct.pack("<I", offset)
    for t in types:
        body += struct.pack("<I", index[t])
    no_index = 0xFFFFFFFF
    for d in sorted(defined):
        body += struct.pack("<8I", types.index(d), 1, no_index, 0, no_index,
                            0, 0, 0)
    file_size = data_off + len(data)
    header = bytearray(b"dex\n" + version + b"\x00")
    header += b"\x00" * 24  # checksum + signature, filled in below
    header += struct.pack(
        "<20I",
        file_size, header_size, 0x12345678,
        0, 0,  # link_size, link_off
        0,  # map_off (unused by the checker)
        len(all_strings), string_ids_off if all_strings else 0,
        len(types), type_ids_off if types else 0,
        0, 0, 0, 0, 0, 0,  # proto, field and method ids
        len(defined), class_defs_off if defined else 0,
        len(data), data_off)
    assert len(header) == header_size
    dex = header + body + data
    dex[12:32] = hashlib.sha1(bytes(dex[32:])).digest()
    dex[8:12] = struct.pack("<I", zlib.adler32(bytes(dex[12:])))
    return bytes(dex)


def axml(*names):
    # Not real binary XML: the checker only looks for the strings, which
    # binary XML stores as UTF-16LE.
    return b"\x03\x00\x08\x00" + b"".join(n.encode("utf-16-le") for n in names)


APP = ["Lio/github/aimdi/mozhi/MainActivity;",
       "Landroidx/core/app/ActivityCompat;",
       # Open-source Google libraries the F-Droid build may keep.
       "Lcom/google/crypto/tink/Aead;",
       "Lcom/google/android/material/color/DynamicColors;"]
REFS = ["Ljava/lang/Object;", "Lcom/google/android/play/core/tasks/Task;"]


def apk(name, entries):
    with zipfile.ZipFile("%s/%s" % (work, name), "w") as z:
        for entry, content in entries.items():
            z.writestr(entry, content)


apk("clean.apk", {
    "AndroidManifest.xml": axml("io.github.aimdi.mozhi"),
    "classes.dex": make_dex(APP, REFS, strings=["com.google.android.gms"]),
    "lib/arm64-v8a/libflutter.so": b"\x7fELF",
})
apk("mlkit.apk", {
    "AndroidManifest.xml": axml("io.github.aimdi.mozhi"),
    "classes.dex": make_dex(APP, REFS),
    "classes2.dex": make_dex(
        ["Lcom/google/mlkit/nl/translate/Translator;",
         "Lcom/google/mlkit/common/MlKitException;"],
        ["Lcom/google/android/gms/tasks/Task;"]),
})
apk("referenced.apk", {
    "classes.dex": make_dex(APP, REFS + ["Lcom/google/android/gms/tasks/Task;",
                                         "[Lcom/google/firebase/Foo;"]),
})
apk("firebase.apk", {
    "classes.dex": make_dex(
        APP + ["Lcom/google/firebase/components/Component;",
               "Lcom/google/android/datatransport/runtime/TransportRuntime;",
               "Lcom/google/android/datatransport/Event$1;"], REFS),
})
apk("manifest_only.apk", {
    "AndroidManifest.xml": axml(
        "com.google.android.gms.metadata.ModuleDependencies"),
    "classes.dex": make_dex(APP, REFS),
})
apk("native.apk", {
    "classes.dex": make_dex(APP, REFS),
    "lib/arm64-v8a/libtranslate_jni.so": b"\x7fELF",
})
apk("corrupt.apk", {
    "classes.dex": b"dex\n035\x00" + b"\xff" * 40
                   + b"Lcom/google/firebase/FirebaseApp;" + b"\x00" * 8,
})
apk("bundle.aab", {
    "base/manifest/AndroidManifest.xml": b"io.github.aimdi.mozhi",
    "base/dex/classes.dex": make_dex(
        APP + ["Lcom/google/android/gms/common/GoogleApiAvailability;"], REFS),
})
apk("bundle_clean.aab", {
    "base/dex/classes.dex": make_dex(APP, REFS),
})
apk("nodex.apk", {"AndroidManifest.xml": axml("io.github.aimdi.mozhi")})
apk("dex041.apk", {
    "classes.dex": make_dex(["Lcom/google/mlkit/vision/text/Text;"], [],
                            version=b"041"),
})
with open("%s/not_a_zip.apk" % work, "wb") as f:
    f.write(b"not a zip")
PY

passed=0
failures=0

# run <name> <expected status> [args...]: runs the checker, keeps its output
# in $out.
run() {
  name=$1
  expected=$2
  shift 2
  status=0
  out=$(sh "$script" "$@" 2>&1) || status=$?
  if [ "$status" -ne "$expected" ]; then
    echo "FAIL $name: exit $status, expected $expected" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    failures=$((failures + 1))
    return 1
  fi
  return 0
}

# expect <name> <text>: $out of the last run contains <text>.
expect() {
  case $out in
    *"$2"*) ;;
    *)
      echo "FAIL $1: output lacks '$2'" >&2
      printf '%s\n' "$out" | sed 's/^/    /' >&2
      failures=$((failures + 1))
      return 1
      ;;
  esac
}

# reject <name> <text>: $out of the last run does not contain <text>.
reject() {
  case $out in
    *"$2"*)
      echo "FAIL $1: output contains '$2'" >&2
      printf '%s\n' "$out" | sed 's/^/    /' >&2
      failures=$((failures + 1))
      return 1
      ;;
  esac
}

# t <name>: records a pass when no failure was added since $mark.
t() {
  if [ "$failures" -eq "$mark" ]; then
    passed=$((passed + 1))
    echo "ok   $1"
  fi
}

mark=$failures
if run clean 0 "$work/clean.apk"; then
  expect clean "OK"
  reject clean "com/google/crypto"
fi
t "clean APK passes (Tink, Material, Play Core refs and string constants are fine)"

mark=$failures
if run mlkit 1 "$work/mlkit.apk"; then
  expect mlkit "Lcom/google/mlkit/nl/translate/Translator;"
  expect mlkit "Lcom/google/mlkit/common/MlKitException;"
  expect mlkit "classes2.dex"
  expect mlkit "Lcom/google/android/gms/tasks/Task;"
  expect mlkit "FAILED"
fi
t "ML Kit classes in classes2.dex fail"

mark=$failures
if run referenced 1 "$work/referenced.apk"; then
  expect referenced "referenced Lcom/google/android/gms/tasks/Task;"
  expect referenced "Lcom/google/firebase/Foo;"
fi
t "referenced-only Google types fail by default"

mark=$failures
if run referenced-defined-only 0 --defined-only "$work/referenced.apk"; then
  expect referenced-defined-only "warning"
  expect referenced-defined-only "OK"
fi
t "--defined-only turns references into warnings"

mark=$failures
if run firebase 1 "$work/firebase.apk"; then
  expect firebase "Lcom/google/firebase/components/Component;"
  expect firebase "Lcom/google/android/datatransport/runtime/TransportRuntime;"
  expect firebase 'Lcom/google/android/datatransport/Event$1;'
fi
t "Firebase and data transport classes fail"

mark=$failures
if run max 1 --max 1 "$work/firebase.apk"; then
  expect max "and 1 more"
fi
t "--max limits the listing"

mark=$failures
if run manifest 0 "$work/manifest_only.apk"; then
  expect manifest "warning: AndroidManifest.xml mentions com.google.android.gms"
fi
t "manifest mentions are warnings only"

mark=$failures
if run native 1 "$work/native.apk"; then
  expect native "lib/arm64-v8a/libtranslate_jni.so"
fi
t "ML Kit native libraries fail"

mark=$failures
run native-dex-only 0 --dex-only "$work/native.apk" || :
t "--dex-only skips the native library check"

mark=$failures
if run corrupt 1 "$work/corrupt.apk"; then
  expect corrupt "byte scan"
  expect corrupt "Lcom/google/firebase/FirebaseApp;"
fi
t "unparsable dex falls back to a byte scan"

mark=$failures
if run bundle 1 "$work/bundle.aab"; then
  expect bundle "Lcom/google/android/gms/common/GoogleApiAvailability;"
fi
t "app bundle (base/dex/classes.dex) is checked"

mark=$failures
run bundle-clean 0 "$work/bundle_clean.aab" || :
t "clean app bundle passes"

mark=$failures
if run dex041 1 "$work/dex041.apk"; then
  expect dex041 "Lcom/google/mlkit/vision/text/Text;"
fi
t "DEX 041 file is parsed"

mark=$failures
if run nodex 2 "$work/nodex.apk"; then
  expect nodex "no classes"
fi
t "APK without dex is an error"

mark=$failures
run not-a-zip 2 "$work/not_a_zip.apk" || :
t "non-zip input is an error"

mark=$failures
run missing 2 "$work/missing.apk" || :
t "missing file is an error"

mark=$failures
if run usage 2; then
  expect usage "usage:"
fi
t "no arguments prints usage"

mark=$failures
run help 0 --help || :
t "--help exits 0"

mark=$failures
run bad-option 2 --nope "$work/clean.apk" || :
t "unknown option is an error"

mark=$failures
status=0
out=$(GITHUB_ACTIONS=true sh "$script" "$work/mlkit.apk" 2>&1) || status=$?
if [ "$status" -eq 1 ]; then
  expect github "::error::"
else
  echo "FAIL github: exit $status, expected 1" >&2
  failures=$((failures + 1))
fi
t "GitHub Actions annotation"

# Byte-scan fallback without python3: a PATH that has unzip, grep and the
# basic tools but no python3.
if command -v unzip >/dev/null 2>&1; then
  bin="$work/bin"
  mkdir -p "$bin"
  for tool in sh unzip grep sort head sed find mktemp rm cat; do
    path=$(command -v "$tool" 2>/dev/null) || continue
    ln -s "$path" "$bin/$tool"
  done
  mark=$failures
  status=0
  out=$(PATH="$bin" "$bin/sh" "$script" "$work/mlkit.apk" 2>&1) || status=$?
  if [ "$status" -eq 1 ]; then
    expect fallback "python3 not found"
    expect fallback "Lcom/google/mlkit/nl/translate/Translator;"
  else
    echo "FAIL fallback: exit $status, expected 1" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    failures=$((failures + 1))
  fi
  t "fallback without python3 finds ML Kit (byte scan)"

  mark=$failures
  status=0
  out=$(PATH="$bin" "$bin/sh" "$script" "$work/clean.apk" 2>&1) || status=$?
  if [ "$status" -eq 0 ]; then
    expect fallback-clean "OK"
  else
    echo "FAIL fallback-clean: exit $status, expected 0" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    failures=$((failures + 1))
  fi
  t "fallback without python3 passes a clean APK"
else
  echo "skip fallback tests (no unzip)"
fi

echo "check_no_google_test: $passed passed, $failures failed"
[ "$failures" -eq 0 ]
