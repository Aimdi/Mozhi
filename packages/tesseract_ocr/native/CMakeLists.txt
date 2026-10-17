# libmozhi_tesseract: the C API in src/mozhi_tesseract.h over the Tesseract
# OCR engine (Apache-2.0; LSTM recognizer only) and the parts of Leptonica
# (BSD-2-Clause) it needs. Images come in as raw pixels, so no image codec
# library (libpng, libjpeg, libtiff, giflib, libwebp, OpenJPEG, zlib) is
# built or linked.
#
# Both are pinned git submodules under third_party/ (see
# ../tool/fetch_native_deps.sh). Nothing is downloaded at configure or build
# time.
#
# Used by the Android Gradle build (../android/build.gradle, one configure per
# ABI with the NDK toolchain) and by ../tool/build_native_linux.sh (the
# library the Dart tests load).
cmake_minimum_required(VERSION 3.22)

project(mozhi_tesseract C CXX)

set(MOZHI_TESSERACT_TESSERACT_DIR
    "${CMAKE_CURRENT_SOURCE_DIR}/third_party/tesseract"
    CACHE PATH "Checkout of github.com/tesseract-ocr/tesseract")
set(MOZHI_TESSERACT_LEPTONICA_DIR
    "${CMAKE_CURRENT_SOURCE_DIR}/third_party/leptonica"
    CACHE PATH "Checkout of github.com/DanBloomberg/leptonica")

foreach(_required
    "${MOZHI_TESSERACT_TESSERACT_DIR}/CMakeLists.txt"
    "${MOZHI_TESSERACT_TESSERACT_DIR}/src/api/baseapi.cpp"
    "${MOZHI_TESSERACT_LEPTONICA_DIR}/CMakeLists.txt"
    "${MOZHI_TESSERACT_LEPTONICA_DIR}/src/allheaders.h")
  if(NOT EXISTS "${_required}")
    message(FATAL_ERROR
      "Missing ${_required}.\n"
      "Run packages/tesseract_ocr/tool/fetch_native_deps.sh first.")
  endif()
endforeach()

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# --- Reproducible builds -------------------------------------------------------
# __FILE__ (Tesseract's ASSERT_HOST, Leptonica's error macros) would embed
# absolute source paths, which differ between machines (CI, F-Droid, a
# developer's checkout). Map the repository root (three levels up) to "."
# and the build directory to "build" for every target below, vendored ones
# included. The last matching map wins, so the more specific ones come
# last. -ffile-prefix-map also covers debug info.
get_filename_component(_mozhi_repo_root "${CMAKE_CURRENT_SOURCE_DIR}/../../.."
  ABSOLUTE)
add_compile_options(
  "-ffile-prefix-map=${_mozhi_repo_root}=."
  "-ffile-prefix-map=${CMAKE_BINARY_DIR}=build")
if(ANDROID AND ANDROID_NDK)
  add_compile_options("-ffile-prefix-map=${ANDROID_NDK}=ndk")
endif()
# Lets --gc-sections drop the many Leptonica and Tesseract functions the C
# API never reaches.
add_compile_options(-ffunction-sections -fdata-sections)

# --- Options of the vendored builds ----------------------------------------------
# CACHE ... FORCE so that option() in every subproject sees them.
macro(_mozhi_force name value)
  set(${name} ${value} CACHE BOOL "Set by mozhi_tesseract" FORCE)
endmacro()
_mozhi_force(BUILD_SHARED_LIBS OFF)

# No image codecs or other optional libraries, even when the system has
# them: a host build must not link a different set than the APK.
foreach(_package ZLIB PNG JPEG TIFF GIF WebP OpenJPEG LibArchive CURL ICU
    OpenMP PkgConfig)
  set(CMAKE_DISABLE_FIND_PACKAGE_${_package} TRUE)
endforeach()

# Leptonica: image processing only (thresholding, scaling, connected
# components). Its readers and writers for files are compiled as stubs.
_mozhi_force(BUILD_PROG OFF)
_mozhi_force(SW_BUILD OFF)
_mozhi_force(SYM_LINK OFF)
_mozhi_force(STRICT_CONF OFF)
_mozhi_force(ENABLE_ZLIB OFF)
_mozhi_force(ENABLE_PNG OFF)
_mozhi_force(ENABLE_GIF OFF)
_mozhi_force(ENABLE_JPEG OFF)
_mozhi_force(ENABLE_TIFF OFF)
_mozhi_force(ENABLE_WEBP OFF)
_mozhi_force(ENABLE_OPENJPEG OFF)

