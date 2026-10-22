# libmozhi_llama: the C API in src/mozhi_llama.h over llama.cpp (MIT) and
# the ggml it vendors (MIT), with ggml's CPU backend only.
#
# llama.cpp is a pinned git submodule under third_party/ (see
# ../tool/fetch_native_deps.sh). Nothing is downloaded at configure or build
# time; no OpenMP, BLAS, GPU (Vulkan, OpenCL, CUDA, Metal, Hexagon),
# llamafile, KleidiAI, libcurl or OpenSSL code is compiled in.
#
# Libraries (the Dart code picks one at run time from /proc/cpuinfo):
#   mozhi_llama          every ABI: the portable baseline (arm64: ARMv8.0-A,
#                        x86_64: SSE4.2)
#   mozhi_llama_dotprod  arm64 only: ARMv8.2-A + dotprod + fp16
#   mozhi_llama_i8mm     arm64 only: ARMv8.6-A + dotprod + fp16 + i8mm
# Each one links llama + ggml statically. Only ggml's CPU backend differs
# between them (as in ggml's own GGML_CPU_ALL_VARIANTS): it is compiled once
# per variant from the sources and settings of the baseline target, with
# its own -march; llama and ggml-base are compiled once, at the baseline.
# No GGML_BACKEND_DL: Android keeps native libraries inside the APK, and
# ggml's backend loader scans directories.
#
# Used by the Android Gradle build (../android/build.gradle, one configure per
# ABI with the NDK toolchain) and by ../tool/build_native_linux.sh (the
# library the Dart tests load).
cmake_minimum_required(VERSION 3.22)

project(mozhi_llama C CXX)

set(MOZHI_LLAMA_CPP_DIR
    "${CMAKE_CURRENT_SOURCE_DIR}/third_party/llama.cpp"
    CACHE PATH "Checkout of github.com/ggml-org/llama.cpp")

foreach(_required
    "${MOZHI_LLAMA_CPP_DIR}/CMakeLists.txt"
    "${MOZHI_LLAMA_CPP_DIR}/include/llama.h"
    "${MOZHI_LLAMA_CPP_DIR}/grammars/json.gbnf"
    "${MOZHI_LLAMA_CPP_DIR}/ggml/CMakeLists.txt"
    "${MOZHI_LLAMA_CPP_DIR}/ggml/src/ggml-cpu/CMakeLists.txt")
  if(NOT EXISTS "${_required}")
    message(FATAL_ERROR
      "Missing ${_required}.\n"
      "Run packages/llama_engine/tool/fetch_native_deps.sh first.")
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
# Lets --gc-sections drop what the C API never reaches (quantization,
# training, sessions, LoRA, ...).
add_compile_options(-ffunction-sections -fdata-sections)

# --- Engine options ------------------------------------------------------------
# CACHE ... FORCE so that option() in llama.cpp and ggml sees them.
macro(_mozhi_force name value)
  set(${name} ${value} CACHE BOOL "Set by mozhi_llama" FORCE)
