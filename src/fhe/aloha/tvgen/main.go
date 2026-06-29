// tvgen — Lattigo-backed test-vector oracle for the Aloha-HE CKKS bring-up.
//
// Lattigo is the independent CKKS oracle (replacing SEAL's original role). Its
// NTT *algorithm* is used, with the 2N-th root pinned to Aloha-HE's minimum
// root g (overwriting the exported RootsForward/RootsBackward, since the public
// API won't force a root). Validated bit-exact against the shipped N=8192 tv.
//
// Usage (run from tvgen/, or pass an explicit dir):
//   tvgen [verify [shipped_tv_dir]]   verify NTT oracle vs shipped ntt_out @N=8192
//                                     (default dir: ../vendor/Aloha-HE_Common/Testbench/tv)
//   tvgen gen <LOGN> <outdir>         emit ntt_in.txt + ntt_out.txt at N=2^LOGN
package main

import (
	"bufio"
	"fmt"
	"math/big"
	"math/bits"
	"math/rand"
	"os"
	"strings"

	"github.com/tuneinsight/lattigo/v6/ring"
)

// The ntt tv uses modulus index 6: Solinas q with current_k=6, qm=0xd.
const (
	nttConstantsSel = 6
	nttCurrentK     = 6
	nttQm           = 0xd
	nttQ            = uint64(0xffffff3000001)
)

func modExp(b, e, m uint64) uint64 {
	return new(big.Int).Exp(big.NewInt(0).SetUint64(b), big.NewInt(0).SetUint64(e), big.NewInt(0).SetUint64(m)).Uint64()
}
func modInv(a, m uint64) uint64 {
	return new(big.Int).ModInverse(big.NewInt(0).SetUint64(a), big.NewInt(0).SetUint64(m)).Uint64()
}

// alohaMinPrimitiveRoot mirrors Scripts/helper.py find_min_primitive_root(2N,q),
// independently of helper.py: any 2N-th primitive root b (b^N==q-1), then the
// minimum among its odd powers.
func alohaMinPrimitiveRoot(twoN, q uint64) uint64 {
	exp := (q - 1) / twoN
	var b uint64
	for a := uint64(2); a < q; a++ {
		c := modExp(a, exp, q)
		if modExp(c, twoN/2, q) == q-1 {
			b = c
			break
		}
	}
	qq := big.NewInt(0).SetUint64(q)
	bsq := new(big.Int).Mod(new(big.Int).Mul(big.NewInt(0).SetUint64(b), big.NewInt(0).SetUint64(b)), qq)
	cg := big.NewInt(0).SetUint64(b)
	g := big.NewInt(0).SetUint64(b)
	for i := uint64(0); i < twoN; i++ {
		if cg.Cmp(g) < 0 {
			g.Set(cg)
		}
		cg.Mod(new(big.Int).Mul(cg, bsq), qq)
	}
	return g.Uint64()
}

// newAlohaSubRing builds a Lattigo SubRing for (N, q) but pins its NTT root to
// Aloha's minimum 2N-th root g, by overwriting the exported RootsForward/Backward
// (the public API won't force a root). Returns the SubRing and g.
func newAlohaSubRing(N int, q uint64) (*ring.SubRing, uint64) {
	g := alohaMinPrimitiveRoot(uint64(2*N), q)
	r, err := ring.NewRing(N, []uint64{q})
	if err != nil {
		panic(err)
	}
	sr := r.SubRings[0]
	logNthRoot := bits.Len64(sr.NthRoot>>1) - 1 // = log2(N)
	gInv := modInv(g, q)
	for j := uint64(0); j < uint64(N); j++ {
		idx := bits.Reverse64(j) >> (64 - uint(logNthRoot))
		sr.RootsForward[idx] = ring.MForm(modExp(g, j, q), q, sr.BRedConstant)
		sr.RootsBackward[idx] = ring.MForm(modExp(gInv, j, q), q, sr.BRedConstant)
	}
	return sr, g
}

// newAlohaRing builds a multi-modulus Lattigo Ring with EVERY SubRing's NTT root
// pinned to Aloha's minimum 2N-th root g for that modulus (the multi-limb
// generalization of newAlohaSubRing). Needed for rescale, whose internal
// INTT/NTT must use Aloha's convention so the rescaled q0 limb stays decryptable.
func newAlohaRing(N int, qs []uint64) *ring.Ring {
	r, err := ring.NewRing(N, qs)
	if err != nil {
		panic(err)
	}
	for li, q := range qs {
		sr := r.SubRings[li]
		g := alohaMinPrimitiveRoot(uint64(2*N), q)
		logNthRoot := bits.Len64(sr.NthRoot>>1) - 1 // = log2(N)
		gInv := modInv(g, q)
		for j := uint64(0); j < uint64(N); j++ {
			idx := bits.Reverse64(j) >> (64 - uint(logNthRoot))
			sr.RootsForward[idx] = ring.MForm(modExp(g, j, q), q, sr.BRedConstant)
			sr.RootsBackward[idx] = ring.MForm(modExp(gInv, j, q), q, sr.BRedConstant)
		}
	}
	return r
}

