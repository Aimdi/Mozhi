# libmozhi_bergamot: the C API in src/mozhi_bergamot.h over Mozilla's
# Firefox Translations inference engine (bergamot-translator, MPL-2.0, with
# its Marian fork, MIT), plus PCRE2 (BSD-3-Clause) for the sentence splitter
# and CLD2 (Apache-2.0) for language identification.
#
# All are pinned git submodules under third_party/ (see
# ../tool/fetch_native_deps.sh, which initialises only the nested submodules
# the CPU engine needs). Nothing is downloaded at configure or build time.
#
# Used by the Android Gradle build (../android/build.gradle, one configure per
# ABI with the NDK toolchain) and by ../tool/build_native_linux.sh (the
# library the Dart tests load).
cmake_minimum_required(VERSION 3.22)

project(mozhi_bergamot C CXX)

set(MOZHI_BERGAMOT_TRANSLATIONS_DIR
    "${CMAKE_CURRENT_SOURCE_DIR}/third_party/translations"
    CACHE PATH "Checkout of github.com/mozilla/translations")
set(MOZHI_BERGAMOT_PCRE2_DIR
    "${CMAKE_CURRENT_SOURCE_DIR}/third_party/pcre2"
    CACHE PATH "Checkout of github.com/PCRE2Project/pcre2")
set(MOZHI_BERGAMOT_CLD2_DIR
    "${CMAKE_CURRENT_SOURCE_DIR}/third_party/cld2"
    CACHE PATH "Checkout of github.com/CLD2Owners/cld2")
set(MOZHI_BERGAMOT_ARCH ""
    CACHE STRING "Marian BUILD_ARCH (-march value); empty picks one per target")

set(_inference "${MOZHI_BERGAMOT_TRANSLATIONS_DIR}/inference")
set(_marian_3rd "${_inference}/marian-fork/src/3rd_party")
foreach(_required
    "${_inference}/CMakeLists.txt"
    "${_inference}/3rd_party/ssplit-cpp/CMakeLists.txt"
    "${_marian_3rd}/sentencepiece/CMakeLists.txt"
    "${_marian_3rd}/ruy/third_party/cpuinfo/CMakeLists.txt"
    "${MOZHI_BERGAMOT_PCRE2_DIR}/CMakeLists.txt"
    "${MOZHI_BERGAMOT_CLD2_DIR}/internal/compact_lang_det_impl.cc")
  if(NOT EXISTS "${_required}")
    message(FATAL_ERROR
      "Missing ${_required}.\n"
      "Run packages/bergamot_translator/tool/fetch_native_deps.sh first.")
  endif()
endforeach()

# native/patches/ must be applied (fetch_native_deps.sh does it).
file(STRINGS "${_marian_3rd}/../tensors/cpu/integer_common.h" _patched
  REGEX "std::memcpy\\(&quantMult")
if(NOT _patched)
  message(FATAL_ERROR
    "native/patches/ are not applied to ${MOZHI_BERGAMOT_TRANSLATIONS_DIR}.\n"
    "Run packages/bergamot_translator/tool/fetch_native_deps.sh first.")
endif()

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# --- Reproducible builds -------------------------------------------------------
# __FILE__ (Marian's ABORT/logging macros, asserts) would embed ~200
# absolute source paths, which differ between machines (CI, F-Droid, a
# developer's checkout). Map the repository root (three levels up) to "."
# and the build directory to "build" for every target below, vendored ones
# included (directory options reach every add_subdirectory). The last
# matching map wins in GCC and clang, so the more specific ones come last.
# -ffile-prefix-map also covers debug info (-fdebug-prefix-map).
get_filename_component(_mozhi_repo_root "${CMAKE_CURRENT_SOURCE_DIR}/../../.."
  ABSOLUTE)
add_compile_options(
  "-ffile-prefix-map=${_mozhi_repo_root}=."
  "-ffile-prefix-map=${CMAKE_BINARY_DIR}=build")
if(ANDROID AND ANDROID_NDK)
  add_compile_options("-ffile-prefix-map=${ANDROID_NDK}=ndk")
endif()

