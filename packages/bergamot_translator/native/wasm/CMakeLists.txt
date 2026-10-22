# bergamot-translator.{js,wasm}: the web build of the Bergamot engine and
# CLD2, for the web app's worker (web/bergamot/worker.js). The C API is the
# native library's (../src/mozhi_bergamot.h, ABI 2) plus loading models from
# memory (src/mozhi_bergamot_wasm.cc); the JavaScript glue is Emscripten's,
# with Mozilla's import-gemm patch so Firefox's privileged `mozIntGemm` is
# used when the page has it and the int8 GEMM compiled into the WASM module
# otherwise.
#
# Configure with Emscripten 3.1.8 (the version mozilla/translations pins:
# newer releases fail to build SentencePiece) through
# ../../tool/build_wasm.sh, which also fetches the sources and applies the
# patches. Single-threaded (no SharedArrayBuffer, so no COOP/COEP headers),
# WASM SIMD (-msimd128), no file system in the glue.
cmake_minimum_required(VERSION 3.22)

project(mozhi_bergamot_wasm C CXX)

if(NOT EMSCRIPTEN)
  message(FATAL_ERROR
    "Configure with emcmake: packages/bergamot_translator/tool/build_wasm.sh")
endif()

get_filename_component(_native "${CMAKE_CURRENT_SOURCE_DIR}/.." ABSOLUTE)
set(MOZHI_BERGAMOT_TRANSLATIONS_DIR "${_native}/third_party/translations"
    CACHE PATH "Checkout of github.com/mozilla/translations")
set(MOZHI_BERGAMOT_CLD2_DIR "${_native}/third_party/cld2"
    CACHE PATH "Checkout of github.com/CLD2Owners/cld2")

set(_inference "${MOZHI_BERGAMOT_TRANSLATIONS_DIR}/inference")
set(_marian_3rd "${_inference}/marian-fork/src/3rd_party")
foreach(_required
    "${_inference}/CMakeLists.txt"
    "${_inference}/wasm/import-gemm-module.js"
    "${_marian_3rd}/sentencepiece/CMakeLists.txt"
    "${_marian_3rd}/intgemm/CMakeLists.txt"
    "${_marian_3rd}/onnxjs/CMakeLists.txt"
    "${_marian_3rd}/onnxjs/deps/eigen/CMakeLists.txt"
    "${MOZHI_BERGAMOT_CLD2_DIR}/internal/compact_lang_det_impl.cc")
  if(NOT EXISTS "${_required}")
    message(FATAL_ERROR
      "Missing ${_required}.\n"
      "Run packages/bergamot_translator/tool/build_wasm.sh (it fetches the "
      "sources the web build needs).")
  endif()
endforeach()

# patches/ must be applied (build_wasm.sh does it).
file(STRINGS "${_inference}/src/translator/text_processor.h" _patched
  REGEX "maxLengthBreak_\\(options->get")
if(NOT _patched)
  message(FATAL_ERROR
    "native/wasm/patches/ are not applied to ${MOZHI_BERGAMOT_TRANSLATIONS_DIR}.\n"
    "Run packages/bergamot_translator/tool/build_wasm.sh.")
endif()

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

# Reproducible builds: no checkout or build paths in the output (Marian's
# __FILE__ messages end up in the WASM data section).
get_filename_component(_mozhi_repo_root "${_native}/../../.." ABSOLUTE)
add_compile_options(
  "-ffile-prefix-map=${_mozhi_repo_root}=."
  "-ffile-prefix-map=${CMAKE_BINARY_DIR}=build")

# --- Engine options ------------------------------------------------------------
macro(_mozhi_force name value)
  set(${name} ${value} CACHE BOOL "Set by mozhi_bergamot_wasm" FORCE)
endmacro()
_mozhi_force(GIT_SUBMODULE OFF)          # bergamot: no submodule updates
_mozhi_force(COMPILE_WASM ON)
_mozhi_force(WORMHOLE OFF)
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
_mozhi_force(USE_SENTENCEPIECE ON)
_mozhi_force(USE_STATIC_LIBS ON)
_mozhi_force(GENERATE_MARIAN_INSTALL_TARGETS OFF)
_mozhi_force(SPM_ENABLE_SHARED OFF)
_mozhi_force(SPM_ENABLE_TCMALLOC OFF)
_mozhi_force(SPM_USE_BUILTIN_PROTOBUF ON)

# --- Bergamot + Marian -----------------------------------------------------------
file(STRINGS "${_inference}/BERGAMOT_VERSION" _engine_version LIMIT_COUNT 1)

# Marian's git_revision.h rule needs git (see ../CMakeLists.txt): replaced by
# the same git-free, deterministic header as the native build.
function(add_custom_command)
  if(ARGC GREATER 1 AND ARGV0 STREQUAL "OUTPUT"
     AND ARGV1 MATCHES "/marian-fork/src/common/git_revision\\.h$")
    _add_custom_command(OUTPUT "${ARGV1}"
      COMMAND "${CMAKE_COMMAND}" "-DOUTPUT=${ARGV1}"
              "-DREVISION=${_engine_version} (mozilla/translations)"
              -P "${_native}/cmake/write_git_revision.cmake"
      VERBATIM)
  else()
    _add_custom_command(${ARGV})
  endif()
endfunction()

# Eigen (onnxjs' float GEMM, the WebAssembly build's sgemm): only its
# MPL-2.0 code, never its LGPL parts (a compile error if one is included).
add_compile_definitions(EIGEN_MPL2_ONLY)