func readTV(path string) (curK, qm uint64, data []uint64) {
	f, err := os.Open(path)
	if err != nil {
		panic(err)
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	first := true
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		if first {
			var cs uint64
			fmt.Sscanf(line, "%x %x %x", &cs, &curK, &qm)
			first = false
			continue
		}
		var v uint64
		fmt.Sscanf(line, "%x", &v)
		data = append(data, v)
	}
	return
}

func writeTV(path string, data []uint64) {
	f, err := os.Create(path)
	if err != nil {
		panic(err)
	}
	defer f.Close()
	w := bufio.NewWriter(f)
	defer w.Flush()
	fmt.Fprintf(w, "%x %x %x\n", nttConstantsSel, nttCurrentK, nttQm) // header: constants_sel current_k qm
	for _, v := range data {
		fmt.Fprintf(w, "%x\n", v)
	}
}

// shipped tv dir, relative to tvgen/ (where verify is run / built); override by
// passing the dir to the `verify` subcommand. No absolute paths baked in.
const defaultShippedTV = "../vendor/Aloha-HE_Common/Testbench/tv"

// verify re-checks the oracle reproduces the shipped ntt_out bit-exact.
func verify(tvDir string) {
	_, _, xin := readTV(tvDir + "/ntt_in.txt")
	_, _, xout := readTV(tvDir + "/ntt_out.txt")
	N := len(xin)
	sr, g := newAlohaSubRing(N, nttQ)
	fmt.Printf("[verify] N=%d q=0x%x g=0x%x\n", N, nttQ, g)
	out := make([]uint64, N)
	in := make([]uint64, N)
	copy(in, xin)
	sr.NTT(in, out)
	mism := 0
	for i := range out {
		if out[i] != xout[i] {
			mism++
		}
	}
	fmt.Printf("[verify] Lattigo NTT vs shipped ntt_out: %d/%d mismatches -> %s\n", mism, N,
		map[bool]string{true: "PASS", false: "FAIL"}[mism == 0])
}

// genSmallN emits ntt_in.txt + ntt_out.txt at N=2^logn into outdir.
func genSmallN(logn int, outdir string, seed int64) {
	N := 1 << logn
	sr, g := newAlohaSubRing(N, nttQ)
	// deterministic random input poly, coeffs in [0, q)
	rng := rand.New(rand.NewSource(seed)) // reproducible; seed varies for data-(in)dependence tests
	in := make([]uint64, N)
	for i := range in {
		in[i] = uint64(rng.Int63n(int64(nttQ)))
	}
	out := make([]uint64, N)
	cpin := make([]uint64, N)
	copy(cpin, in)
	sr.NTT(cpin, out)
	if err := os.MkdirAll(outdir, 0o755); err != nil {
		panic(err)
	}
	writeTV(outdir+"/ntt_in.txt", in)
	writeTV(outdir+"/ntt_out.txt", out)
	fmt.Printf("[gen] N=%d (LOGN=%d) q=0x%x g=0x%x -> %s/{ntt_in,ntt_out}.txt\n", N, logn, nttQ, g, outdir)
}

// ---- in-memory homomorphic-eval cores --------------------------------------
// The untrusted CKKS "server" payload (Rung 7), decoupled from transport. The
// single-run DPI-C cosim (Rung 7c) reaches these in-process via cosim_dpi.go's
// cgo exports (`-tags dpi -buildmode=c-shared`); the testbench hands them the
// PUBLIC ciphertext mid-sim and gets the result back, so the secret key never
// leaves the sim process. Inputs/outputs are NTT/eval-domain standard residues,
// one RNS limb per []uint64.

// coreAdd: ct1 + ct2 (Rung 7a). Plain modular add per poly.
func coreAdd(N int, q uint64, c0a, c1a, c0b, c1b []uint64) (c0sum, c1sum []uint64) {
	r, err := ring.NewRing(N, []uint64{q})
	if err != nil {
		panic(err)
	}
	poly := func(c []uint64) ring.Poly { p := r.NewPoly(); copy(p.Coeffs[0], c); return p }
	add := func(a, b []uint64) []uint64 { s := r.NewPoly(); r.Add(poly(a), poly(b), s); return s.Coeffs[0] }
	return add(c0a, c0b), add(c1a, c1b)
}

