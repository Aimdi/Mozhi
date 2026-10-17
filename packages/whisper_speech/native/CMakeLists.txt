# libmozhi_whisper: the C API in src/mozhi_whisper.h over whisper.cpp (MIT)
# and the ggml it vendors (MIT), with ggml's CPU backend only.
#
# whisper.cpp is a pinned git submodule under third_party/ (see
# ../tool/fetch_native_deps.sh). Nothing is downloaded at configure or build
# time; no OpenMP, BLAS, GPU (Vulkan, OpenCL, CUDA, Metal), Core ML,
# OpenVINO or KleidiAI code is compiled in.
#
# Used by the Android Gradle build (../android/build.gradle, one configure per
# ABI with the NDK toolchain) and by ../tool/build_native_linux.sh (the
# library the Dart tests load).
cmake_minimum_required(VERSION 3.22)

project(mozhi_whisper C CXX)

set(MOZHI_WHISPER_CPP_DIR
    "${CMAKE_CURRENT_SOURCE_DIR}/third_party/whisper.cpp"
    CACHE PATH "Checkout of github.com/ggml-org/whisper.cpp")

foreach(_required
    "${MOZHI_WHISPER_CPP_DIR}/CMakeLists.txt"
    "${MOZHI_WHISPER_CPP_DIR}/include/whisper.h"
    "${MOZHI_WHISPER_CPP_DIR}/ggml/CMakeLists.txt"
    "${MOZHI_WHISPER_CPP_DIR}/ggml/src/ggml-cpu/CMakeLists.txt")
  if(NOT EXISTS "${_required}")
    message(FATAL_ERROR
      "Missing ${_required}.\n"
      "Run packages/whisper_speech/tool/fetch_native_deps.sh first.")
  endif()
endforeach()

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# --- Reproducible builds -------------------------------------------------------
# __FILE__ (GGML_ASSERT, logging) would embed absolute source paths, which
# differ between machines (CI, F-Droid, a developer's checkout). Map the
# repository root (three levels up) to "." and the build directory to
# "build" for every target below, vendored ones included. The last matching
# map wins in GCC and clang, so the more specific ones come last.
get_filename_component(_mozhi_repo_root "${CMAKE_CURRENT_SOURCE_DIR}/../../.."
  ABSOLUTE)
add_compile_options(
  "-ffile-prefix-map=${_mozhi_repo_root}=."
  "-ffile-prefix-map=${CMAKE_BINARY_DIR}=build")
if(ANDROID AND ANDROID_NDK)
  add_compile_options("-ffile-prefix-map=${ANDROID_NDK}=ndk")
endif()
# Lets --gc-sections drop what the C API never reaches (the parakeet model,
# VAD, grammar sampling, ...).
add_compile_options(-ffunction-sections -fdata-sections)

# --- Engine options ------------------------------------------------------------
# CACHE ... FORCE so that option() in whisper.cpp and ggml sees them.
macro(_mozhi_force name value)
  set(${name} ${value} CACHE BOOL "Set by mozhi_whisper" FORCE)
