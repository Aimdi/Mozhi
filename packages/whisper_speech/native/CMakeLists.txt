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
# grammar sampling, ...). Silero VAD stays: mozhi_whisper_vad_* uses it
# (whisper_vad_*), so the linker keeps it.
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
# A portable baseline per ABI, never the build machine's CPU (GGML_NATIVE):
#  * arm64-v8a: ARMv8.0-A (NEON; FP16 conversion, no FP16 arithmetic,
#    dotprod or i8mm: Cortex-A53/A57/A72 phones lack them);
#  * armeabi-v7a: NEON + VFPv4 (FMA), like libmozhi_bergamot; Dart checks
#    /proc/cpuinfo before loading;
#  * x86_64: SSE4.2, which the Android x86_64 ABI guarantees (emulators,
#    Chromebooks); no AVX, F16C or FMA.
# ggml only picks kernels at compile time (or with GGML_BACKEND_DL, one
# dlopen()ed backend per CPU found by scanning a directory, which an APK
# does not have), so arm64-v8a also gets complete libraries for newer CPUs
# (MOZHI_WHISPER_CPU_VARIANTS below), and Dart loads the best one the CPU
# runs (lib/src/engine/cpu_features.dart).
_mozhi_force(GGML_NATIVE OFF)
foreach(_x86 AVX AVX_VNNI AVX2 BMI2 AVX512 AVX512_VBMI AVX512_VNNI AVX512_BF16
        FMA F16C AMX_TILE AMX_INT8 AMX_BF16)
  _mozhi_force(GGML_${_x86} OFF)
endforeach()
set(GGML_CPU_ARM_ARCH "" CACHE STRING "Set by mozhi_whisper" FORCE)
set(_variants "")
if(CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|AMD64|amd64)$")
  _mozhi_force(GGML_SSE42 ON)
  set(_cpu "x86-64+sse4.2")
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^(aarch64|arm64)$")
  _mozhi_force(GGML_SSE42 OFF)
  set(GGML_CPU_ARM_ARCH "armv8-a" CACHE STRING "Set by mozhi_whisper" FORCE)
  set(_cpu "armv8-a")
  # The variants of contract §4 (the CPU features Dart reads from
  # /proc/cpuinfo): dotprod + FP16 arithmetic (Cortex-A55/A75/A76 and
  # later, 2018+), and those + int8 matrix multiply (ARMv9 cores:
  # Cortex-A510/A710/X2 and later, 2022+).
  set(_variants
    "dotprod=armv8.2-a+dotprod+fp16"
    "i8mm=armv8.6-a+dotprod+fp16+i8mm")
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
  set(_cpu "armv7-a+neon-vfpv4")
else()
  message(FATAL_ERROR
    "mozhi_whisper: unsupported CPU ${CMAKE_SYSTEM_PROCESSOR}")
endif()
message(STATUS "mozhi_whisper: CPU baseline ${_cpu}")

# Every <name>=<march> builds libmozhi_whisper_<name>.so (and
# mozhi_whisper_<name>_cli), the same library with ggml's CPU kernels
# compiled for -march=<march>. Defaults: the arm64 variants above, none
# elsewhere. A host build can measure one, e.g.
# -DMOZHI_WHISPER_CPU_VARIANTS=native=native (tool/build_native_linux.sh).
if(NOT DEFINED MOZHI_WHISPER_CPU_VARIANTS)
  set(MOZHI_WHISPER_CPU_VARIANTS "${_variants}" CACHE STRING
    "Extra libmozhi_whisper_<name>.so builds: <name>=<march> list")
endif()

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

# A libmozhi_whisper library: the C API (src/mozhi_whisper.cc), exporting
# nothing else. `cpu` names the CPU it is built for in
# mozhi_whisper_version() ("CPU armv8-a").
function(_mozhi_whisper_library target cpu)
  add_library(${target} SHARED src/mozhi_whisper.cc)
  set_target_properties(${target} PROPERTIES
    CXX_STANDARD 17
    CXX_STANDARD_REQUIRED ON
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON)
  target_compile_definitions(${target} PRIVATE
    MOZHI_WHISPER_ENGINE_VERSION="${_engine_version}"
    MOZHI_WHISPER_CPU="${cpu}")
  if(NOT APPLE AND NOT WIN32)
    set(_map "${CMAKE_CURRENT_SOURCE_DIR}/src/mozhi_whisper.map")
    target_link_options(${target} PRIVATE
      "-Wl,--version-script=${_map}" "-Wl,--gc-sections" "-Wl,--no-undefined")
    set_property(TARGET ${target} APPEND PROPERTY LINK_DEPENDS "${_map}")
  endif()
  if(ANDROID)
    # 16 KB page sizes (Android 15+); NDK r28 already defaults to this.
    target_link_options(${target} PRIVATE "-Wl,-z,max-page-size=16384")
    target_link_libraries(${target} PRIVATE log)
  endif()
  install(TARGETS ${target} LIBRARY DESTINATION lib)

  # Smoke-test / benchmark CLI (not part of the app):
  # `--target <target>_cli`.
  add_executable(${target}_cli EXCLUDE_FROM_ALL tool/mozhi_whisper_cli.c)
  target_link_libraries(${target}_cli PRIVATE ${target})
  if(NOT ANDROID AND NOT APPLE AND NOT WIN32)
    set_target_properties(${target}_cli PROPERTIES BUILD_RPATH "$ORIGIN")
  endif()
