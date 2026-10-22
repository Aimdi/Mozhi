#!/usr/bin/env bash
# Builds libmozhi_llama.so for the host (Linux) so the Dart tests can load
# the real engine.
#
# Usage: packages/llama_engine/tool/build_native_linux.sh [build-dir]
#
# Output: <build-dir>/libmozhi_llama.so, by default
#   packages/llama_engine/build/native/linux/libmozhi_llama.so
# which is where the tests look unless LLAMA_LIBRARY_PATH is set (plus the
# CLI, mozhi_llama_cli). The host build uses the same portable CPU baseline
# as Android (x86-64 with SSE4.2, or ARMv8.0-A), so it is slower than a
# -march=native build. For arm64 it also builds the dotprod and i8mm
# variants (libmozhi_llama_dotprod.so, libmozhi_llama_i8mm.so, and a CLI
# for each).
#
# Needs cmake (>= 3.22), a C++17 compiler (gcc >= 9 or clang >= 10) and,
# optionally, ninja and ccache. Environment:
#   LLAMA_JOBS  parallel jobs (default: all cores)
#   CMAKE_ARGS  extra cmake arguments (e.g. -DCMAKE_CXX_COMPILER=clang++, or
#               a cross toolchain)
# ccache is used when it is installed (CI caches it).
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${1:-${package_dir}/build/native/linux}"
jobs="${LLAMA_JOBS:-$(nproc 2>/dev/null || echo 4)}"

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

cmake -S "${package_dir}/native" -B "$build_dir" "${generator[@]}" \
  -DCMAKE_BUILD_TYPE=Release "${launcher[@]}" "${extra[@]}"

# The variants (and their CLIs) exist only for arm64 targets.
targets=(mozhi_llama mozhi_llama_cli)
for variant in dotprod i8mm; do
  if cmake --build "$build_dir" --target help 2>/dev/null |
    grep -q "mozhi_llama_${variant}\b"; then
    targets+=("mozhi_llama_${variant}" "mozhi_llama_${variant}_cli")
  fi
done
cmake --build "$build_dir" --target "${targets[@]}" --parallel "$jobs"

library="${build_dir}/libmozhi_llama.so"
if [ ! -f "$library" ]; then
  echo "error: ${library} was not produced" >&2
  exit 1
fi
for built in "$build_dir"/libmozhi_llama*.so; do
  echo "Built ${built} ($(du -h "$built" | cut -f1))"
done
