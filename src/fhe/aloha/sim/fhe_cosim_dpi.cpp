// Rung 7c — Verilator DPI-C shim bridging the SV testbench to the in-process
// Lattigo "server" (libfhecosim.so, built from tvgen/ with `-tags dpi
// -buildmode=c-shared`). The TB calls fhe_dpi_{add,mul,mul_rescale} mid-sim with
// the PUBLIC ciphertext polys as open arrays; this shim marshals them to the
// cgo-exported AlohaServer* cores and writes the result back. One RTL process,
// secret key never leaves it (no re-keygen, no file handoff).
//
// Built + linked only when the DPI driver passes this file + -LDFLAGS
// "-lfhecosim"; the default file-based cosim never references these symbols
// (the SV side is guarded by `ifdef FHE_DPI_COSIM).

#include "svdpi.h"
#include <vector>
#include <cstdint>

// cgo-exported cores (signatures from libfhecosim.h). uint64* <-> longint*.
extern "C" {
void AlohaServerAdd(int n, uint64_t q,
                    uint64_t *c0a, uint64_t *c1a, uint64_t *c0b, uint64_t *c1b,
                    uint64_t *outc0, uint64_t *outc1);
void AlohaServerMul(int n, uint64_t q,
                    uint64_t *c0, uint64_t *c1, uint64_t *pt,
                    uint64_t *outc0, uint64_t *outc1);
void AlohaServerMulRescale(int n, uint64_t q0, uint64_t q1,
                           uint64_t *c0q0, uint64_t *c0q1, uint64_t *c1q0,
                           uint64_t *c1q1, uint64_t *ptq0, uint64_t *ptq1,
                           uint64_t *outc0, uint64_t *outc1);
}

// Copy an SV open array of `longint` into a flat uint64 buffer.
static void gather(const svOpenArrayHandle h, std::vector<uint64_t> &v, int n) {
  v.resize(n);
  for (int i = 0; i < n; i++)
    v[i] = *reinterpret_cast<const uint64_t *>(svGetArrElemPtr1(h, i));
}

// Write a flat uint64 buffer back into an SV open array of `longint`.
static void scatter(const svOpenArrayHandle h, const uint64_t *p, int n) {
  for (int i = 0; i < n; i++)
    *reinterpret_cast<uint64_t *>(svGetArrElemPtr1(h, i)) = p[i];
}

extern "C" void fhe_dpi_add(int n, long long q,
                            const svOpenArrayHandle c0a, const svOpenArrayHandle c1a,
                            const svOpenArrayHandle c0b, const svOpenArrayHandle c1b,
                            const svOpenArrayHandle outc0, const svOpenArrayHandle outc1) {
  std::vector<uint64_t> a0, a1, b0, b1, o0(n), o1(n);
  gather(c0a, a0, n); gather(c1a, a1, n); gather(c0b, b0, n); gather(c1b, b1, n);
  AlohaServerAdd(n, (uint64_t)q, a0.data(), a1.data(), b0.data(), b1.data(),
                 o0.data(), o1.data());
  scatter(outc0, o0.data(), n); scatter(outc1, o1.data(), n);
}

extern "C" void fhe_dpi_mul(int n, long long q,
                            const svOpenArrayHandle c0, const svOpenArrayHandle c1,
                            const svOpenArrayHandle pt,
                            const svOpenArrayHandle outc0, const svOpenArrayHandle outc1) {
  std::vector<uint64_t> v0, v1, vp, o0(n), o1(n);
  gather(c0, v0, n); gather(c1, v1, n); gather(pt, vp, n);
  AlohaServerMul(n, (uint64_t)q, v0.data(), v1.data(), vp.data(),
                 o0.data(), o1.data());
  scatter(outc0, o0.data(), n); scatter(outc1, o1.data(), n);
}

extern "C" void fhe_dpi_mul_rescale(int n, long long q0, long long q1,
                                    const svOpenArrayHandle c0q0, const svOpenArrayHandle c0q1,
                                    const svOpenArrayHandle c1q0, const svOpenArrayHandle c1q1,
                                    const svOpenArrayHandle ptq0, const svOpenArrayHandle ptq1,
                                    const svOpenArrayHandle outc0, const svOpenArrayHandle outc1) {
  std::vector<uint64_t> a0, a1, b0, b1, p0, p1, o0(n), o1(n);
  gather(c0q0, a0, n); gather(c0q1, a1, n);
  gather(c1q0, b0, n); gather(c1q1, b1, n);
  gather(ptq0, p0, n); gather(ptq1, p1, n);
  AlohaServerMulRescale(n, (uint64_t)q0, (uint64_t)q1,
                        a0.data(), a1.data(), b0.data(), b1.data(),
                        p0.data(), p1.data(), o0.data(), o1.data());
  scatter(outc0, o0.data(), n); scatter(outc1, o1.data(), n);
}
