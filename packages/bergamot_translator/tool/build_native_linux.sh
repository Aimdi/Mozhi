#!/usr/bin/env bash
# Builds libmozhi_bergamot.so for the host (Linux) so the Dart tests can load
# the real engine.
#
# Usage: packages/bergamot_translator/tool/build_native_linux.sh [build-dir]
#
# Output: <build-dir>/libmozhi_bergamot.so, by default
#   packages/bergamot_translator/build/native/linux/libmozhi_bergamot.so
# which is where the tests look unless BERGAMOT_LIBRARY_PATH is set.
#
# Needs cmake (>= 3.22), a C++17 compiler (gcc >= 9 or clang >= 10) and,
# optionally, ninja. Environment:
#   BERGAMOT_ARCH  -march value (default x86-64-v2 / armv8-a; "native" is
#                  fastest but not portable)
#   BERGAMOT_JOBS  parallel jobs (default: all cores)
#   CMAKE_ARGS     extra cmake arguments (e.g. -DCMAKE_CXX_COMPILER=clang++)
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${1:-${package_dir}/build/native/linux}"
jobs="${BERGAMOT_JOBS:-$(nproc 2>/dev/null || echo 4)}"

"${package_dir}/tool/fetch_native_deps.sh" >/dev/null

generator=()
if command -v ninja >/dev/null 2>&1; then
  generator=(-G Ninja)
fi

args=(-DCMAKE_BUILD_TYPE=Release)
if [ -n "${BERGAMOT_ARCH:-}" ]; then
  args+=("-DMOZHI_BERGAMOT_ARCH=${BERGAMOT_ARCH}")
fi
# shellcheck disable=SC2206 # CMAKE_ARGS is split on purpose.
extra=(${CMAKE_ARGS:-})

cmake -S "${package_dir}/native" -B "$build_dir" "${generator[@]}" \
  "${args[@]}" "${extra[@]}"
cmake --build "$build_dir" --target mozhi_bergamot --parallel "$jobs"

library="${build_dir}/libmozhi_bergamot.so"
if [ ! -f "$library" ]; then
  echo "error: ${library} was not produced" >&2
  exit 1
fi
echo "Built ${library} ($(du -h "$library" | cut -f1))"
