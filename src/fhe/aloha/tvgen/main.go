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
	// `verify [shipped_tv_dir]` (default: ../vendor/...Testbench/tv, i.e. run from tvgen/)
	tvDir := defaultShippedTV
	if len(os.Args) >= 3 && os.Args[1] == "verify" {
		tvDir = os.Args[2]
	}
	verify(tvDir)
}
