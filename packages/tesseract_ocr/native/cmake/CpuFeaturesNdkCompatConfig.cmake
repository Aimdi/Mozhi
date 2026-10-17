# Stands in for Google's cpu_features (ndk_compat), which Tesseract's
# CMakeLists requires on Android (find_package(CpuFeaturesNdkCompat
# REQUIRED)) only to detect NEON on 32-bit ARM. libmozhi_tesseract detects
# it with getauxval(AT_HWCAP) instead (HAVE_GETAUXVAL, see ../CMakeLists.txt,
# which also defines the empty CpuFeatures::ndk_compat target and points
# CpuFeaturesNdkCompat_DIR here). Not a copy of cpu_features: nothing of it
# is built or linked.
if(NOT TARGET CpuFeatures::ndk_compat)
  message(FATAL_ERROR "CpuFeatures::ndk_compat must be defined by "
    "packages/tesseract_ocr/native/CMakeLists.txt before Tesseract is added.")
endif()
set(CpuFeaturesNdkCompat_FOUND TRUE)
