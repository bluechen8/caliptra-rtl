# FHE (CKKS) accelerator — tests & how to reproduce them

This directory holds the exploration of an in-Caliptra **CKKS FHE accelerator**. There
are two test surfaces:

| Where | What | How it's tested |
|---|---|---|
| `rtl/`, `tb/` | **Stage-0 FHE block** — a behavioral CKKS accelerator integrated into Caliptra as an AHB-Lite responder (the integration shell). | a fast standalone Verilator unit TB + a firmware-driven smoke test on the full SoC |
| `aloha/` | **Aloha-HE bring-up (Stage A′) + secret-key scheme (Rung 6) + client↔server cosim (Rung 7)** — the real CKKS datapath (vendored `flokrieger/Aloha-HE`), brought up engine-by-engine in standalone Verilator, parameterized over the ring dimension `N`, composed end-to-end with a real keygen + a dedicated secret-key PWM (`rtl/PWMSk.sv`), then run against **Lattigo as an untrusted homomorphic server**. | per-engine golden-vector TBs (§A.1–A.2) + a composed-core round-trip / secret-key-scheme TB (§A.3) + a single-run **DPI-C** Aloha⇄Lattigo cosim (§A.4: ct+ct, pt×ct, pt×ct+rescale), at `N=8192` and small `N` |

Everything below is runnable from this directory (`src/fhe`).

---

## Prerequisites

- **Verilator 5.022** — the chipyard conda build at `/scratch/boru/chipyard/.conda-env/bin/verilator`.
  `aloha/sim/run_tb.sh` defaults `VERILATOR` to it; override with `VERILATOR=<path>`.
- **Python 3 + numpy** — for the FFT golden-vector generator.
- **Go 1.26.4 + Lattigo v6.1.1** — needed to (re)generate the NTT golden vectors at small `N`, the
  Rung-6 keygen cross-check, and the Rung-7 Lattigo "server" (§A.4). Self-contained toolchain at
  `/scratch/boru/go-toolchain`, module cache at `~/go` (offline-capable). Activate with
  `source aloha/tvgen/env.sh` (the runners do this themselves).