endmacro()
_mozhi_force(BUILD_SHARED_LIBS OFF)       # llama + ggml linked statically
_mozhi_force(LLAMA_BUILD_IS_DEV OFF)      # pinned release tag: "0.6.0"
_mozhi_force(LLAMA_BUILD_COMMON OFF)      # no common/ (HTTP, downloads, jinja)
_mozhi_force(LLAMA_BUILD_TESTS OFF)
_mozhi_force(LLAMA_BUILD_TOOLS OFF)
_mozhi_force(LLAMA_BUILD_EXAMPLES OFF)
_mozhi_force(LLAMA_BUILD_SERVER OFF)
_mozhi_force(LLAMA_BUILD_APP OFF)
_mozhi_force(LLAMA_BUILD_UI OFF)
_mozhi_force(LLAMA_USE_PREBUILT_UI OFF)   # would download the web UI
_mozhi_force(LLAMA_BUILD_MTMD OFF)
_mozhi_force(LLAMA_TOOLS_INSTALL OFF)
_mozhi_force(LLAMA_TESTS_INSTALL OFF)
_mozhi_force(LLAMA_CURL OFF)
_mozhi_force(LLAMA_OPENSSL OFF)
_mozhi_force(LLAMA_SUBPROCESS OFF)
_mozhi_force(LLAMA_LLGUIDANCE OFF)        # would download a Rust library
_mozhi_force(LLAMA_USE_SYSTEM_GGML OFF)
_mozhi_force(LLAMA_ALL_WARNINGS OFF)
_mozhi_force(LLAMA_FATAL_WARNINGS OFF)
_mozhi_force(LLAMA_SANITIZE_THREAD OFF)
_mozhi_force(LLAMA_SANITIZE_ADDRESS OFF)
_mozhi_force(LLAMA_SANITIZE_UNDEFINED OFF)
_mozhi_force(GGML_BUILD_TESTS OFF)
_mozhi_force(GGML_BUILD_EXAMPLES OFF)
_mozhi_force(GGML_BACKEND_DL OFF)         # one library, no dlopen()ed backends
_mozhi_force(GGML_CPU ON)
_mozhi_force(GGML_CPU_ALL_VARIANTS OFF)   # our variants are separate libraries
_mozhi_force(GGML_CPU_KLEIDIAI OFF)       # would download KleidiAI
_mozhi_force(GGML_CPU_REPACK ON)          # faster Q4_0/Q4_K/IQ4_NL weights
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
_mozhi_force(GGML_ZENDNN OFF)
_mozhi_force(GGML_HEXAGON OFF)
_mozhi_force(GGML_OPENVINO OFF)
_mozhi_force(GGML_ET OFF)
_mozhi_force(GGML_VIRTGPU OFF)
_mozhi_force(GGML_VIRTGPU_BACKEND OFF)
_mozhi_force(GGML_CCACHE OFF)             # CMAKE_<LANG>_COMPILER_LAUNCHER instead
_mozhi_force(GGML_LTO OFF)
_mozhi_force(GGML_STATIC OFF)             # not -static: this is a shared library
_mozhi_force(GGML_ALL_WARNINGS OFF)
_mozhi_force(GGML_FATAL_WARNINGS OFF)
_mozhi_force(GGML_SANITIZE_THREAD OFF)
_mozhi_force(GGML_SANITIZE_ADDRESS OFF)
_mozhi_force(GGML_SANITIZE_UNDEFINED OFF)

# --- Target CPU ----------------------------------------------------------------
# A portable baseline per ABI, never the build machine's CPU (GGML_NATIVE):
#  * arm64-v8a: ARMv8.0-A (NEON; Cortex-A53/A57/A72 phones lack dotprod,
#    FP16 arithmetic and i8mm), plus the two faster variants below;
#  * x86_64: SSE4.2, which the Android x86_64 ABI guarantees (emulators,
#    Chromebooks); no AVX, F16C or FMA.
# There is no armeabi-v7a build: a 1-2 GB model cannot be mapped into a
# 32-bit address space reliably.
_mozhi_force(GGML_NATIVE OFF)
foreach(_x86 AVX AVX_VNNI AVX2 BMI2 AVX512 AVX512_VBMI AVX512_VNNI AVX512_BF16
        FMA F16C AMX_TILE AMX_INT8 AMX_BF16)
  _mozhi_force(GGML_${_x86} OFF)
endforeach()
set(GGML_CPU_ARM_ARCH "" CACHE STRING "Set by mozhi_llama" FORCE)
# name=-march value of each extra variant (arm64 only).
set(_variants "")
if(CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|AMD64|amd64)$")
  _mozhi_force(GGML_SSE42 ON)
  set(_cpu "x86-64+sse4.2")
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^(aarch64|arm64)$")
  _mozhi_force(GGML_SSE42 OFF)
  set(GGML_CPU_ARM_ARCH "armv8-a" CACHE STRING "Set by mozhi_llama" FORCE)
  set(_cpu "armv8-a")
  option(MOZHI_LLAMA_CPU_VARIANTS
    "Also build the dotprod and i8mm libraries (arm64)" ON)
  if(MOZHI_LLAMA_CPU_VARIANTS)
    set(_variants
      "dotprod=armv8.2-a+dotprod+fp16"
      "i8mm=armv8.6-a+dotprod+fp16+i8mm")
  endif()
else()
  message(FATAL_ERROR
    "mozhi_llama: unsupported CPU ${CMAKE_SYSTEM_PROCESSOR} "
    "(arm64-v8a and x86_64 only)")
endif()
message(STATUS "mozhi_llama: CPU baseline ${_cpu}")