// coreMul: pt * ct, single modulus (Rung 7b). Standard*standard coeff multiply.
func coreMul(N int, q uint64, c0, c1, pt []uint64) (c0prod, c1prod []uint64) {
	r, err := ring.NewRing(N, []uint64{q})
	if err != nil {
		panic(err)
	}
	poly := func(c []uint64) ring.Poly { p := r.NewPoly(); copy(p.Coeffs[0], c); return p }
	mul := func(a, b []uint64) []uint64 { s := r.NewPoly(); r.MulCoeffsBarrett(poly(a), poly(b), s); return s.Coeffs[0] }
	return mul(c0, pt), mul(c1, pt)
}

// coreMulRescale: 2-limb pt*ct then RESCALE {q0,q1}->{q0} (Rung 7b-rescale).
// BOTH SubRing roots pinned to Aloha's g (newAlohaRing) so the rescale's
// internal INTT/NTT stay in Aloha's convention; returns the single q0 limb.
func coreMulRescale(N int, q0, q1 uint64, c0q0, c0q1, c1q0, c1q1, ptq0, ptq1 []uint64) (c0out, c1out []uint64) {
	r := newAlohaRing(N, []uint64{q0, q1})
	poly2 := func(a0, a1 []uint64) ring.Poly {
		p := r.NewPoly()
		copy(p.Coeffs[0], a0)
		copy(p.Coeffs[1], a1)
		return p
	}
	pt := poly2(ptq0, ptq1)
	c0 := poly2(c0q0, c0q1)
	c1 := poly2(c1q0, c1q1)
	pc0 := r.NewPoly()
	pc1 := r.NewPoly()
	r.MulCoeffsBarrett(c0, pt, pc0)
	r.MulCoeffsBarrett(c1, pt, pc1)
	buff := r.NewPoly()
	out0 := r.NewPoly()
	out1 := r.NewPoly()
	r.DivRoundByLastModulusNTT(pc0, buff, out0)
	r.DivRoundByLastModulusNTT(pc1, buff, out1)
	return out0.Coeffs[0], out1.Coeffs[0]
}

func main() {
	if len(os.Args) >= 4 && os.Args[1] == "gen" {
		var logn int
		fmt.Sscanf(os.Args[2], "%d", &logn)
		var seed int64 = 1234
		if len(os.Args) >= 5 {
			fmt.Sscanf(os.Args[4], "%d", &seed)
		}
		genSmallN(logn, os.Args[3], seed)
		return
	}
	// `ntt <logn> <q_hex> <in_residues.txt> <out.txt>`: forward NTT of an
	// arbitrary residue poly under an arbitrary Solinas modulus q (Aloha root +
	// HW bit-reversed output order). Input/output are plain hex, one per line,
	// no header. Used by the Rung-6 keygen cross-check (verify HW s_ntt == NTT(s)).
	if len(os.Args) >= 6 && os.Args[1] == "ntt" {
		var logn int
		fmt.Sscanf(os.Args[2], "%d", &logn)
		var q uint64
		fmt.Sscanf(strings.TrimPrefix(os.Args[3], "0x"), "%x", &q)
		N := 1 << logn
		in := make([]uint64, 0, N)
		f, err := os.Open(os.Args[4])
		if err != nil {
			panic(err)
		}
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 1<<20), 1<<20)
		for sc.Scan() {
			line := strings.TrimSpace(sc.Text())
			if line == "" {
				continue
			}
			var v uint64
			fmt.Sscanf(line, "%x", &v)
			in = append(in, v)
		}
		f.Close()
		if len(in) != N {
			panic(fmt.Sprintf("ntt: expected %d residues, got %d", N, len(in)))
		}
		sr, g := newAlohaSubRing(N, q)
		out := make([]uint64, N)
		sr.NTT(in, out)
		of, err := os.Create(os.Args[5])
		if err != nil {
			panic(err)
		}
		w := bufio.NewWriter(of)
		for _, v := range out {
			fmt.Fprintf(w, "%x\n", v)
		}
		w.Flush()
		of.Close()
		fmt.Printf("[ntt] N=%d q=0x%x g=0x%x -> %s\n", N, q, g, os.Args[5])
		return
	}

	// `verify [shipped_tv_dir]` (default: ../vendor/...Testbench/tv, i.e. run from tvgen/)
	tvDir := defaultShippedTV
	if len(os.Args) >= 3 && os.Args[1] == "verify" {
		tvDir = os.Args[2]
	}
	verify(tvDir)
}