- **A C/C++ compiler (conda `gcc`/`g++`)** — for the Rung-7 **DPI-C** cosim (§A.4), where cgo builds the
  Lattigo server into an in-process c-shared `.so` linked into the Verilator binary. (The engine/round-trip
  TBs and the `go run .` oracle CLI don't need it.)

---

## A. Aloha-HE engine tests (Stage A′)

Seven testbenches, one per datapath engine, run through a single generic runner:

```
aloha/sim/run_tb.sh <TOP_MODULE> <filelist.f> [extra verilator -G args...]
```

PASS = the run reaches `$finish` with zero assertion failures (the runner prints
`RESULT: PASS`). Useful env knobs: `CLEAN=1` forces a clean rebuild; `ALOHA_MIF_DIR`
and `ALOHA_TV_DIR` override the ROM-init (`.coe`) and golden-vector directories (used
for small-`N`, see §A.2).

### The engines

| Engine | TOP module | filelist | config (`-G`) | small-`N` golden source |
|---|---|---|---|---|
| Montgomery modmul | `tb_ModMul` | `aloha_rung1.f` | — | none (self-checking, `N`-independent) |
| FP butterfly | `tb_FFTButterfly` | `tb_fftbutterfly.f` | — | none (`N`-agnostic) |
| int→double | `tb_IntToFlpWrapper` | `tb_inttoflp.f` | — | `gen_pointwise.py` |
| Trivium sampling | `tb_RandomSampling` | `tb_randomsampling.f` | — | `gen_sampling.py` |
| pointwise mult | `tb_PWM` | `tb_pwm.f` | — | `gen_pointwise.py` |
| RNS map | `tb_RNS` | `tb_rns.f` | — | `gen_rns.py` |
| NTT | `tb_UnifiedTransformation` | `tb_unifiedtransformation.f` | `-GDO_FFT=0 -GFORWARD_TRANSFORM=1` | `tvgen` (Lattigo) + RNS-const ROM |
| FFT (stored twiddles) | `tb_UnifiedTransformation` | `tb_unifiedtransformation.f` | `-GDO_FFT=1 -GON_THE_FLY_GENERATION=0 -GFORWARD_TRANSFORM=1` | `gen_fft.py` (numpy) + stored-FFT ROM |
| FFT (on-the-fly) | `tb_UnifiedTransformation` | `tb_unifiedtransformation.f` | `-GDO_FFT=1 -GON_THE_FLY_GENERATION=1 -GFORWARD_TRANSFORM=1` | `gen_fft.py` (numpy) + RNS-const ROM |

### A.1 At `N=8192` (default — uses the shipped golden vectors, nothing to generate)

```bash
cd aloha/sim
./run_tb.sh tb_ModMul              aloha_rung1.f
./run_tb.sh tb_FFTButterfly        tb_fftbutterfly.f
./run_tb.sh tb_IntToFlpWrapper     tb_inttoflp.f
./run_tb.sh tb_RandomSampling      tb_randomsampling.f
./run_tb.sh tb_PWM                 tb_pwm.f
./run_tb.sh tb_RNS                 tb_rns.f
./run_tb.sh tb_UnifiedTransformation tb_unifiedtransformation.f -GDO_FFT=0 -GFORWARD_TRANSFORM=1                          # NTT
./run_tb.sh tb_UnifiedTransformation tb_unifiedtransformation.f -GDO_FFT=1 -GON_THE_FLY_GENERATION=0 -GFORWARD_TRANSFORM=1 # FFT, stored
./run_tb.sh tb_UnifiedTransformation tb_unifiedtransformation.f -GDO_FFT=1 -GON_THE_FLY_GENERATION=1 -GFORWARD_TRANSFORM=1 # FFT, on-the-fly
```

The golden vectors live in `aloha/vendor/Aloha-HE_Common/Testbench/tv/` and the ROM
init files in `aloha/vendor/Aloha-HE_Common/MemoryInitializationFiles/`; the runner wires
them up automatically.

### A.2 At small `N` (the `N`-parameterization validation)

The RTL is parameterized over `N=2^LOGN`. One script regenerates the ROM tables + golden
vectors for the requested `N` and runs every engine, printing a PASS/FAIL summary:

```bash
cd aloha
./run_smalln.sh 8      # N=256  (default if LOGN omitted)
```

It also works at `LOGN=9` (512), `10` (1024), etc. The Solinas prime is reused from the
shipped moduli (it satisfies `q ≡ 1 mod 2N` for any `N ≤ 8192`). All artifacts land under
`aloha/build/N<N>/` (gitignored) — per-engine `.log`s are kept there for inspection.

**Smallest workable `N`:** `128` (`LOGN=7`) — all engines pass. Below that (`N=64`), the
NTT and on-the-fly FFT fail because `UnifiedTwFctGen`'s on-the-fly twiddle cache has a
structural lower bound (its fixed stage-0..4 cache + the `take_from_rom < 16` cutoff assume
enough radix-2 stages); the stored-FFT and pointwise/sampling engines still pass that low.
`N=256` is the recommended small-`N` target.

Under the hood the script just does, per engine: regenerate ROMs (`vendor/Scripts/Generate*.py`)
+ goldens (`tvgen/`), then `CLEAN=1 ALOHA_MIF_DIR=… ALOHA_TV_DIR=… ./sim/run_tb.sh <TOP> <flist> <-G config> -GN=<N>`.
`tb_ModMul` / `tb_FFTButterfly` are `N`-independent and run without `-GN`/overrides.

### A.3 Composed-core round-trip & secret-key scheme (Rungs 5–6)

The engine TBs above check each datapath block in isolation. `tb_ckks_roundtrip.sv`
exercises the **whole composed core** (`ComputeCoreWrapper` → FFT → sample → RNS → NTT →
PWM → iNTT → I2F → iFFT → PROJECT), driven through the `INS_RAM` microcode sequencer via
the SDK `send64`/`receive64`/`exeIns` debug-IO protocol. One runner, mode-selected by env var:

```
aloha/sim/run_roundtrip.sh <golden_dir> [N]      # N defaults to 8192
```

| Mode (env) | Rung | What it checks | Build |
|---|---|---|---|
| *(none)* | 5a | encode+encrypt+decrypt+decode vs **SEAL goldens**, bit-exact @ N=8192 | pk (`SCHEME=0`) |
| `ROUNDTRIP=1` | 5c | self-contained recovered≈input round-trip (all-HW keypair, `s=1` hack) | pk |
| `SKSCHEME_HW=1` | 6 | **real ternary keygen + secret-key scheme** on the **dedicated `PWMSk`** (self-contained: HW negate, `c1=a` passthrough) | sk (`+define+FHE_SK_HW`) |

`SKSCHEME_HW=1` additionally runs an **independent NTT-oracle keygen cross-check**
(dump the sampled ternary `s` + the HW `s_ntt`, recompute `NTT(s)` under q0 with the Go/Lattigo
oracle, require bit-exact) — this is the real keygen gate, since the round-trip alone can't catch a
bad key (the encrypt-negate and decrypt MontMuls cancel for any blob). Needs `source aloha/tvgen/env.sh`.

```bash
cd aloha
# Rung 5a — composed core vs SEAL goldens @ N=8192 (shipped goldens in build/full8192):
./sim/run_roundtrip.sh build/full8192 8192
# Rung 6 — keygen + secret-key scheme on the dedicated PWMSk, at small N (compile-time SCHEME=1):
SKSCHEME_HW=1 ALOHA_MIF_DIR=$PWD/build/N256/mif ./sim/run_roundtrip.sh build/rt256 256
# At N=8192 the default (vendor) ROMs are used — omit ALOHA_MIF_DIR:
SKSCHEME_HW=1 ./sim/run_roundtrip.sh build/rt8192 8192
```

Validated at **N = 128 / 256 / 8192**. Small-`N` inputs/ROMs are produced like §A.2:
`GenerateConstantsROM.py <LOGN>` + `GenerateStoredFFTTwiddleFct.py <LOGN>` into `build/N<N>/mif`,
and `tvgen/gen_roundtrip.py <LOGN> build/rt<N>` for the plaintext + seeds. The **`SCHEME`**
generator flag selects the encryption datapath: `0` = vendor public-key PWM (the SEAL-golden
reference, default), `1` = secret-key `PWMSk` (`rtl/PWMSk.sv`, selected by `+define+FHE_SK_HW`).
The pk path (5a/5c) stays green under the default build; the sk path runs under the `FHE_SK_HW` build.

### A.4 Client↔server cosim — Aloha (RTL) ⇄ Lattigo (untrusted server) (Rung 7)

The first test of the actual **FHE-client use case**, and the strongest correctness statement in the
ladder: the Aloha RTL (trusted client) keygens + secret-key-encrypts, an **untrusted Lattigo "server"**
runs the homomorphic evaluation on the *public* ciphertext, and the RTL decrypts the result — proving
Aloha ciphertexts are real CKKS ciphertexts that interoperate with a standard library.

It runs as a **single `verilator --binary` run via DPI-C**: the testbench calls an `import "DPI-C"`
function mid-simulation that hands the *public* ciphertext to an **in-process** Lattigo server (built from
`tvgen/` as a c-shared `.so`) and gets the result back. The secret key `s` **provably never leaves the sim
process** — no second process, no re-keygen, no ciphertext files on disk; only the public ciphertext
crosses the DPI boundary. One driver, op-selected by `COSIM_OP`; needs `source aloha/tvgen/env.sh` (Go)
**and a C compiler** (the conda `gcc`, used by cgo for the `.so`).

```
COSIM_OP=add|mul|rescale  aloha/sim/run_cosim_dpi.sh [golden_dir] [N] [seed]   # N defaults to 8192
```

| `COSIM_OP` | Op | Server (Lattigo) | Check |
|---|---|---|---|
| `add` (default) | `ct(m1) + ct(m2)` | `ring.Add` | recovered ≈ `m1 + m2` |
| `mul` | `pt(m2) × ct(m1)`, single modulus | `MulCoeffsBarrett` | recovered ≈ **complex** `m1 ⊙ m2` |
| `rescale` | **2-limb** `pt(m2) × ct(m1)` + CKKS **rescale** `{q0,q1}→{q0}` | per-limb mul + `DivRoundByLastModulusNTT` | recovered ≈ `m1 ⊙ m2` |

```bash
cd aloha
COSIM_OP=add     ./sim/run_cosim_dpi.sh 256     # ct+ct interop (small N regenerates q0 ROMs automatically)
COSIM_OP=mul     ./sim/run_cosim_dpi.sh 256     # pt*ct multiply interop
COSIM_OP=rescale ./sim/run_cosim_dpi.sh 256     # 2-limb pt*ct + rescale {q0,q1}->{q0}
COSIM_OP=add     ./sim/run_cosim_dpi.sh 8192    # ...likewise at the production size
```

PASS = `tb_ckks_roundtrip DPI cosim RESULT: PASS` (the recovered-vs-expected check). Validated at
**N = 256 / 8192**, all three ops. Plaintexts `m1`,`m2` come from `tvgen/gen_cosim.py` (run by the driver);
all artifacts land in `build/cosimdpi<N>/`. How it's wired:

- `tvgen/main.go` holds the homomorphic-eval cores `coreAdd` / `coreMul` / `coreMulRescale` (Lattigo
  `ring.Add` / `MulCoeffsBarrett` / `DivRoundByLastModulusNTT`); `newAlohaRing` pins every modulus's NTT
  root to Aloha's `g` (required for the rescale's internal INTT/NTT).
