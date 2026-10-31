#!/usr/bin/env bash
# Builds libmozhi_whisper.so for the host (Linux) so the Dart tests can load
# the real engine.
#
# Usage: packages/whisper_speech/tool/build_native_linux.sh [build-dir]
#
# Output: <build-dir>/libmozhi_whisper.so, by default
#   packages/whisper_speech/build/native/linux/libmozhi_whisper.so
# which is where the tests look unless WHISPER_LIBRARY_PATH is set. The
# host build uses the same portable CPU baseline as Android (x86-64 with
# SSE4.2, or ARMv8.0-A), so it is slower than a -march=native build.
#
# Needs cmake (>= 3.22), a C++17 compiler (gcc >= 9 or clang >= 10) and,
# optionally, ninja and ccache (used when installed; CI caches it).
# Environment:
#   WHISPER_JOBS          parallel jobs (default: all cores)
#   WHISPER_CPU_VARIANTS  also build CPU variants, `<name>=<march>` separated
#                         by `;` (default: none), e.g. `native=native` builds
#                         libmozhi_whisper_native.so and
#                         mozhi_whisper_native_cli to compare with the
#                         baseline (the arm64 Android variants are
#                         `dotprod=armv8.2-a+dotprod+fp16` and
#                         `i8mm=armv8.6-a+dotprod+fp16+i8mm`)
#   CMAKE_ARGS            extra cmake arguments (e.g.
#                         -DCMAKE_CXX_COMPILER=clang++)
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${1:-${package_dir}/build/native/linux}"
jobs="${WHISPER_JOBS:-$(nproc 2>/dev/null || echo 4)}"

"${package_dir}/tool/fetch_native_deps.sh" >/dev/null

generator=()
if command -v ninja >/dev/null 2>&1; then
  generator=(-G Ninja)
fi

launcher=()
if command -v ccache >/dev/null 2>&1; then
  launcher=(-DCMAKE_C_COMPILER_LAUNCHER=ccache
    -DCMAKE_CXX_COMPILER_LAUNCHER=ccache)
fi

# shellcheck disable=SC2206 # CMAKE_ARGS is split on purpose.
extra=(${CMAKE_ARGS:-})

variants="${WHISPER_CPU_VARIANTS:-}"
targets=(mozhi_whisper mozhi_whisper_cli)
if [ -n "$variants" ]; then
  IFS=';' read -ra entries <<< "$variants"
  for entry in "${entries[@]}"; do
    targets+=("mozhi_whisper_${entry%%=*}" "mozhi_whisper_${entry%%=*}_cli")
  done
fi

# The variants are always passed (empty: none), so an earlier run's stay
# out of the cache.
cmake -S "${package_dir}/native" -B "$build_dir" "${generator[@]}" \
  -DCMAKE_BUILD_TYPE=Release "-DMOZHI_WHISPER_CPU_VARIANTS=${variants}" \
  "${launcher[@]}" "${extra[@]}"
cmake --build "$build_dir" --target "${targets[@]}" --parallel "$jobs"

library="${build_dir}/libmozhi_whisper.so"
if [ ! -f "$library" ]; then
  echo "error: ${library} was not produced" >&2
  exit 1
fi
echo "Built ${library} ($(du -h "$library" | cut -f1))"