# Tesseract: the LSTM recognizer of tessdata_fast. The legacy engine (and
# with it orientation detection, osd.traineddata) is left out, as are the
# training tools, ScrollView (a debugging GUI over a socket), OpenMP,
# libarchive, libcurl (Tesseract can fetch images by URL) and libtiff.
_mozhi_force(BUILD_TRAINING_TOOLS OFF)
_mozhi_force(BUILD_TESTS OFF)
_mozhi_force(GRAPHICS_DISABLED ON)
_mozhi_force(DISABLED_LEGACY_ENGINE ON)
_mozhi_force(OPENMP_BUILD OFF)
_mozhi_force(DISABLE_ARCHIVE ON)
_mozhi_force(DISABLE_CURL ON)
_mozhi_force(DISABLE_TIFF ON)
_mozhi_force(ENABLE_LTO OFF)
_mozhi_force(FAST_FLOAT ON)
_mozhi_force(ENABLE_NATIVE OFF)
_mozhi_force(USE_SYSTEM_ICU OFF)
_mozhi_force(INSTALL_CONFIGS OFF)
_mozhi_force(ENABLE_UNITY_BUILD OFF)
_mozhi_force(ENABLE_PRECOMPILED_HEADERS OFF)
_mozhi_force(ENABLE_CCACHE OFF)
_mozhi_force(ENABLE_NINJA_POOL OFF)

# --- Target CPU ------------------------------------------------------------------
# Tesseract compiles its SIMD kernels (src/arch) with their own flags and
# picks one at run time:
#  * arm64-v8a: NEON (always present).
#  * armeabi-v7a: NEON kernels (-mfpu=neon), detected at run time with
#    getauxval(AT_HWCAP). Tesseract's CMake build never defines
#    HAVE_GETAUXVAL (only its autotools build does), which would leave NEON
#    unused; it is defined for libtesseract below. The NDK builds
#    armeabi-v7a with NEON anyway (the default since r21), so the library
#    needs a NEON CPU, like libmozhi_bergamot; Dart checks before loading.
#  * x86_64: SSE4.1 (part of the Android x86_64 ABI). The AVX, AVX2,
#    AVX-512 and FMA kernels are left out on Android, where x86_64 means
#    emulators (whose CPU features vary with the host) and a few
#    Chromebooks; desktop builds keep them (MOZHI_TESSERACT_X86_AVX).
if(ANDROID)
  set(_avx_default OFF)
else()
  set(_avx_default ON)
endif()
option(MOZHI_TESSERACT_X86_AVX
  "Compile Tesseract's AVX/AVX2/AVX-512/FMA kernels (x86_64)" ${_avx_default})
if(CMAKE_SYSTEM_PROCESSOR MATCHES "x86|AMD64|amd64|i.86"
   AND NOT MOZHI_TESSERACT_X86_AVX)
  # check_cxx_compiler_flag() keeps a cached result, so Tesseract's checks
  # for these flags find them "unsupported".
  foreach(_flag HAVE_AVX HAVE_AVX2 HAVE_AVX512F HAVE_FMA)
    set(${_flag} FALSE CACHE INTERNAL "Set by mozhi_tesseract")
  endforeach()
endif()

# --- Leptonica ----------------------------------------------------------------------
add_subdirectory("${MOZHI_TESSERACT_LEPTONICA_DIR}" leptonica EXCLUDE_FROM_ALL)
get_directory_property(_leptonica_version
  DIRECTORY "${MOZHI_TESSERACT_LEPTONICA_DIR}" DEFINITION leptonica_VERSION)
get_directory_property(_leptonica_binary_dir
  DIRECTORY "${MOZHI_TESSERACT_LEPTONICA_DIR}" BINARY_DIR)
target_compile_options(leptonica PRIVATE -w)
# Its public headers for Tesseract and the shim: allheaders.h & co. and the
# generated endianness.h, copied on its own. (Leptonica's build directory
# also holds its config_auto.h, which would shadow Tesseract's: Tesseract
# would then compile its legacy engine calls although the legacy sources
# are left out.) BUILD_INTERFACE: its install rules, never used here,
# refuse source paths.
set(_leptonica_include "${CMAKE_CURRENT_BINARY_DIR}/leptonica-include")
configure_file("${_leptonica_binary_dir}/src/endianness.h"
  "${_leptonica_include}/endianness.h" COPYONLY)
target_include_directories(leptonica INTERFACE
  "$<BUILD_INTERFACE:${MOZHI_TESSERACT_LEPTONICA_DIR}/src>"
  "$<BUILD_INTERFACE:${_leptonica_include}>")

