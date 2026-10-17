/*
 * 32-bit ARM (armeabi-v7a) replacements for NEON intrinsics that only exist
 * on AArch64, used by Marian's SSE-on-NEON layer (simd_utils) and its ruy
 * glue. Force-included into every translation unit of 32-bit ARM builds by
 * ../CMakeLists.txt, so the vendored sources stay unmodified.
 *
 * Copyright (c) 2026 Mozhi contributors. MIT License.
 */
#ifndef MOZHI_ARMV7_NEON_COMPAT_H_
#define MOZHI_ARMV7_NEON_COMPAT_H_

#if defined(__arm__) && !defined(__aarch64__) && defined(__ARM_NEON)

#include <arm_neon.h>

/* a + b * n (fused multiply-add needs VFPv4, i.e. -mfpu=neon-vfpv4). */
static inline float32x4_t mozhi_vfmaq_n_f32(float32x4_t a, float32x4_t b,
                                            float32_t n) {
#if defined(__ARM_FEATURE_FMA)
  return vfmaq_f32(a, b, vdupq_n_f32(n));
#else
  return vmlaq_n_f32(a, b, n);
#endif
}
#define vfmaq_n_f32 mozhi_vfmaq_n_f32

#if !defined(__ARM_FEATURE_DIRECTED_ROUNDING)
/* Float -> int32 rounding to nearest. ARMv7 has no VCVTN; this rounds
 * halfway cases away from zero instead of to even, which only differs on
 * exact .5 values (irrelevant for quantised activations). */
static inline int32x4_t mozhi_vcvtnq_s32_f32(float32x4_t a) {
  const float32x4_t half = vdupq_n_f32(0.5f);
  const uint32x4_t negative = vcltq_f32(a, vdupq_n_f32(0.0f));
  const float32x4_t bias = vbslq_f32(negative, vnegq_f32(half), half);
  return vcvtq_s32_f32(vaddq_f32(a, bias));
}
#define vcvtnq_s32_f32 mozhi_vcvtnq_s32_f32
#endif

#if defined(__clang__)
/* sse2neon's _mm_stream_pd casts to float64x2_t (an AArch64-only type) when
 * the compiler has __builtin_nontemporal_store, as clang does. On 32-bit
 * ARM sse2neon's __m128d is a float32x4_t, so name that. */
typedef float32x4_t float64x2_t;

#if defined(__cplusplus)
/* simd_utils' 32-bit _mm_cvtpd_epi64 calls _mm_set_epi64(int64_t, int64_t);
 * GCC converts the scalars to __m64, clang does not. This overload (C++
 * linkage, next to sse2neon's C one) takes them as they are. */
static inline int64x2_t _mm_set_epi64(int64_t i1, int64_t i2) {
  return vcombine_s64(vcreate_s64((uint64_t)i2), vcreate_s64((uint64_t)i1));
}
#endif
#endif

#if defined(__GNUC__) && !defined(__clang__)
/* GCC's 32-bit arm_neon.h lacks the x4 loads (clang has them). */
static inline uint8x16x4_t mozhi_vld1q_u8_x4(const uint8_t* p) {
  uint8x16x4_t r;
  r.val[0] = vld1q_u8(p);
  r.val[1] = vld1q_u8(p + 16);
  r.val[2] = vld1q_u8(p + 32);
  r.val[3] = vld1q_u8(p + 48);
  return r;
}
#define vld1q_u8_x4 mozhi_vld1q_u8_x4
#endif

#endif /* 32-bit ARM with NEON */

#endif /* MOZHI_ARMV7_NEON_COMPAT_H_ */