# --- Target CPU --------------------------------------------------------------
# Marian replaces CMAKE_CXX_FLAGS with "-march=${BUILD_ARCH} ..." in its
# directories, so the target CPU (and FPU on 32-bit ARM) goes through
# BUILD_ARCH. x86_64 additionally gets -msse4.1 from Marian (guaranteed by
# the Android x86_64 ABI); intgemm dispatches AVX2/AVX-512 kernels at runtime.
if(MOZHI_BERGAMOT_ARCH)
  set(_arch "${MOZHI_BERGAMOT_ARCH}")
elseif(ANDROID)
  if(ANDROID_ABI STREQUAL "arm64-v8a")
    set(_arch "armv8-a")
  elseif(ANDROID_ABI STREQUAL "armeabi-v7a")
    # NEON with VFPv4 (FMA): Cortex-A5/A7/A12/A15/A17 and every ARMv8 core in
    # 32-bit mode. Dart checks /proc/cpuinfo for "vfpv4" before loading.
    set(_arch "armv7-a -mfpu=neon-vfpv4 -mfloat-abi=softfp -mthumb")
  elseif(ANDROID_ABI STREQUAL "x86_64")
    set(_arch "x86-64")
  else()
    message(FATAL_ERROR "Unsupported ANDROID_ABI ${ANDROID_ABI}")
  endif()
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|AMD64|amd64)$")
  set(_arch "x86-64-v2")
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^(aarch64|arm64)$")
  set(_arch "armv8-a")
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^arm")
  set(_arch "armv7-a -mfpu=neon-vfpv4 -mfloat-abi=hard -mthumb")
else()
  set(_arch "native")
endif()
set(BUILD_ARCH "${_arch}" CACHE STRING "Marian target architecture" FORCE)
message(STATUS "mozhi_bergamot: BUILD_ARCH=${BUILD_ARCH}")

# Marian's flags only reach Marian's own directories. Every other target
# (bergamot's translator sources, PCRE2, SentencePiece, this shim) must be
# compiled for the same CPU, or the headers they share with Marian take
# different code paths (e.g. NEON vs SSE emulation on 32-bit ARM).
separate_arguments(_arch_flags UNIX_COMMAND "-march=${_arch}")
if(CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|AMD64|amd64)$"
   AND NOT _arch STREQUAL "native")
  list(APPEND _arch_flags -msse4.1)
endif()
add_compile_options(${_arch_flags})

if(CMAKE_SYSTEM_PROCESSOR MATCHES "^(aarch64|arm64|arm)")
  # simd_utils.h (Marian's SSE-on-NEON layer, ARM only) calls fesetround()
  # without including <fenv.h>; only some C++ libraries include it already.
  add_compile_options("SHELL:-include fenv.h")
endif()
if(CMAKE_SYSTEM_PROCESSOR MATCHES "^arm" AND NOT CMAKE_SYSTEM_PROCESSOR MATCHES "^arm64")
  # AArch64-only NEON intrinsics used by simd_utils and Marian's ruy glue.
  add_compile_options(
    "SHELL:-include ${CMAKE_CURRENT_SOURCE_DIR}/src/armv7_neon_compat.h")
endif()

# --- Engine options ------------------------------------------------------------
# CACHE ... FORCE so that option() in every subproject (including those
# without policy CMP0077) sees them.
macro(_mozhi_force name value)
  set(${name} ${value} CACHE BOOL "Set by mozhi_bergamot" FORCE)
