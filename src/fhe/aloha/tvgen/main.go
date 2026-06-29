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

	// `server_add <logn> <q_hex> <dir>`: the untrusted CKKS *server* for the
	// Rung 7a cosim. Imports the two public ciphertexts dumped by the Aloha RTL
	// (ct1_{c0,c1}.txt, ct2_{c0,c1}.txt -- NTT/eval-domain residues mod q) into
	// Lattigo's polynomial ring and homomorphically adds them with ring.Add (the
	// exact modular add the rlwe/ckks Evaluator dispatches to for ct+ct), writing
	// sum_{c0,c1}.txt back for the RTL to decrypt. Nothing secret crosses the
	// boundary -- only the public ciphertext polys. Proves Aloha cts are real
	// CKKS ring elements a standard library can operate on.
	if len(os.Args) >= 5 && os.Args[1] == "server_add" {
		var logn int
		fmt.Sscanf(os.Args[2], "%d", &logn)
		var q uint64
		fmt.Sscanf(strings.TrimPrefix(os.Args[3], "0x"), "%x", &q)
		dir := os.Args[4]
		N := 1 << logn
		rd := func(name string) []uint64 {
			f, err := os.Open(dir + "/" + name)
			if err != nil {
				panic(err)
			}
			defer f.Close()
			sc := bufio.NewScanner(f)
			sc.Buffer(make([]byte, 1<<20), 1<<20)
			out := make([]uint64, 0, N)
			for sc.Scan() {
				line := strings.TrimSpace(sc.Text())
				if line == "" {
					continue
				}
				var v uint64
				fmt.Sscanf(line, "%x", &v)
				out = append(out, v)
			}
			if len(out) != N {
				panic(fmt.Sprintf("%s: expected %d residues, got %d", name, N, len(out)))
			}
			return out
		}
		r, err := ring.NewRing(N, []uint64{q})
		if err != nil {
			panic(err)
		}
		poly := func(c []uint64) ring.Poly { p := r.NewPoly(); copy(p.Coeffs[0], c); return p }
		add := func(a, b []uint64) []uint64 {
			s := r.NewPoly()
			r.Add(poly(a), poly(b), s)
			return s.Coeffs[0]
		}
		c0sum := add(rd("ct1_c0.txt"), rd("ct2_c0.txt"))
		c1sum := add(rd("ct1_c1.txt"), rd("ct2_c1.txt"))
		wr := func(name string, data []uint64) {
			of, err := os.Create(dir + "/" + name)
			if err != nil {
				panic(err)
			}
			w := bufio.NewWriter(of)
			for _, v := range data {
				fmt.Fprintf(w, "%x\n", v)
			}
			w.Flush()
			of.Close()
		}
		wr("sum_c0.txt", c0sum)
		wr("sum_c1.txt", c1sum)
		fmt.Printf("[server_add] N=%d q=0x%x: ct1+ct2 -> sum_{c0,c1}.txt (Lattigo ring.Add)\n", N, q)
		return
	}

	// `server_mul <logn> <q_hex> <dir>`: the Rung 7b server -- plaintext x
	// ciphertext. Imports the ciphertext (ct_{c0,c1}.txt) and the encoded
	// plaintext (pt.txt) -- all NTT/eval-domain *standard* residues mod q -- and
	// computes (pt*c0, pt*c1) with Lattigo's standard-domain coefficientwise
	// multiply (MulCoeffsBarrett, the op the rlwe Evaluator uses for pt*ct),
	// writing prod_{c0,c1}.txt. Degree-1 product => no relinearization key, and
	// nothing secret crosses the boundary (only public ct + public pt).
	if len(os.Args) >= 5 && os.Args[1] == "server_mul" {
		var logn int
		fmt.Sscanf(os.Args[2], "%d", &logn)
		var q uint64
		fmt.Sscanf(strings.TrimPrefix(os.Args[3], "0x"), "%x", &q)
		dir := os.Args[4]
		N := 1 << logn
		rd := func(name string) []uint64 {
			f, err := os.Open(dir + "/" + name)
			if err != nil {
				panic(err)
			}
			defer f.Close()
			sc := bufio.NewScanner(f)
			sc.Buffer(make([]byte, 1<<20), 1<<20)
			out := make([]uint64, 0, N)
			for sc.Scan() {
				line := strings.TrimSpace(sc.Text())
				if line == "" {
					continue
				}
				var v uint64
				fmt.Sscanf(line, "%x", &v)
				out = append(out, v)
			}
			if len(out) != N {
				panic(fmt.Sprintf("%s: expected %d residues, got %d", name, N, len(out)))
			}
			return out
		}
		r, err := ring.NewRing(N, []uint64{q})
		if err != nil {
			panic(err)
		}
		poly := func(c []uint64) ring.Poly { p := r.NewPoly(); copy(p.Coeffs[0], c); return p }
		mul := func(a, b []uint64) []uint64 {
			s := r.NewPoly()
			r.MulCoeffsBarrett(poly(a), poly(b), s) // standard*standard -> standard, mod q
			return s.Coeffs[0]
		}
		pt := rd("pt.txt")
		c0prod := mul(rd("ct_c0.txt"), pt)
		c1prod := mul(rd("ct_c1.txt"), pt)
		wr := func(name string, data []uint64) {
			of, err := os.Create(dir + "/" + name)
			if err != nil {
				panic(err)
			}
			w := bufio.NewWriter(of)
			for _, v := range data {
				fmt.Fprintf(w, "%x\n", v)
			}
			w.Flush()
			of.Close()
		}
		wr("prod_c0.txt", c0prod)
		wr("prod_c1.txt", c1prod)
		fmt.Printf("[server_mul] N=%d q=0x%x: pt*ct -> prod_{c0,c1}.txt (Lattigo MulCoeffsBarrett)\n", N, q)
		return
	}

	// `server_mul_rescale <logn> <q0_hex> <q1_hex> <dir>`: the Rung 7b-rescale
	// server -- 2-limb pt*ct then a CKKS RESCALE {q0,q1}->{q0} (divide by q1, drop
	// the q1 limb). Imports the 2-limb ciphertext (ct_{c0,c1}_{q0,q1}.txt) and the
	// 2-limb plaintext (pt_{q0,q1}.txt) -- all NTT/eval-domain standard residues --
	// multiplies per limb (MulCoeffsBarrett over the 2-modulus ring), then
	// DivRoundByLastModulusNTT (the rlwe Evaluator's rescale), writing the
	// single-limb prod_{c0,c1}.txt @q0 for the RTL to decrypt. The ring's BOTH
	// SubRing roots are pinned to Aloha's g so the rescale's internal INTT/NTT
	// keep the result in Aloha's convention.
	if len(os.Args) >= 6 && os.Args[1] == "server_mul_rescale" {
		var logn int
		fmt.Sscanf(os.Args[2], "%d", &logn)
		var q0, q1 uint64
		fmt.Sscanf(strings.TrimPrefix(os.Args[3], "0x"), "%x", &q0)
		fmt.Sscanf(strings.TrimPrefix(os.Args[4], "0x"), "%x", &q1)
		dir := os.Args[5]
		N := 1 << logn
		rd := func(name string) []uint64 {
			f, err := os.Open(dir + "/" + name)
			if err != nil {
				panic(err)
			}
			defer f.Close()
			sc := bufio.NewScanner(f)
			sc.Buffer(make([]byte, 1<<20), 1<<20)
			out := make([]uint64, 0, N)
			for sc.Scan() {
				line := strings.TrimSpace(sc.Text())
				if line == "" {
					continue
				}
				var v uint64
				fmt.Sscanf(line, "%x", &v)
				out = append(out, v)
			}
			if len(out) != N {
				panic(fmt.Sprintf("%s: expected %d residues, got %d", name, N, len(out)))
			}
			return out
		}
		r := newAlohaRing(N, []uint64{q0, q1}) // level 1 (2 limbs)
		// build a 2-limb poly from the q0,q1 residue files
		poly2 := func(q0name, q1name string) ring.Poly {
			p := r.NewPoly()
			copy(p.Coeffs[0], rd(q0name))
			copy(p.Coeffs[1], rd(q1name))
			return p
		}
		pt := poly2("pt_q0.txt", "pt_q1.txt")
		c0 := poly2("ct_c0_q0.txt", "ct_c0_q1.txt")
		c1 := poly2("ct_c1_q0.txt", "ct_c1_q1.txt")
		// pt*ct per limb (degree stays 1)
		pc0 := r.NewPoly()
		pc1 := r.NewPoly()
		r.MulCoeffsBarrett(c0, pt, pc0)
		r.MulCoeffsBarrett(c1, pt, pc1)
		// rescale {q0,q1} -> {q0}: divide by q1 (rounded), drop the last limb
		buff := r.NewPoly()
		out0 := r.NewPoly()
		out1 := r.NewPoly()
		r.DivRoundByLastModulusNTT(pc0, buff, out0)
		r.DivRoundByLastModulusNTT(pc1, buff, out1)
		wr := func(name string, data []uint64) {
			of, err := os.Create(dir + "/" + name)
			if err != nil {
				panic(err)
			}
			w := bufio.NewWriter(of)
			for _, v := range data {
				fmt.Fprintf(w, "%x\n", v)
			}
			w.Flush()
			of.Close()
		}
		wr("prod_c0.txt", out0.Coeffs[0]) // rescaled, single limb @q0
		wr("prod_c1.txt", out1.Coeffs[0])
		fmt.Printf("[server_mul_rescale] N=%d q0=0x%x q1=0x%x: pt*ct + rescale{q0,q1}->{q0} -> prod_{c0,c1}.txt\n", N, q0, q1)
		return
	}

	// `verify [shipped_tv_dir]` (default: ../vendor/...Testbench/tv, i.e. run from tvgen/)
	tvDir := defaultShippedTV
	if len(os.Args) >= 3 && os.Args[1] == "verify" {
		tvDir = os.Args[2]
	}
	verify(tvDir)
}