# Tesseract looks for Leptonica with find_package(Leptonica CONFIG) (an
# installed copy). Point it at the target built above instead, through a
# small config file. (With CMake >= 3.25 Tesseract also try-runs a TIFF
# test against it, which cannot link a target that is not built yet: it
# prints "Failed to compile test" and the build continues without TIFF,
# which is disabled anyway.)
set(_leptonica_config "${CMAKE_CURRENT_BINARY_DIR}/leptonica-config")
file(WRITE "${_leptonica_config}/LeptonicaConfig.cmake" "\
# Written by packages/tesseract_ocr/native/CMakeLists.txt: the leptonica
# target of this build, for Tesseract's find_package(Leptonica CONFIG).
set(Leptonica_FOUND TRUE)
set(Leptonica_VERSION ${_leptonica_version})
set(Leptonica_LIBRARIES leptonica)
set(Leptonica_INCLUDE_DIRS
  \"${MOZHI_TESSERACT_LEPTONICA_DIR}/src\"
  \"${_leptonica_include}\")
")
include(CMakePackageConfigHelpers)
write_basic_package_version_file(
  "${_leptonica_config}/LeptonicaConfigVersion.cmake"
  VERSION "${_leptonica_version}"
  COMPATIBILITY AnyNewerVersion)
set(Leptonica_DIR "${_leptonica_config}" CACHE PATH "Set by mozhi_tesseract"
  FORCE)

# --- Tesseract ------------------------------------------------------------------------
if(ANDROID)
  # Tesseract's Android build links Google's cpu_features (ndk_compat) for
  # one thing: NEON detection on 32-bit ARM, where getauxval() does the
  # same (see HAVE_GETAUXVAL below). An empty target satisfies its
  # find_package(CpuFeaturesNdkCompat REQUIRED).
  add_library(CpuFeatures::ndk_compat INTERFACE IMPORTED)
  set(CpuFeaturesNdkCompat_DIR "${CMAKE_CURRENT_SOURCE_DIR}/cmake"
    CACHE PATH "Set by mozhi_tesseract" FORCE)
endif()

# Tesseract's CMakeLists asks git for its version (`git describe` in the
# submodule): "5.5.3" at the pinned tag, and when the tag was not fetched
# (shallow checkouts) it falls back to its VERSION file, "5.5.3" too, so
# the version compiled in does not depend on the checkout.
add_subdirectory("${MOZHI_TESSERACT_TESSERACT_DIR}" tesseract EXCLUDE_FROM_ALL)
file(STRINGS "${MOZHI_TESSERACT_TESSERACT_DIR}/VERSION" _tesseract_version
  LIMIT_COUNT 1)
message(STATUS "mozhi_tesseract: Tesseract ${_tesseract_version}, "
  "Leptonica ${_leptonica_version}, ${CMAKE_SYSTEM_PROCESSOR}")

# The generated tesseract/version.h (baseapi.h includes it), for the shim.
get_directory_property(_tesseract_binary_dir
  DIRECTORY "${MOZHI_TESSERACT_TESSERACT_DIR}" BINARY_DIR)
target_include_directories(libtesseract INTERFACE
  "$<BUILD_INTERFACE:${_tesseract_binary_dir}/include>")

if(CMAKE_SYSTEM_PROCESSOR MATCHES "^arm" AND NOT CMAKE_SYSTEM_PROCESSOR
   MATCHES "^arm64")
  target_compile_definitions(libtesseract PRIVATE HAVE_GETAUXVAL)
endif()
# Vendored code: its warnings are noise here (it never builds with -Werror).
target_compile_options(libtesseract PRIVATE -w)

# --- The shim ----------------------------------------------------------------------------

add_library(mozhi_tesseract SHARED src/mozhi_tesseract.cc)
set_target_properties(mozhi_tesseract PROPERTIES
  CXX_STANDARD 17
  CXX_STANDARD_REQUIRED ON
  CXX_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN ON)
target_link_libraries(mozhi_tesseract PRIVATE libtesseract leptonica)

if(NOT APPLE AND NOT WIN32)
  set(_map "${CMAKE_CURRENT_SOURCE_DIR}/src/mozhi_tesseract.map")
  target_link_options(mozhi_tesseract PRIVATE
    "-Wl,--version-script=${_map}" "-Wl,--gc-sections" "-Wl,--no-undefined")
  set_property(TARGET mozhi_tesseract APPEND PROPERTY LINK_DEPENDS "${_map}")
endif()
if(ANDROID)
  # 16 KB page sizes (Android 15+); NDK r28 already defaults to this.
  target_link_options(mozhi_tesseract PRIVATE "-Wl,-z,max-page-size=16384")
endif()

install(TARGETS mozhi_tesseract LIBRARY DESTINATION lib)

# Smoke-test / benchmark CLI (not part of the app): `--target mozhi_tesseract_cli`.
add_executable(mozhi_tesseract_cli EXCLUDE_FROM_ALL tool/mozhi_tesseract_cli.c)
target_link_libraries(mozhi_tesseract_cli PRIVATE mozhi_tesseract)
if(NOT ANDROID AND NOT APPLE AND NOT WIN32)
  set_target_properties(mozhi_tesseract_cli PROPERTIES BUILD_RPATH "$ORIGIN")
endif()