endmacro()
_mozhi_force(GIT_SUBMODULE OFF)          # bergamot: no submodule updates
_mozhi_force(COMPILE_WASM OFF)
_mozhi_force(USE_WASM_COMPATIBLE_SOURCE OFF)
_mozhi_force(COMPILE_TESTS OFF)
_mozhi_force(COMPILE_UNIT_TESTS OFF)
_mozhi_force(COMPILE_PYTHON OFF)
_mozhi_force(COMPILE_LIBRARY_ONLY ON)    # marian: no executables
_mozhi_force(COMPILE_CPU ON)
_mozhi_force(COMPILE_CUDA OFF)
_mozhi_force(COMPILE_SERVER OFF)
_mozhi_force(COMPILE_EXAMPLES OFF)
_mozhi_force(USE_CUDNN OFF)
_mozhi_force(USE_DOXYGEN OFF)
_mozhi_force(USE_FBGEMM OFF)
_mozhi_force(USE_MKL OFF)
_mozhi_force(USE_MPI OFF)
_mozhi_force(USE_NCCL OFF)
_mozhi_force(USE_CCACHE OFF)
# Float GEMM: there is no MKL/OpenBLAS on Android, so use Google's ruy on
# every target (Marian already does on ARM). Int8 GEMM is intgemm on x86
# and ruy on ARM.
_mozhi_force(USE_RUY ON)
_mozhi_force(USE_RUY_SGEMM ON)
_mozhi_force(USE_SENTENCEPIECE ON)
_mozhi_force(USE_STATIC_LIBS ON)
_mozhi_force(GENERATE_MARIAN_INSTALL_TARGETS OFF)
# Marian configures the spm_* tools (not built: EXCLUDE_FROM_ALL below).
_mozhi_force(SPM_BUILD_LIBRARY_ONLY OFF)
_mozhi_force(SPM_ENABLE_SHARED OFF)
_mozhi_force(SPM_ENABLE_TCMALLOC OFF)
_mozhi_force(SPM_USE_BUILTIN_PROTOBUF ON)
_mozhi_force(SSPLIT_COMPILE_LIBRARY_ONLY ON)
_mozhi_force(SSPLIT_USE_INTERNAL_PCRE2 OFF)
_mozhi_force(SSPLIT_PREFER_STATIC_COMPILE ON)

# --- PCRE2 (static, 8-bit, no JIT: no executable memory needed) ----------------
_mozhi_force(BUILD_SHARED_LIBS OFF)
_mozhi_force(BUILD_STATIC_LIBS ON)
_mozhi_force(PCRE2_BUILD_PCRE2_8 ON)
_mozhi_force(PCRE2_BUILD_PCRE2_16 OFF)
_mozhi_force(PCRE2_BUILD_PCRE2_32 OFF)
_mozhi_force(PCRE2_STATIC_PIC ON)
_mozhi_force(PCRE2_SUPPORT_JIT OFF)
_mozhi_force(PCRE2_SUPPORT_UNICODE ON)
_mozhi_force(PCRE2_BUILD_PCRE2GREP OFF)
_mozhi_force(PCRE2_BUILD_TESTS OFF)
_mozhi_force(PCRE2_BUILD_DOCS OFF)
_mozhi_force(PCRE2_SUPPORT_LIBBZ2 OFF)
_mozhi_force(PCRE2_SUPPORT_LIBZ OFF)
_mozhi_force(PCRE2_SUPPORT_LIBEDIT OFF)
_mozhi_force(PCRE2_SUPPORT_LIBREADLINE OFF)
_mozhi_force(PCRE2_SHOW_REPORT OFF)
add_subdirectory("${MOZHI_BERGAMOT_PCRE2_DIR}" pcre2 EXCLUDE_FROM_ALL)
# ssplit's FindPCRE2 keeps these instead of searching the system.
set(PCRE2_LIBRARIES pcre2-8-static CACHE STRING "Set by mozhi_bergamot" FORCE)
set(PCRE2_INCLUDE_DIRS "${CMAKE_CURRENT_BINARY_DIR}/pcre2/interface"
    CACHE PATH "Set by mozhi_bergamot" FORCE)

# --- Bergamot + Marian -----------------------------------------------------------
file(STRINGS "${_inference}/BERGAMOT_VERSION" _engine_version LIMIT_COUNT 1)

# Marian generates src/common/git_revision.h with `git log`, depending on
# <gitdir>/logs/HEAD, which it resolves relative to the wrong directory when
# mozilla/translations is a submodule (the build then fails with "missing
# and no known rule to make it"). Replace that one rule with a git-free,
# deterministic header; every other add_custom_command call is unchanged.
function(add_custom_command)
  if(ARGC GREATER 1 AND ARGV0 STREQUAL "OUTPUT"
     AND ARGV1 MATCHES "/marian-fork/src/common/git_revision\\.h$")
    _add_custom_command(OUTPUT "${ARGV1}"
      COMMAND "${CMAKE_COMMAND}" "-DOUTPUT=${ARGV1}"
              "-DREVISION=${_engine_version} (mozilla/translations)"
              -P "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/cmake/write_git_revision.cmake"
      VERBATIM)
  else()
    _add_custom_command(${ARGV})
  endif()
endfunction()

