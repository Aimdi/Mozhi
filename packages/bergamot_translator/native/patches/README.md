# Patches to the vendored engine

Applied by `../../tool/fetch_native_deps.sh` to the pinned
`third_party/translations` checkout (idempotent; `native/CMakeLists.txt`
refuses to configure without them). Keep them few and small, and send them
upstream to <https://github.com/mozilla/translations>.

| Patch | Why |
| --- | --- |
| `0001-marian-unaligned-quant-mult.patch` | Marian reads and writes the float quantisation multiplier that follows an int8 matrix through a cast `float*`. For the 1x1 item `Wemb_QuantMultA` of `*.alphas.bin` models it is not 4-byte aligned, which is harmless on x86 and AArch64 but a SIGBUS on 32-bit ARM (VFP loads must be aligned). Uses `std::memcpy` instead (same code on the other targets). |
| `0002-marian-unaligned-binary-header.patch` | The model header's 64-bit fields after the item names and shapes (e.g. the data offset) are read through `uint64_t*` casts at unaligned addresses. Clang emits `ldrd` for them on 32-bit ARM, which faults without a kernel fix-up (GCC splits the load and got away with it). Reads them with `std::memcpy`. |

The vendored sources are MPL-2.0 (bergamot) and MIT (Marian); these patches
are under the same licenses as the files they modify.