# Marian's CMakeLists runs `git submodule update --init --recursive` while
# configuring (it would clone mozilla/translations' training tools): point
# git at nothing during the configure step, as ../CMakeLists.txt does.
set(_saved_git_dir "$ENV{GIT_DIR}")
set(ENV{GIT_DIR} "${CMAKE_CURRENT_BINARY_DIR}/no-git-during-configure")
# EXCLUDE_FROM_ALL: only what bergamot-translator links is built (not
# upstream's embind module, which is replaced by the C API below).
add_subdirectory("${_inference}" bergamot EXCLUDE_FROM_ALL)
if(_saved_git_dir)
  set(ENV{GIT_DIR} "${_saved_git_dir}")
else()
  unset(ENV{GIT_DIR})
endif()

# Marian's build_info.cpp lists every CMake cache variable (machine paths):
# replaced by a fixed one, as in ../CMakeLists.txt.
get_directory_property(_marian_binary_dir
  DIRECTORY "${_inference}/marian-fork" BINARY_DIR)
set(_build_info "${_marian_binary_dir}/src/common/build_info.cpp")
if(EXISTS "${_build_info}")
  file(WRITE "${_build_info}" "\
// Written by packages/bergamot_translator/native/wasm/CMakeLists.txt instead
// of Marian's list of CMake cache variables (machine-specific paths).
#include \"common/build_info.h\"

std::string marian::cmakeBuildOptions() {
  return \"mozhi_bergamot: wasm32 simd128\\n\";
}

std::string marian::cmakeBuildOptionsAdvanced() {
  return marian::cmakeBuildOptions();
}
")
endif()

foreach(_target marian intgemm)
  if(TARGET ${_target})
    target_compile_options(${_target} PRIVATE -Wno-error)
  endif()
endforeach()

# Upstream's flags for every WebAssembly target (inference/CMakeLists.txt).
set(_wasm_compile_flags
  -O3 -fPIC -mssse3 -msimd128
  -sDISABLE_EXCEPTION_CATCHING=1 -sSTRICT=1)

# --- CLD2 (language identification) -------------------------------------------------
# As in ../CMakeLists.txt: the 24 files of internal/compile_libs.sh's
# "libcld2" with the "chrome" tables (83 languages).
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
set_target_properties(mozhi_cld2 PROPERTIES CXX_STANDARD 17
  CXX_STANDARD_REQUIRED ON)
target_include_directories(mozhi_cld2 PUBLIC "${MOZHI_BERGAMOT_CLD2_DIR}/public")
target_compile_options(mozhi_cld2 PRIVATE ${_wasm_compile_flags} -w
  -Wno-narrowing)

# --- bergamot-translator.js / .wasm ---------------------------------------------------
set(_exports
  _malloc _free
  _mozhi_bergamot_abi_version _mozhi_bergamot_version
  _mozhi_bergamot_buffer_create _mozhi_bergamot_buffer_data
  _mozhi_bergamot_buffer_destroy _mozhi_bergamot_model_create_from_buffers
  _mozhi_bergamot_model_destroy _mozhi_bergamot_translate_ex
  _mozhi_bergamot_free_string _mozhi_bergamot_last_error
  _mozhi_bergamot_detect
  # The int8 GEMM compiled into the module, for import-gemm-module.js when
  # the browser has no mozIntGemm (every browser but Firefox's privileged
  # pages).
  _int8PrepareAFallback _int8PrepareBFallback
  _int8PrepareBFromTransposedFallback
  _int8PrepareBFromQuantizedTransposedFallback _int8PrepareBiasFallback
  _int8MultiplyAndAddBiasFallback _int8SelectColumnsOfBFallback)
list(JOIN _exports "," _exports_list)

add_executable(mozhi_bergamot_wasm src/mozhi_bergamot_wasm.cc)
set_target_properties(mozhi_bergamot_wasm PROPERTIES
  OUTPUT_NAME bergamot-translator
  SUFFIX ".js"
  CXX_STANDARD 17
  CXX_STANDARD_REQUIRED ON
  # Not next to upstream's (unbuilt) target of the same file name.
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/out")
target_compile_definitions(mozhi_bergamot_wasm PRIVATE
  MOZHI_BERGAMOT_ENGINE_VERSION="${_engine_version}")
target_compile_options(mozhi_bergamot_wasm PRIVATE ${_wasm_compile_flags})
target_link_libraries(mozhi_bergamot_wasm PRIVATE bergamot-translator-source
  mozhi_cld2)
target_link_options(mozhi_bergamot_wasm PRIVATE
  -O3
  # Keeps the JS readable (and the import-gemm patch's pattern intact); the
  # WASM binary is not affected.
  -g1
  -sASSERTIONS=0
  -sDISABLE_EXCEPTION_CATCHING=1
  # The int8 GEMM functions come from the "wasm_gemm" import at run time.
  -sLLD_REPORT_UNDEFINED
  -sERROR_ON_UNDEFINED_SYMBOLS=0
  -sSTRICT=1
  -sALLOW_MEMORY_GROWTH=1
  -sENVIRONMENT=worker
  -sINVOKE_RUN=0
  -sFILESYSTEM=0
  -sDECLARE_ASM_MODULE_EXPORTS=0
  "-sEXPORTED_FUNCTIONS=[${_exports_list}]"
  # The memory is created in JS so mozIntGemm can share it.
  -sIMPORTED_MEMORY=1
  # No eval/new Function: the page's CSP has no 'unsafe-eval'.
  -sDYNAMIC_EXECUTION=0
  "--post-js=${CMAKE_CURRENT_SOURCE_DIR}/src/post.js")
set_property(TARGET mozhi_bergamot_wasm APPEND PROPERTY LINK_DEPENDS
  "${CMAKE_CURRENT_SOURCE_DIR}/src/post.js")