# Marian's CMakeLists runs `git submodule update --init --recursive` while
# configuring, which would clone every submodule of mozilla/translations
# (training tools, emsdk, ...) into the source tree. Point git at a
# repository that does not exist for the duration of the configure step, so
# that command (and bergamot's `git rev-parse`) fail harmlessly.
set(_saved_git_dir "$ENV{GIT_DIR}")
set(ENV{GIT_DIR} "${CMAKE_CURRENT_BINARY_DIR}/no-git-during-configure")
add_subdirectory("${_inference}" bergamot EXCLUDE_FROM_ALL)
if(_saved_git_dir)
  set(ENV{GIT_DIR} "${_saved_git_dir}")
else()
  unset(ENV{GIT_DIR})
endif()

# Marian compiles the values of every CMake cache variable into the library
# (build_info.cpp, for `marian --build-info`): absolute paths of the
# checkout, the build directory, the compiler, the NDK and system
# libraries. Replace the generated file with a fixed one, so the same
# sources give the same library on every machine. (Re-written on each
# configure, after Marian's version: one small file recompiles.)
get_directory_property(_marian_binary_dir
  DIRECTORY "${_inference}/marian-fork" BINARY_DIR)
set(_build_info "${_marian_binary_dir}/src/common/build_info.cpp")
if(NOT EXISTS "${_build_info}")
  message(FATAL_ERROR "Marian no longer generates ${_build_info}; "
    "update the reproducible-build override in native/CMakeLists.txt.")