# --- llama.cpp + ggml ------------------------------------------------------------
file(STRINGS "${MOZHI_LLAMA_CPP_DIR}/CMakeLists.txt" _version_lines
  REGEX "^set\\(LLAMA_VERSION_(MAJOR|MINOR|PATCH) [0-9]+\\)")
string(REGEX REPLACE ".*MAJOR ([0-9]+).*MINOR ([0-9]+).*PATCH ([0-9]+).*"
  "\\1.\\2.\\3" _engine_version "${_version_lines}")

# llama.cpp and ggml embed `git rev-parse --short HEAD` (and a commit count)
# of the checkout in the library. Point git at a repository that does not
# exist while configuring, so they are always "unknown" and the same
# sources give the same library on every machine (a tarball, a dirty
# checkout). git then prints "fatal: not a git repository": expected.
set(_saved_git_dir "$ENV{GIT_DIR}")
set(ENV{GIT_DIR} "${CMAKE_CURRENT_BINARY_DIR}/no-git-during-configure")
add_subdirectory("${MOZHI_LLAMA_CPP_DIR}" llama.cpp EXCLUDE_FROM_ALL)
if(_saved_git_dir)
  set(ENV{GIT_DIR} "${_saved_git_dir}")
else()
  unset(ENV{GIT_DIR})
endif()

# Vendored code: a newer compiler (the NDK's clang) must not fail the build
# or flood it over new warnings.
foreach(_target llama ggml ggml-base ggml-cpu)
  if(TARGET ${_target})
    target_compile_options(${_target} PRIVATE -w)
  endif()
endforeach()

# One more CPU backend, mozhi_ggml_cpu_<name>: the sources, include
# directories, definitions and options of ggml-cpu (whatever this llama.cpp
# release lists), with -march=<march> instead of the baseline's. A static
# library of its own, so no cache option or directory setting of the
# baseline changes.
function(_mozhi_cpu_variant name march)
  set(_target mozhi_ggml_cpu_${name})
  get_target_property(_dir ggml-cpu SOURCE_DIR)
  get_target_property(_sources ggml-cpu SOURCES)
  set(_absolute "")
  foreach(_source IN LISTS _sources)
    if(IS_ABSOLUTE "${_source}")
      list(APPEND _absolute "${_source}")
    else()
      list(APPEND _absolute "${_dir}/${_source}")
    endif()
  endforeach()
  add_library(${_target} STATIC EXCLUDE_FROM_ALL ${_absolute})
  foreach(_property INCLUDE_DIRECTORIES COMPILE_DEFINITIONS COMPILE_FEATURES
          C_STANDARD C_STANDARD_REQUIRED C_EXTENSIONS
          CXX_STANDARD CXX_STANDARD_REQUIRED CXX_EXTENSIONS)
    get_target_property(_value ggml-cpu ${_property})
    if(NOT _value STREQUAL "_value-NOTFOUND")
      set_property(TARGET ${_target} PROPERTY ${_property} "${_value}")
    endif()
  endforeach()
  # Directory-level definitions of ggml/src (_GNU_SOURCE, _XOPEN_SOURCE,
  # GGML_SCHED_MAX_COPIES) apply to targets defined there only.
  get_directory_property(_definitions DIRECTORY "${_dir}" COMPILE_DEFINITIONS)
  target_compile_definitions(${_target} PRIVATE ${_definitions})
  get_target_property(_options ggml-cpu COMPILE_OPTIONS)
  if(_options STREQUAL "_options-NOTFOUND")
    set(_options "")
  endif()
  list(FILTER _options EXCLUDE REGEX "^-march=")
  set_property(TARGET ${_target} PROPERTY COMPILE_OPTIONS
    ${_options} "-march=${march}")
  get_target_property(_libraries ggml-cpu LINK_LIBRARIES)
  if(NOT _libraries STREQUAL "_libraries-NOTFOUND")
    target_link_libraries(${_target} PUBLIC ${_libraries})
  endif()
  message(STATUS "mozhi_llama: CPU variant ${name}: -march=${march}")
endfunction()

# --- The shim ----------------------------------------------------------------------