endmacro()
_mozhi_force(BUILD_SHARED_LIBS OFF)       # whisper + ggml linked statically
_mozhi_force(WHISPER_BUILD_IS_DEV OFF)    # pinned release tag: "1.9.5"
_mozhi_force(WHISPER_BUILD_TESTS OFF)
_mozhi_force(WHISPER_BUILD_EXAMPLES OFF)
_mozhi_force(WHISPER_BUILD_SERVER OFF)
_mozhi_force(WHISPER_CURL OFF)
_mozhi_force(WHISPER_SDL2 OFF)
_mozhi_force(WHISPER_COREML OFF)
_mozhi_force(WHISPER_OPENVINO OFF)
_mozhi_force(WHISPER_VITISAI OFF)
_mozhi_force(WHISPER_USE_SYSTEM_GGML OFF)
_mozhi_force(WHISPER_FATAL_WARNINGS OFF)
_mozhi_force(GGML_BUILD_TESTS OFF)
_mozhi_force(GGML_BUILD_EXAMPLES OFF)
_mozhi_force(GGML_BACKEND_DL OFF)         # one library, no dlopen()ed backends
_mozhi_force(GGML_CPU ON)
_mozhi_force(GGML_CPU_ALL_VARIANTS OFF)
_mozhi_force(GGML_CPU_KLEIDIAI OFF)       # would download KleidiAI
_mozhi_force(GGML_CPU_REPACK OFF)         # quantized weights only; ours are F16
_mozhi_force(GGML_CPU_HBM OFF)
_mozhi_force(GGML_LLAMAFILE OFF)
_mozhi_force(GGML_OPENMP OFF)             # ggml's own thread pool
_mozhi_force(GGML_OPENMP_FETCH OFF)
_mozhi_force(GGML_BLAS OFF)
_mozhi_force(GGML_ACCELERATE OFF)
_mozhi_force(GGML_METAL OFF)
_mozhi_force(GGML_CUDA OFF)
_mozhi_force(GGML_HIP OFF)
_mozhi_force(GGML_MUSA OFF)
_mozhi_force(GGML_VULKAN OFF)
_mozhi_force(GGML_OPENCL OFF)
_mozhi_force(GGML_SYCL OFF)
_mozhi_force(GGML_WEBGPU OFF)
_mozhi_force(GGML_RPC OFF)
_mozhi_force(GGML_ZDNN OFF)
_mozhi_force(GGML_HEXAGON OFF)
_mozhi_force(GGML_OPENVINO OFF)
_mozhi_force(GGML_VIRTGPU OFF)
_mozhi_force(GGML_CCACHE OFF)
_mozhi_force(GGML_LTO OFF)
_mozhi_force(GGML_STATIC OFF)             # not -static: this is a shared library
_mozhi_force(GGML_FATAL_WARNINGS OFF)

# --- Target CPU ----------------------------------------------------------------
# A portable baseline per ABI, never the build machine's CPU (GGML_NATIVE).
# ggml can only pick faster kernels at run time with GGML_BACKEND_DL (one
# dlopen()ed library per CPU variant), so each ABI gets one baseline:
#  * arm64-v8a: ARMv8.0-A (NEON; FP16 conversion, no FP16 arithmetic,
#    dotprod or i8mm: Cortex-A53/A57/A72 phones lack them);
#  * armeabi-v7a: NEON + VFPv4 (FMA), like libmozhi_bergamot; Dart checks
#    /proc/cpuinfo before loading;
#  * x86_64: SSE4.2, which the Android x86_64 ABI guarantees (emulators,
#    Chromebooks); no AVX, F16C or FMA.
_mozhi_force(GGML_NATIVE OFF)
foreach(_x86 AVX AVX_VNNI AVX2 BMI2 AVX512 AVX512_VBMI AVX512_VNNI AVX512_BF16
        FMA F16C AMX_TILE AMX_INT8 AMX_BF16)
  _mozhi_force(GGML_${_x86} OFF)
endforeach()
set(GGML_CPU_ARM_ARCH "" CACHE STRING "Set by mozhi_whisper" FORCE)
if(CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|AMD64|amd64)$")
  _mozhi_force(GGML_SSE42 ON)
  set(_cpu "x86-64 + SSE4.2")
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^(aarch64|arm64)$")
  _mozhi_force(GGML_SSE42 OFF)
  set(GGML_CPU_ARM_ARCH "armv8-a" CACHE STRING "Set by mozhi_whisper" FORCE)
  set(_cpu "armv8-a")
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^arm")
  _mozhi_force(GGML_SSE42 OFF)
  set(GGML_CPU_ARM_ARCH "armv7-a" CACHE STRING "Set by mozhi_whisper" FORCE)
  # After the NDK's -mfpu=neon on the command line, so it wins. softfp is
  # the armeabi-v7a calling convention.
  if(ANDROID)
    add_compile_options(-mfpu=neon-vfpv4 -mfloat-abi=softfp -mthumb)
  else()
    add_compile_options(-mfpu=neon-vfpv4 -mthumb)
  endif()
  set(_cpu "armv7-a + NEON-VFPv4")