- `tvgen/cosim_dpi.go` (`//go:build dpi`) exports those cores via cgo (`//export AlohaServer{Add,Mul,MulRescale}`);
  built with `go build -tags dpi -buildmode=c-shared -o libfhecosim.so` (excluded from the plain `go run .`
  oracle CLI, which therefore needs no C toolchain).
- `sim/fhe_cosim_dpi.cpp` is the Verilator DPI-C shim (gathers the SV open-array polys → calls the cores →
  scatters results back).
- `sim/tb_ckks_roundtrip.sv` provides the `+DPICOSIM` mode (`+DPIOP=add|mul|rescale`) behind
  `` `ifdef FHE_DPI_COSIM `` — so the default (Rung 5/6) build never references the DPI symbols. It composes
  the validated `cosim_{keygen,encrypt,decrypt,encode_pt,…}` tasks: keygen → encrypt → `fhe_dpi_*` → decrypt.
- `sim/run_cosim_dpi.sh` builds the `.so`, builds the Verilator binary (`+define+FHE_SK_HW +FHE_DPI_COSIM`,
  links `-lfhecosim`), and runs once.

### Golden-vector oracles (`aloha/tvgen/`)

Each is independent of the RTL (an external/standalone reference), and each is
self-gated by reproducing the shipped `N=8192` vectors before being used at small `N`.

| File | Engine(s) | Oracle | CLI |
|---|---|---|---|
| `main.go` | NTT | **Lattigo** NTT, root pinned to Aloha's `g` | `./tvgen` (verify @8192) · `./tvgen gen <LOGN> <out> [seed]` · `./tvgen ntt <LOGN> <q_hex> <in> <out>` (forward NTT of an arbitrary residue poly under modulus `q`; used by the Rung-6 keygen cross-check `check_keygen.py`) |
| `main.go` (cores) + `cosim_dpi.go` (`//go:build dpi`) | — | **Lattigo** homomorphic eval (`coreAdd`/`coreMul`/`coreMulRescale`), exported for **in-process** DPI-C (Rung 7) | not a CLI — `go build -tags dpi -buildmode=c-shared -o libfhecosim.so .` emits the `.so`+header that `sim/fhe_cosim_dpi.cpp` links. Driven by `run_cosim_dpi.sh`. |
| `gen_fft.py` | FFT | **numpy** special-FFT `exp(-iπk/N)·DFT(bitrev(x))` | `gen_fft.py validate <shipped_tv>` · `gen_fft.py gen <LOGN> <out>` |
| `gen_sampling.py` + `trivium.py` | sampling | **Trivium** port (cipher-gated vs serial eSTREAM Trivium) | `gen_sampling.py <LOGN> <shipped_tv> <out>` |
| `gen_pointwise.py` | IntToFlp, PWM | per-coefficient transforms computed from the input: IntToFlp `signed(int,q)·2^scale`; PWM `MontMul(a,b)+c` | `gen_pointwise.py validate <shipped_tv>` · `gen_pointwise.py gen <LOGN> <shipped_tv> <out>` |
| `gen_rns.py` | RNS | float→int (significand `<< (exp+scale)`, rounding on negative shifts) reduced mod `q`, plus the `+e0` encrypt term and the `e1`/`v` sample reductions — computed from the input | `gen_rns.py validate <shipped_tv>` · `gen_rns.py gen <LOGN> <shipped_tv> <out>` |