# kJsonGrammar: llama.cpp's grammars/json.gbnf (any JSON object) as a C++
# string, read from the pinned checkout.
file(READ "${MOZHI_LLAMA_CPP_DIR}/grammars/json.gbnf" MOZHI_LLAMA_JSON_GBNF)
if(MOZHI_LLAMA_JSON_GBNF MATCHES "\\)mozhi_gbnf\"")
  message(FATAL_ERROR "grammars/json.gbnf contains the raw string delimiter")
endif()
configure_file(src/mozhi_llama_json.h.in
  "${CMAKE_CURRENT_BINARY_DIR}/generated/mozhi_llama_json.h" @ONLY)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
  "${MOZHI_LLAMA_CPP_DIR}/grammars/json.gbnf")

set(_map "${CMAKE_CURRENT_SOURCE_DIR}/src/mozhi_llama.map")

# _mozhi_shim(<target> <cpu> [VARIANT <name>]): a C API library. The
# baseline links llama's targets; a variant links the same archives with its
# own CPU backend instead of ggml-cpu.
function(_mozhi_shim target cpu)
  cmake_parse_arguments(_shim "" "VARIANT" "" ${ARGN})
  add_library(${target} SHARED src/mozhi_llama.cc)
  set_target_properties(${target} PROPERTIES
    CXX_STANDARD 17
    CXX_STANDARD_REQUIRED ON
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON)
  target_include_directories(${target} PRIVATE
    "${CMAKE_CURRENT_BINARY_DIR}/generated")
  target_compile_definitions(${target} PRIVATE
    MOZHI_LLAMA_ENGINE_VERSION="${_engine_version}"
    MOZHI_LLAMA_CPU="${cpu}")
  if(_shim_VARIANT)
    # The archives by file: linking the llama target would also pull in the
    # baseline ggml-cpu (llama -> ggml -> ggml-cpu).
    target_include_directories(${target} PRIVATE
      "$<TARGET_PROPERTY:llama,INTERFACE_INCLUDE_DIRECTORIES>"
      "$<TARGET_PROPERTY:ggml-base,INTERFACE_INCLUDE_DIRECTORIES>")
    target_link_libraries(${target} PRIVATE
      "$<TARGET_FILE:llama>" "$<TARGET_FILE:ggml>"
      mozhi_ggml_cpu_${_shim_VARIANT})
    if(CMAKE_DL_LIBS)
      target_link_libraries(${target} PRIVATE ${CMAKE_DL_LIBS})
    endif()
    add_dependencies(${target} llama ggml ggml-base)
  else()
    target_link_libraries(${target} PRIVATE llama)
  endif()
  if(NOT APPLE AND NOT WIN32)
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

  # Smoke-test / benchmark CLI (not part of the app; for adb shell):
  # `--target <target>_cli`.
  add_executable(${target}_cli EXCLUDE_FROM_ALL tool/mozhi_llama_cli.c)
  target_link_libraries(${target}_cli PRIVATE ${target})
  if(NOT ANDROID AND NOT APPLE AND NOT WIN32)
    set_target_properties(${target}_cli PROPERTIES BUILD_RPATH "$ORIGIN")
  endif()
endfunction()

_mozhi_shim(mozhi_llama "${_cpu}")
foreach(_variant IN LISTS _variants)
  string(REPLACE "=" ";" _parts "${_variant}")
  list(GET _parts 0 _name)
  list(GET _parts 1 _march)
  _mozhi_cpu_variant(${_name} ${_march})
  _mozhi_shim(mozhi_llama_${_name} "${_march}" VARIANT ${_name})
endforeach()

# android/build.gradle lists the arm64-v8a variants as targets for every ABI
# (the Android Gradle plugin may check each ABI's targets). On x86_64 an
# empty static library of the same name stands in: only shared libraries
# are packaged into the APK, so nothing of it ships.
if(ANDROID)
  foreach(_name dotprod i8mm)
    if(NOT TARGET mozhi_llama_${_name})
      set(_stub "${CMAKE_CURRENT_BINARY_DIR}/mozhi_llama_${_name}_absent.c")
      file(CONFIGURE OUTPUT "${_stub}" CONTENT
        "/* No mozhi_llama_${_name} for this ABI (CMakeLists.txt). */\ntypedef int mozhi_llama_${_name}_absent;\n")
      add_library(mozhi_llama_${_name} STATIC EXCLUDE_FROM_ALL "${_stub}")
    endif()
  endforeach()
endif()
