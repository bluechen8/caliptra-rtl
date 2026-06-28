# FHE (CKKS) accelerator — tests & how to reproduce them

This directory holds the exploration of an in-Caliptra **CKKS FHE accelerator**. There
are two test surfaces:

| Where | What | How it's tested |
|---|---|---|
| `rtl/`, `tb/` | **Stage-0 FHE block** — a behavioral CKKS accelerator integrated into Caliptra as an AHB-Lite responder (the integration shell). | a fast standalone Verilator unit TB + a firmware-driven smoke test on the full SoC |
| `aloha/` | **Aloha-HE bring-up (Stage A′)** — the real CKKS datapath (vendored `flokrieger/Aloha-HE`), brought up engine-by-engine in standalone Verilator and parameterized over the ring dimension `N`. | 7 self-checking / golden-vector testbenches at `N=8192` and at small `N` |

Everything below is runnable from this directory (`src/fhe`).

---

## Prerequisites

- **Verilator 5.022** — the chipyard conda build at `/scratch/boru/chipyard/.conda-env/bin/verilator`.
  `aloha/sim/run_tb.sh` defaults `VERILATOR` to it; override with `VERILATOR=<path>`.
- **Python 3 + numpy** — for the FFT golden-vector generator.
- **Go 1.26.4 + Lattigo v6.1.1** — only needed to (re)generate the NTT golden vectors at small `N`.
  Self-contained toolchain at `/scratch/boru/go-toolchain`, module cache at `~/go` (offline-capable).
  Activate with `source aloha/tvgen/env.sh`.

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

### Golden-vector oracles (`aloha/tvgen/`)

Each is independent of the RTL (an external/standalone reference), and each is
self-gated by reproducing the shipped `N=8192` vectors before being used at small `N`.

| File | Engine(s) | Oracle | CLI |
|---|---|---|---|
| `main.go` | NTT | **Lattigo** NTT, root pinned to Aloha's `g` | `./tvgen` (verify @8192) · `./tvgen gen <LOGN> <out> [seed]` |
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

## B. Stage-0 FHE block tests

### Fast standalone unit TB (Verilator, ~seconds)

```bash
./tb/run_fhe_top_tb.sh      # builds + runs fhe_top_tb; prints "FHE_TOP_TB: TEST PASSED"
```

Exercises the AHB register block + the behavioral control FSM (NAME/VERSION, idle
status, register R/W, ENCRYPT→VALID, KEYGEN→VALID, busy-rejection, ZEROIZE).

### Firmware-driven smoke test on the full SoC

`smoke_test_fhe` boots the SoC (`caliptra_top_tb`), reaches `main()`, drives the FHE
AHB registers from VeeR, and prints `FHE smoke test PASSED`. It runs on the native
Caliptra build flow (VCS or Xcelium), not standalone Verilator:

```bash
# (one-time env per the caliptra build — see ../../../CLAUDE.md and the design-review progress doc)
make -C <rundir> -f $CALIPTRA_ROOT/tools/scripts/Makefile TESTNAME=smoke_test_fhe vcs   # or: xrun
```

Sources: `src/integration/test_suites/smoke_test_fhe/` + `libs/fhe_ckks/`. Full
instructions are in `design-review/fhe-ckks-implementation-progress.md` (§"How to run the tests").

---

## Notes / gotchas

- **Vendored RTL is a nested git submodule** (`aloha/vendor` → fork `bluechen8/Aloha-HE`,
  branch `caliptra-fhe`). The `N`-parameterization edits to the Aloha-HE RTL/TBs/scripts
  are made in-place there and tracked as commits on that branch.
- **Verilator 5.022 `-j 0`** occasionally throws a transient internal error
  (`attempted to destroy locked Thread Pool`) — just re-run.
- `run_tb.sh` always regenerates the `.coe`→`.mem` conversion, so switching
  `ALOHA_MIF_DIR` between default-`N` and small-`N` is safe.
