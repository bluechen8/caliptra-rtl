//go:build dpi

// Rung 7c — c-shared bridge. Build with `-tags dpi -buildmode=c-shared` to emit
// libfhecosim.so + libfhecosim.h, exporting the CKKS homomorphic-eval cores as
// C-callable functions. The Verilator DPI shim (sim/fhe_cosim_dpi.cpp) links
// this .so and calls these mid-simulation, so the whole client<->server cosim
// runs in ONE RTL process and the secret key never leaves it.
//
// This file is excluded from the normal pure-Go CLI (`go run .`, no `dpi` tag),
// so the NTT-oracle / keygen-cross-check CLI (gen/ntt/verify in main.go) needs
// no C toolchain. The evaluation logic is coreAdd/coreMul/coreMulRescale (main.go).
package main

/* #include <stdint.h> */
import "C"
import "unsafe"

// view exposes a caller-owned C uint64 buffer of length n as a Go slice (no copy).
func view(p *C.ulonglong, n C.int) []uint64 {
	return unsafe.Slice((*uint64)(unsafe.Pointer(p)), int(n))
}

//export AlohaServerAdd
func AlohaServerAdd(n C.int, q C.ulonglong, c0a, c1a, c0b, c1b, outc0, outc1 *C.ulonglong) {
	N := int(n)
	s0, s1 := coreAdd(N, uint64(q), view(c0a, n), view(c1a, n), view(c0b, n), view(c1b, n))
	copy(view(outc0, n), s0)
	copy(view(outc1, n), s1)
}

//export AlohaServerMul
func AlohaServerMul(n C.int, q C.ulonglong, c0, c1, pt, outc0, outc1 *C.ulonglong) {
	N := int(n)
	p0, p1 := coreMul(N, uint64(q), view(c0, n), view(c1, n), view(pt, n))
	copy(view(outc0, n), p0)
	copy(view(outc1, n), p1)
}

//export AlohaServerMulRescale
func AlohaServerMulRescale(n C.int, q0, q1 C.ulonglong, c0q0, c0q1, c1q0, c1q1, ptq0, ptq1, outc0, outc1 *C.ulonglong) {
	N := int(n)
	o0, o1 := coreMulRescale(N, uint64(q0), uint64(q1),
		view(c0q0, n), view(c0q1, n), view(c1q0, n), view(c1q1, n),
		view(ptq0, n), view(ptq1, n))
	copy(view(outc0, n), o0)
	copy(view(outc1, n), o1)
}