> **RNS golden range.** `gen_rns.py` reproduces the shipped `N=8192` golden bit-for-bit
> (`validate`) and computes small-`N` goldens from fresh inputs. The float→int datapath only
> supports `e_unbiased = raw_exp + scale` up to ~`159` (four 40-bit Montgomery chunks), so the
> generator constrains the random doubles to that range (matching the shipped distribution,
> whose `e_unbiased` tops out at `76`); doubles outside it would overflow the chunked shifter,
> which the HW does not model.
>
> The **scale** that drives the float↔int shift is a *programmable input*, not hardwired: it
> arrives per RNS block in the `double_rns_testvec` / `int_to_double_wrap_testvec` headers
> (and in HW on the `scale`/`scale_power_DP` port), so each modulus level can carry its own
> CKKS scaling exponent.

> The two `Generate*.py` ROM scripts live under `aloha/vendor/Scripts/`; both take
> `LOGN` as arg 1 and an output path as arg 2. Always pass an explicit output path
> (as above) — the no-arg defaults target the in-tree `.coe` files and
> `GenerateStoredFFTTwiddleFct.py` would overwrite the shipped one. At `LOGN=13` the
> regenerated tables match the shipped ROMs (the stored-FFT table differs only by a
> 2-ULP `cmath.exp` rounding drift, well within the FFT tolerance).