endfunction()

# The baseline (every CPU of the ABI).
_mozhi_whisper_library(mozhi_whisper "${_cpu}")
target_link_libraries(mozhi_whisper PRIVATE whisper)

# --- CPU variants ---------------------------------------------------------------
# libmozhi_whisper_<name>.so: the same whisper.cpp and ggml objects, except
# ggml's CPU backend (the only code compiled with -march: the kernels),
# which is compiled again for <march> from ggml's own ggml-cpu target (its
# sources, include directories, definitions and options, so that it follows
# whisper.cpp updates), and linked instead of the baseline one. Nothing of
# the baseline CPU backend is linked in (no `whisper` target dependency,
# which would bring it): the archives are listed explicitly, in a group
# (GNU ld resolves the references between them in any order; lld always
# does).
function(_mozhi_whisper_cpu_variant name march)
  set(_backend mozhi_ggml_cpu_${name})
  get_target_property(_dir ggml-cpu SOURCE_DIR)
  get_target_property(_sources ggml-cpu SOURCES)
  # Relative sources are relative to the directory that defined ggml-cpu.
  list(TRANSFORM _sources PREPEND "${_dir}/" REGEX "^[^/$]")
  add_library(${_backend} STATIC EXCLUDE_FROM_ALL ${_sources})
  foreach(_property
      INCLUDE_DIRECTORIES COMPILE_DEFINITIONS COMPILE_OPTIONS COMPILE_FEATURES
      C_STANDARD C_STANDARD_REQUIRED C_EXTENSIONS
      CXX_STANDARD CXX_STANDARD_REQUIRED CXX_EXTENSIONS
      LINK_LIBRARIES INTERFACE_LINK_LIBRARIES)
    get_target_property(_value ggml-cpu ${_property})
    if(NOT _value STREQUAL "_value-NOTFOUND")
      set_property(TARGET ${_backend} PROPERTY ${_property} "${_value}")
    endif()
  endforeach()
  # Definitions of ggml's directory (_GNU_SOURCE, GGML_SCHED_MAX_COPIES...)
  # apply to every target defined there, so they are not target properties.
  get_directory_property(_definitions DIRECTORY "${_dir}" COMPILE_DEFINITIONS)
  target_compile_definitions(${_backend} PRIVATE ${_definitions})
  # The baseline's -march (GGML_CPU_ARM_ARCH) gives way to the variant's.
  get_target_property(_options ${_backend} COMPILE_OPTIONS)
  list(FILTER _options EXCLUDE REGEX "^-march=")
  list(APPEND _options "-march=${march}")
  set_property(TARGET ${_backend} PROPERTY COMPILE_OPTIONS "${_options}")

  set(_target mozhi_whisper_${name})
  _mozhi_whisper_library(${_target} "${march}")
  target_include_directories(${_target} PRIVATE
    $<TARGET_PROPERTY:whisper,INTERFACE_INCLUDE_DIRECTORIES>
    $<TARGET_PROPERTY:ggml,INTERFACE_INCLUDE_DIRECTORIES>)
  target_compile_definitions(${_target} PRIVATE
    $<TARGET_PROPERTY:ggml,INTERFACE_COMPILE_DEFINITIONS>)
  add_dependencies(${_target} whisper ggml ggml-base ${_backend})
  target_link_libraries(${_target} PRIVATE
    -Wl,--start-group
    $<TARGET_FILE:whisper> $<TARGET_FILE:ggml> $<TARGET_FILE:${_backend}>
    $<TARGET_FILE:ggml-base>
    -Wl,--end-group
    Threads::Threads ${CMAKE_DL_LIBS} m)
  message(STATUS "mozhi_whisper: CPU variant ${_target} (-march=${march})")
endfunction()

find_package(Threads REQUIRED)
foreach(_variant IN LISTS MOZHI_WHISPER_CPU_VARIANTS)
  if(NOT _variant MATCHES "^([a-z0-9]+)=([A-Za-z0-9.+_-]+)$")
    message(FATAL_ERROR
      "mozhi_whisper: MOZHI_WHISPER_CPU_VARIANTS entry \"${_variant}\" is not "
      "<name>=<march>")
  endif()
  _mozhi_whisper_cpu_variant("${CMAKE_MATCH_1}" "${CMAKE_MATCH_2}")
endforeach()

# android/build.gradle lists the arm64-v8a variants as targets for every
# ABI (the Android Gradle plugin may check each ABI's targets). Elsewhere
# an empty static library of the same name stands in: only shared
# libraries are packaged into the APK, so nothing of it ships.
if(ANDROID)
  foreach(_name dotprod i8mm)
    if(NOT TARGET mozhi_whisper_${_name})
      set(_stub "${CMAKE_CURRENT_BINARY_DIR}/mozhi_whisper_${_name}_absent.c")
      file(CONFIGURE OUTPUT "${_stub}" CONTENT
        "/* No mozhi_whisper_${_name} for this ABI (CMakeLists.txt). */\ntypedef int mozhi_whisper_${_name}_absent;\n")
      add_library(mozhi_whisper_${_name} STATIC EXCLUDE_FROM_ALL "${_stub}")
    endif()
  endforeach()
endif()