else()
  message(FATAL_ERROR
    "mozhi_whisper: unsupported CPU ${CMAKE_SYSTEM_PROCESSOR}")
endif()
message(STATUS "mozhi_whisper: CPU baseline ${_cpu}")

# --- whisper.cpp + ggml ----------------------------------------------------------
file(STRINGS "${MOZHI_WHISPER_CPP_DIR}/CMakeLists.txt" _version_lines
  REGEX "^set\\(WHISPER_VERSION_(MAJOR|MINOR|PATCH) [0-9]+\\)")
string(REGEX REPLACE ".*MAJOR ([0-9]+).*MINOR ([0-9]+).*PATCH ([0-9]+).*"
  "\\1.\\2.\\3" _engine_version "${_version_lines}")

# ggml embeds `git rev-parse --short HEAD` (plus "-dirty") of the checkout
# in the library (ggml_commit()). Point git at a repository that does not
# exist while configuring, so it is always "unknown" and the same sources
# give the same library on every machine (a tarball, a dirty checkout).
set(_saved_git_dir "$ENV{GIT_DIR}")
set(ENV{GIT_DIR} "${CMAKE_CURRENT_BINARY_DIR}/no-git-during-configure")
add_subdirectory("${MOZHI_WHISPER_CPP_DIR}" whisper.cpp EXCLUDE_FROM_ALL)
if(_saved_git_dir)
  set(ENV{GIT_DIR} "${_saved_git_dir}")
else()
  unset(ENV{GIT_DIR})
endif()

# Vendored code: a newer compiler (the NDK's clang) must not fail the build
# or flood it over new warnings.
foreach(_target whisper ggml ggml-base ggml-cpu)
  if(TARGET ${_target})
    target_compile_options(${_target} PRIVATE -w)
  endif()
endforeach()

# --- The shim ----------------------------------------------------------------------

add_library(mozhi_whisper SHARED src/mozhi_whisper.cc)
set_target_properties(mozhi_whisper PROPERTIES
  CXX_STANDARD 17
  CXX_STANDARD_REQUIRED ON
  CXX_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN ON)
target_compile_definitions(mozhi_whisper PRIVATE
  MOZHI_WHISPER_ENGINE_VERSION="${_engine_version}")
target_link_libraries(mozhi_whisper PRIVATE whisper)

if(NOT APPLE AND NOT WIN32)
  set(_map "${CMAKE_CURRENT_SOURCE_DIR}/src/mozhi_whisper.map")
  target_link_options(mozhi_whisper PRIVATE
    "-Wl,--version-script=${_map}" "-Wl,--gc-sections" "-Wl,--no-undefined")
  set_property(TARGET mozhi_whisper APPEND PROPERTY LINK_DEPENDS "${_map}")
endif()
if(ANDROID)
  # 16 KB page sizes (Android 15+); NDK r28 already defaults to this.
  target_link_options(mozhi_whisper PRIVATE "-Wl,-z,max-page-size=16384")
  target_link_libraries(mozhi_whisper PRIVATE log)
endif()

install(TARGETS mozhi_whisper LIBRARY DESTINATION lib)

# Smoke-test / benchmark CLI (not part of the app): `--target mozhi_whisper_cli`.
add_executable(mozhi_whisper_cli EXCLUDE_FROM_ALL tool/mozhi_whisper_cli.c)
target_link_libraries(mozhi_whisper_cli PRIVATE mozhi_whisper)
if(NOT ANDROID AND NOT APPLE AND NOT WIN32)
  set_target_properties(mozhi_whisper_cli PROPERTIES BUILD_RPATH "$ORIGIN")
endif()