---

## B. Caliptra-integrated FHE block tests

Three surfaces, in ascending fidelity: the Stage-0 behavioral stub, the B′ real datapath +
dedicated DMA (standalone Verilator), and the full-SoC firmware-driven smoke (VeeR on
`caliptra_top_tb`, VCS).

### Fast standalone unit TB — Stage-0 stub (Verilator, ~seconds)

```bash
./tb/run_fhe_top_tb.sh      # builds + runs fhe_top_tb; prints "FHE_TOP_TB: TEST PASSED"
```

Exercises the AHB register block + the behavioral control FSM (NAME/VERSION, idle
status, register R/W, ENCRYPT→VALID, KEYGEN→VALID, busy-rejection, ZEROIZE).

### B′ 2c — real datapath + dedicated FHE DMA (AHB-driven round-trip, Verilator)

`fhe_top` built with `+define+FHE_WALKER` instantiates the **real** datapath — the
microsequencer (`fhe_microseq`) driving the Aloha `ComputeCore`, plus the dedicated
**`fhe_dma`** engine (reuses Caliptra's `axi_mgr_rd`/`axi_mgr_wr` + `caliptra_prim_fifo_sync`)
on an AXI4 manager port. The TB plays firmware over AHB (seeds / scales / `CONFIG.L`
+ the 4 DMA pointer registers + `CMD`) and backs the manager with a behavioral AXI
subordinate DRAM model; keygen → encrypt → decrypt round-trips the ciphertext through
**real AXI bursts** and checks recovered ≈ input.

```bash
# from src/fhe/ — default LOGN=8 (N=256); pass 13 for N=8192. CLEAN=1 forces a rebuild.
CLEAN=1 ./tb/run_fhe_top_dma_tb.sh 8      # N=256  (regenerates small-N ROMs + plaintext)
CLEAN=1 ./tb/run_fhe_top_dma_tb.sh 13     # N=8192 (uses the shipped vendor ROMs)
# -> "fhe_top_dma_tb RESULT: PASS"  (recovered vs input, rel<2^-30)
```

All build/run artifacts (Verilator `obj_dir`, the depth-5 ROM rundir, the generated
small-N ROMs + `input.txt`, the log) go under `src/fhe/build/` — gitignored, never
under `tb/`. The walker's instruction/seed trace alone (no core, no DMA) is checked by
`./tb/run_fhe_microseq.sh`; the walker driving the real core (no DMA, TB array model)
is the `+WALKER` mode of `aloha/sim/run_roundtrip.sh` (see §A.3).

### B′ 2c-step-3 — firmware-driven smoke on the full SoC (VeeR → real datapath → DMA)

The end-to-end milestone: `smoke_test_fhe` boots the full `caliptra_top_tb`, reaches
`main()`, and drives the FHE AHB registers from **VeeR firmware** to run the real Aloha
datapath. It programs the microsequencer seeds / scales / `CONFIG.L` + the 4 DMA pointer
registers, then issues **KEYGEN → ENCRYPT → DECRYPT** (polling `STATUS.VALID` per command).
The ciphertext round-trips through the dedicated `fhe_dma` engine to a behavioral AXI DRAM
model wired onto `caliptra_top`'s FHE manager port; the testbench backdoor-preloads the
plaintext and, after the final `DMA_OUT`, checks recovered ≈ input (VeeR can't reach the
DMA's external DRAM, so the TB owns the data check while the firmware owns the control path).

This is the native Caliptra flow under **VCS** — Verilator 5.022 can **not** build the full
`caliptra_top_tb` (the base SoC BFM uses `process::self()`/`fork` + `force` on VeeR input
ports; pre-existing, unrelated to FHE). One harness does golden + ROM generation, the rv32
firmware build, the VCS build, and the run:

```bash
# from src/fhe/ — sources /ecad/tools/vlsi.bashrc for VCS; default LOGN=8 (N=256).
SIM=vcs ./tb/run_smoke_fhe.sh 8
# -> [FHE-TB] FHE DMA round-trip: PASS ...  * TESTCASE PASSED  ->  smoke_test_fhe RESULT: PASS
```

Under the hood it generates `input.txt` + the Aloha FFT/RNS ROM `.mem` into the rundir,
builds `program.hex` with the rv32 multilib toolchain, then builds+runs the model via the
native Makefile with the FHE filelist + defines:

```bash
make -C <rundir> -f $CALIPTRA_ROOT/tools/scripts/Makefile \
  TESTNAME=smoke_test_fhe \
  TB_VF=$CALIPTRA_ROOT/src/integration/config/caliptra_top_tb_fhe.vf \
  EXTRA_DEFS="+define+FHE_WALKER +define+FHE_N=256" \
  VERILATOR_RUN_ARGS="+FHE_TVDIR=<rundir>" vcs      # or: xrun
```

`caliptra_top_tb_fhe.vf` = the base `caliptra_top_tb.vf` (`-f`-included) + the Aloha core
(`aloha_core.f`) + `fhe_microseq`/`fhe_dma`, with the vendored Aloha sources bracketed by
`` `default_nettype wire`/`none `` (they predate Caliptra's nettype-none convention). The
`TB_VF` override keeps the lean default build untouched. Validated at **N = 256** (VCS
V-2023.12). Sources: `src/integration/test_suites/smoke_test_fhe/` + `libs/fhe_ckks/`. Full
status in `design-review/fhe-ckks-bprime-microsequencer.md` (§2c-step-3).

---

## Notes / gotchas

- **Vendored RTL is a nested git submodule** (`aloha/vendor` → fork `bluechen8/Aloha-HE`,
  branch `caliptra-fhe`). The `N`-parameterization edits to the Aloha-HE RTL/TBs/scripts
  are made in-place there and tracked as commits on that branch.
- **Verilator 5.022 `-j 0`** occasionally throws a transient internal error
  (`attempted to destroy locked Thread Pool`) — just re-run. It can also print this with a
  nonzero exit *after* successfully producing the binary; `run_cosim_dpi.sh` therefore gates on the
  binary's existence, not the exit code.
- **DPI-C plumbing (Rung 7c):** Verilator `--binary` compiles only **`.cpp`** DPI files (a `.c` is
  silently dropped → "undefined reference"); use `extern "C"` in a `.cpp`. Open-array DPI imports map to
  `const svOpenArrayHandle` (read with `svGetArrElemPtr1`) — a **dynamic** SV array can't be the actual,
  so the TB stages through fixed `[N]` buffers. And don't begin a comment with `// Verilator …` — it's
  parsed as a lint metacomment.
- `run_tb.sh` always regenerates the `.coe`→`.mem` conversion, so switching
  `ALOHA_MIF_DIR` between default-`N` and small-`N` is safe.