endif()
file(WRITE "${_build_info}" "\
// Written by packages/bergamot_translator/native/CMakeLists.txt instead of
// Marian's list of CMake cache variables (machine-specific paths).
#include \"common/build_info.h\"

std::string marian::cmakeBuildOptions() {
  return \"mozhi_bergamot: BUILD_ARCH=${BUILD_ARCH}\\n\";
}

std::string marian::cmakeBuildOptionsAdvanced() {
  return marian::cmakeBuildOptions();
}
")

# Marian adds its configuration (ARM FMA SSE / USE_INTGEMM, USE_RUY_SGEMM,
# -flax-vector-conversions, ...) as directory properties, which do not reach
# bergamot's translator sources (a sibling directory) or this shim. Its
# headers depend on them (e.g. the SSE-on-NEON layer on ARM), so every
# translation unit must agree: forward them through the bergamot target.
get_directory_property(_marian_definitions
  DIRECTORY "${_inference}/marian-fork/src" COMPILE_DEFINITIONS)
get_directory_property(_marian_options
  DIRECTORY "${_inference}/marian-fork/src" COMPILE_OPTIONS)
message(STATUS "mozhi_bergamot: Marian definitions: ${_marian_definitions}")
target_compile_definitions(bergamot-translator-source PUBLIC
  ${_marian_definitions})
target_compile_options(bergamot-translator-source PUBLIC ${_marian_options})

# Marian and intgemm compile themselves with -Werror. A newer compiler (the
# NDK's clang) must not fail the build over new warnings in vendored code.
foreach(_target marian intgemm)
  if(TARGET ${_target})
    target_compile_options(${_target} PRIVATE -Wno-error)
  endif()
endforeach()

# faiss uses SSE/SSE3 intrinsics (__m128, _mm_hadd_ps) under `#ifdef __SSE__`
# but only includes <x86intrin.h> on Apple; libstdc++ pulls the headers in
# transitively, the NDK's libc++ does not (Android x86_64 failed with
# "unknown type name '__m128'"). SSE3 itself is enabled by -msse4.1.
if(TARGET faiss AND CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|AMD64|amd64|i.86)$")
  target_compile_options(faiss PRIVATE -include immintrin.h)
endif()

if(ANDROID AND TARGET pathie-cpp)
  # Bionic declares iconv only from API 28 (minSdk is lower). Android paths
  # are always UTF-8, so pathie never converts and iconv is never called.
  target_compile_definitions(pathie-cpp PRIVATE
    PATHIE_ASSUME_UTF8_ON_UNIX __ANDROID_UNAVAILABLE_SYMBOLS_ARE_WEAK__)
endif()

# --- CLD2 (language identification) -------------------------------------------------
# Compact Language Detector 2, plain C++ without dependencies, built like
# its internal/compile_libs.sh "libcld2" with the "chrome" tables: 83
# languages in ~1.8 MB (the "full" 0122 tables, 165 languages, are ~6.5 MB:
# 4.7 MB more per ABI). debug_empty.cc instead of debug.cc: no HTML debug
# output. Its scoring tables are static const, so it is thread-safe.
set(_cld2 "${MOZHI_BERGAMOT_CLD2_DIR}/internal")
add_library(mozhi_cld2 STATIC
  "${_cld2}/cldutil.cc"
  "${_cld2}/cldutil_shared.cc"
  "${_cld2}/compact_lang_det.cc"
  "${_cld2}/compact_lang_det_hint_code.cc"
  "${_cld2}/compact_lang_det_impl.cc"
  "${_cld2}/debug_empty.cc"
  "${_cld2}/fixunicodevalue.cc"
  "${_cld2}/generated_entities.cc"
  "${_cld2}/generated_language.cc"
  "${_cld2}/generated_ulscript.cc"
  "${_cld2}/getonescriptspan.cc"
  "${_cld2}/lang_script.cc"
  "${_cld2}/offsetmap.cc"
  "${_cld2}/scoreonescriptspan.cc"
  "${_cld2}/tote.cc"
  "${_cld2}/utf8statetable.cc"
  "${_cld2}/cld_generated_cjk_uni_prop_80.cc"
  "${_cld2}/cld2_generated_cjk_compatible.cc"
  "${_cld2}/cld_generated_cjk_delta_bi_4.cc"
  "${_cld2}/generated_distinct_bi_0.cc"
  "${_cld2}/cld2_generated_quadchrome_2.cc"
  "${_cld2}/cld2_generated_deltaoctachrome.cc"
  "${_cld2}/cld2_generated_distinctoctachrome.cc"
  "${_cld2}/cld_generated_score_quad_octa_2.cc")
set_target_properties(mozhi_cld2 PROPERTIES
  CXX_STANDARD 17
  CXX_STANDARD_REQUIRED ON
  CXX_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN ON)
target_include_directories(mozhi_cld2 PUBLIC "${MOZHI_BERGAMOT_CLD2_DIR}/public")
# The 2014 generated tables initialise uint8 arrays with negative constants
# (e.g. -14 for 0xF2), an error since C++11 in GCC and clang (the NDK's
# clang 19 too); the values wrap exactly as CLD2 intends (Chrome built it
# with the same flag). -w: vendored code, its other warnings are noise.
target_compile_options(mozhi_cld2 PRIVATE -w -Wno-narrowing)

# --- The shim ----------------------------------------------------------------------

add_library(mozhi_bergamot SHARED src/mozhi_bergamot.cc)
set_target_properties(mozhi_bergamot PROPERTIES
  CXX_STANDARD 17
  CXX_STANDARD_REQUIRED ON
  CXX_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN ON)
target_compile_definitions(mozhi_bergamot PRIVATE
  MOZHI_BERGAMOT_ENGINE_VERSION="${_engine_version}")
target_link_libraries(mozhi_bergamot PRIVATE bergamot-translator-source
  mozhi_cld2)

if(NOT APPLE AND NOT WIN32)
  set(_map "${CMAKE_CURRENT_SOURCE_DIR}/src/mozhi_bergamot.map")
  target_link_options(mozhi_bergamot PRIVATE
    "-Wl,--version-script=${_map}" "-Wl,--gc-sections" "-Wl,--no-undefined")
  set_property(TARGET mozhi_bergamot APPEND PROPERTY LINK_DEPENDS "${_map}")
endif()
if(ANDROID)
  # 16 KB page sizes (Android 15+); NDK r28 already defaults to this.
  target_link_options(mozhi_bergamot PRIVATE "-Wl,-z,max-page-size=16384")
  target_link_libraries(mozhi_bergamot PRIVATE log)
endif()

install(TARGETS mozhi_bergamot LIBRARY DESTINATION lib)

# Smoke-test / benchmark CLI (not part of the app): `--target mozhi_bergamot_cli`.
add_executable(mozhi_bergamot_cli EXCLUDE_FROM_ALL tool/mozhi_bergamot_cli.c)
target_link_libraries(mozhi_bergamot_cli PRIVATE mozhi_bergamot)
if(NOT ANDROID AND NOT APPLE AND NOT WIN32)
  set_target_properties(mozhi_bergamot_cli PROPERTIES BUILD_RPATH "$ORIGIN")
endif()
