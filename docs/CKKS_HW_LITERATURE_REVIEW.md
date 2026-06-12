# CKKS Hardware Literature Review

*Background for adding a CKKS accelerator to the Caliptra root-of-trust (RoT) SoC. Focus: client-side primitives (encode, decode, encrypt, decrypt), side-channel countermeasures, and RoT integration.*

---

## Executive summary

The hardware-acceleration literature for CKKS is dominated by **datacenter-class ASIC accelerators** (F1, CraterLake, BTS, ARK, SHARP, CiFHER, REED, Heracles, Trebuchet, Basalisc) and **large FPGA shells** (HEAX, HEAWS, Poseidon, FAB, FxHENN, Medha). Almost all target the *server-side* hot path — key-switching, NTT, automorphism, bootstrapping — at ring dimensions N=2^15 to N=2^17 with RNS chains of 50–60-bit primes (or 32-bit primes in designs like SHARP that exploit short-word RNS for area savings). Their chip areas (100–400 mm² in 7–14 nm) and power budgets (50–300 W) are incompatible with an RoT block like Caliptra.

**Three findings frame this review:**

1. **Client-side operations are tractable at RoT scale.** Encode/encrypt and decode/decrypt for N=2^13–2^14 require only a small iFFT, a 4–8 lane RNS-NTT, and a sampler — roughly 250–400 K gates. The only published open hardware covering this scope is **Aloha-HE** (TU Graz, DATE 2024, VHDL/Verilog) and, for decode only, Lee/Duong/Lee (Sensors 2023). Both confirm that the iFFT/scaling step is small relative to the polynomial arithmetic.

2. **Side-channel defense infrastructure already exists in Caliptra.** Adams Bridge's ML-DSA accelerator ships masked AND/MUX, A2B/B2A conversion, masked adders/multipliers, and a partially-masked + shuffled NTT under Apache 2.0. These primitives transfer directly to a CKKS datapath. Published attacks on CKKS (RevEAL, DATE 2022; "Leaking Secrets," 2023) demonstrate that unprotected NTT is exploitable in a single trace — masking is not optional.

3. **No published RoT-resident CKKS accelerator with measured leakage results exists.** This is the gap. TVLA (Test Vector Leakage Assessment) applies Welch's t-test to power/EM traces collected under fixed-vs-random inputs; a |t| > 4.5 threshold flags exploitable leakage. Adams Bridge reports no first-order leakage at 1 M traces [48]. A CKKS block built in the same style, with the same test methodology, would be a first-of-its-kind contribution.

**Open-source RTL is rare.** Beyond Aloha-HE and Zama HPU (SystemVerilog, TFHE-oriented), Intel HEXL-FPGA is OpenCL/HLS — not synthesizable RTL. The opportunity is clear: build a client-side-only CKKS encrypt/decrypt accelerator in Adams Bridge-style SystemVerilog, reuse its masked primitive library, and validate with TVLA.

---

## Full-pipeline CKKS accelerators (server-class)

| System | Venue / Year | Platform | Ring N | Modulus chain | Area / Power | RTL public? |
|---|---|---|---|---|---|---|
| F1 [1] | MICRO 2021 | ASIC (14/12 nm) | up to 2^16 | RNS 28-bit primes | 151 mm² / 180 W | No |
| CraterLake [2] | ISCA 2022 | ASIC (14 nm sim) | 2^16–2^17 | 28-bit RNS | 472 mm² / 320 W | No |
| BTS [3] | ISCA 2022 | ASIC (7 nm sim) | 2^17 | 64-bit (extended) | 373.6 mm² / 163 W | No |
| ARK [4] | MICRO 2022 | ASIC (7 nm sim) | 2^16 | 60-bit RNS | 418.3 mm² / 281 W | No |
| SHARP [5] | ISCA 2023 | ASIC (7 nm sim) | 2^16 | **36-bit short word** | 178.8 mm² / 113 W | No |
| HEAX [6] | ASPLOS 2020 | FPGA (Stratix 10) | 2^13–2^15 | 54-bit RNS | not reported | No |
| HEAWS [7] | TC 2020 | AWS F1 (VU9P) | 2^13 (BFV) | 30-bit | not reported | No |
| Medha [8] | TCHES 2023 | Alveo U250 | 2^14, 2^15 | logQ=438/546 | 200 MHz | No |
| Poseidon [9] | HPCA 2023 | Alveo U280 + HBM | 2^16 | 54-bit RNS | not reported | No |
| FAB [10] | HPCA 2023 | Alveo U280 (cluster) | 2^16 | 54-bit RNS | per-FPGA 215 W | No |
| FPT [11] | CCS 2023 | Alveo U280 | TFHE N=1024 | fixed-point | not reported | **Yes** (TFHE not CKKS) |
| CASA [12] | TCHES 2024 | Artix-7 (mid-range!) | 2^13–2^15 | RNS multi-prime | XC7A200T / ~5.8 % CPU power | No |
| CiFHER [13] | MICRO 2024 | ASIC chiplet (7 nm) | 2^16 | 60-bit RNS | 4.28 mm²/chiplet | No |
| REED [14] | TCHES 2025 | ASIC 2.5D chiplet (7 nm) | 2^16 | 54-bit RNS | 96.7 mm² / 49.4 W | No |
| Taiyi [15] | arXiv 2024 | ASIC (TSMC 7 nm) | 2^16 | 64-bit | 1 GHz, Verilog (internal) | No |
| Trinity [16] | MICRO 2024 | ASIC | unified | unified | not reported | No |
| Trebuchet [17] | WAHC 2023 | ASIC tile (DPRIVE) | up to 2^17 | 128-bit | not reported | No |
| Basalisc [18] | ePrint 2022 | ASIC, 12 nm GF | BGV | RNS | 150 mm² target | No |
| Heracles [19] | ISSCC 2026 | Intel 3 nm | parametric | parametric | 200 mm² class / 176 W | No |
| HEAP [20] | ISCA 2024 | ASIC (BU/MIT) | CKKS+TFHE | hybrid | not reported | No |
| MAD [21] | MICRO 2023 | ASIC sim | 2^16 | 60-bit RNS | not reported | No |

### Per-system notes (grouped)

All systems above are server/datacenter designs (100+ mm², 100+ W, multi-GB SRAM/HBM) optimized for unbounded-depth evaluation of full neural-network inference or analytics workloads. None release RTL, and none target a constrained client-side or RoT footprint. They contextualize the parameter ranges and NTT/key-switch micro-architectures that a lightweight client-side encoder could eventually hand off to.

**Monolithic ASIC lineage (F1 → CraterLake → BTS/ARK/SHARP).** F1 [1] established the template: 64 MB on-chip SRAM, wide NTT vector lanes, and dedicated automorphism units (5400× over SEAL). CraterLake [2] extends this to unbounded bootstrapping via key-switch-hint prefetch (472 mm², 320 W). BTS [3], ARK [4], and SHARP [5] form the SNU trilogy that progressively optimizes bootstrapping scheduling, on-the-fly key generation, and word-width selection (36-bit sweet-spot); all exceed 150 mm² and 100 W — irrelevant for RoT integration.

**Chiplet and 2.5D disaggregation (CiFHER, REED, Taiyi).** CiFHER [13] decomposes the BTS/ARK architecture into 4.28 mm² chiplets scalable from 4 to 64 units. REED [14] is a 2.5D-chiplet ASIC (96.7 mm², 49.4 W, 2991× over CPU) with pipelined NTT. Taiyi [15] targets inner-product-dominated workloads at 1 GHz. All remain datacenter-class with no client-side applicability.

**FPGA implementations (HEAX, HEAWS, Medha, Poseidon, FAB, FPT).** HEAX [6] and HEAWS [7] are early FPGA proofs-of-concept on Stratix 10 and AWS F1. Medha [8] microcodes RNS-CKKS on Alveo U250 (68–78× over SEAL). Poseidon [9] and FAB [10] target Alveo U280 with HBM for full bootstrappable CKKS. FPT [11] is TFHE-only but is the sole open-source HE accelerator RTL (<https://github.com/KULeuven-COSIC/fpt-demo>); its fixed-point compression idea may port to CKKS encode. All require large FPGAs (100k+ LUTs, HBM) far beyond RoT budgets.

**Smallest footprint reference (CASA).** CASA [12] fits CKKS (N=2^13–2^15) into a mid-range Artix-7 at ~5.8% of CPU power using partial reduction-free modular arithmetic. This is the closest existing design to an RoT-class area budget, though it targets standalone acceleration rather than a side-channel-hardened encode-only datapath. Closed RTL.

**Hybrid and unified designs (Trinity, HEAP, MAD).** Trinity [16] unifies CKKS + TFHE in one dataflow. HEAP [20] parallelizes bootstrapping via TFHE BlindRotate. MAD [21] contributes memory-aware scheduling applicable across platforms. All are evaluation-side optimizations with no client-encode relevance.

---

## Open-source HDL projects

| Repo | Language | Last active | Primitives | Notes |
|---|---|---|---|---|
| [flokrieger/Aloha-HE](https://github.com/flokrieger/Aloha-HE) [22] | VHDL 69% / Verilog 21% / SV 0.6% | 2024 (DATE'24) | **encode, decode, encrypt, decrypt** (CKKS) | ZYNQ-7000 + Kintex-7. Most relevant for Caliptra integration. |
| [flokrieger/Aloha-HE_AMD-OpenHW](https://github.com/flokrieger/Aloha-HE_AMD-OpenHW) [22] | VHDL/Verilog | 2024 | Same as above | AMD OpenHW contest variant |
| [Sam-Vervaeck/NEORV32_AlohaHE_thesis](https://github.com/Sam-Vervaeck/NEORV32_AlohaHE_thesis) [23] | VHDL | 2024 | CKKS client ops + NEORV32 RISC-V wrapper | **Direct precedent**: CKKS coprocessor on a small RISC-V core |
| [zama-ai/hpu_fpga](https://github.com/zama-ai/hpu_fpga) [24] | SystemVerilog | 2025 active | TFHE (PBS), *not CKKS* | Alveo V80, 350 MHz, 7 nm + HBM2e, ~13k PBS/s; pure SV useful as templating reference |
| [intel/hexl-fpga](https://github.com/intel/hexl-fpga) [25] | Intel oneAPI / HLS | 2022 | NTT, INTT, KeySwitch, dyadic mult | Intel PAC D5005 — not portable RTL |
| [IntelLabs/hexl](https://github.com/IntelLabs/hexl) [26] | C++ / AVX-512 | archived 2024 | NTT, mod-mult (software) | Reference for NTT loop structure and Harvey/Shoup reduction |
| [KULeuven-COSIC/fpt-demo](https://github.com/KULeuven-COSIC/fpt-demo) [11] | Verilog / Vivado HLS | 2023 | TFHE bootstrapping (not CKKS) | Best open HW reference for low-precision FHE arithmetic |
| [openfheorg/openfhe-development](https://github.com/openfheorg/openfhe-development) [27] | C++ | active | Full CKKS software | Reference for parameter generation and correctness testing |
| [tuneinsight/lattigo](https://github.com/tuneinsight/lattigo) [28] | Go | active | Full CKKS | Cleaner than SEAL; multiparty support |

### Key takeaway

As of mid-2026, **Aloha-HE is the only open RTL that implements CKKS encode/decode/encrypt/decrypt end-to-end on the client side**. Zama's HPU is the only fully open SystemVerilog HE accelerator but targets TFHE (algorithmically distinct). For a Caliptra-class integration, the actionable starting points are:

1. **Aloha-HE RTL** [22] — direct port candidate for the CKKS datapath.
2. **NEORV32_AlohaHE** [23] — demonstrates the coprocessor-bus integration pattern on a minimal RISC-V core.
3. **Zama HPU** [24] — reusable SV infrastructure (memory controllers, scheduling) even though the crypto kernel differs.

---

## Encode / decode in hardware

### Algorithm summary

CKKS encode is **not** a polynomial-ring operation. It is the inverse canonical embedding: a length-N/2 complex inverse FFT, followed by multiplication by scaling factor Δ (typically 2^30–2^60) and rounding into Z[X]/(X^N+1) [29]. Decode is the forward transform.

### Implementations in the literature

| # | Work | Key Contribution | Open RTL? |
|---|------|-----------------|-----------|
| 1 | **Aloha-HE** (Krieger, Hirner, Mert, Sinha Roy — DATE 2024) [22] | Optimized floating-point unit for complex encoding; hardware-friendly modulo reduction of FP values after iFFT; datapath shared with modular-ring encryption arithmetic. 59× over prior solutions on Kintex-7. | **Yes** |
| 2 | **Lee, Duong, Lee** (Sensors 23(17), 2023) [30] | Configurable ENC/DEC for poly degrees 2^12–2^16, modular widths 20–64 bits, mult depth up to 30 at 128-bit security. 23.7× (encrypt) and 10.9× (decrypt) over SEAL on Alveo U250. | No |
| 3 | **DNA-HHE** (arXiv 2512.18589) [31] | Encoder on edge device with Rubato as the hybrid symmetric layer. | No |
| 4 | **CCAD'24 invited** (Krieger et al.) [32] | Encrypt-side encoding optimizations. | No |

### Design guidance for an RoT-class iFFT/encode block

- **Butterfly structure**: Radix-2 or radix-4 Cooley–Tukey with bit-reversed input is standard across all reported designs.
- **Precision trade-off**: Aloha-HE uses a dedicated floating-point datapath; Lee et al. parameterize 20–64-bit integers. Both note that Δ in the 2^50–2^60 range forces multi-precision arithmetic when the hardware word is narrower [33]. For a Caliptra-sized block, fixing Δ ≤ 2^40 keeps the datapath single-precision at the cost of reduced plaintext dynamic range. Alternatively, using 32-bit RNS primes (as in SHARP's short-word approach) avoids wide multipliers entirely while retaining sufficient ciphertext modulus via multi-prime decomposition.
- **Twiddle-Δ fusion**: The scaling factor Δ can be folded into twiddle constants at no extra cost if the iFFT is performed in (scaled) integer arithmetic — eliminates a separate multiplier stage.

---

## Encrypt / decrypt in hardware

### Algorithm summary

- **Encrypt**: Sample small error (CBD or discrete Gaussian) + uniform random polynomial *a*; compute `c0 = b·u + e1 + m`, `c1 = a·u + e2` in R_q (two NTT-domain poly multiplications + additions).
- **Decrypt**: Compute `m + e ≈ c0 + c1·s mod q`, then round and decode.

Both are far cheaper than bootstrapping — a few NTTs, a few CBD samples, a linear combination, and a final decode. This makes them tractable for an area-constrained RoT.

### Client-side hardware implementations

| Work | Scope | Platform | Relevance to Caliptra |
|------|-------|----------|----------------------|
| **Aloha-HE** [22] | Full encode+encrypt, decode+decrypt | Kintex-7 (small footprint) | **Highest** — explicitly client-side, open RTL |
| **Lee/Duong/Lee** [30] | Configurable ENC/DEC, N=4096–65536 | Alveo U250 | Architecture reference (closed source) |
| **DNA-HHE** [31] | Dual-mode RNS-CKKS + Rubato HHE | Edge accelerator | Hybrid-HE flow reference |
| **CCAD'24 invited** [32] | Encryption-only optimizations | — | Micro-architectural tricks for encrypt path |

### Actionable notes

1. **Server-side accelerators** (HEAX, F1, BTS, CraterLake, etc.) include encrypt/decrypt only nominally — they assume host-side encoding and are not optimized for the client path.
2. **Minimum viable datapath** for Caliptra: one NTT butterfly unit (time-multiplexed), a CBD sampler (trivial in hardware), and the shared iFFT/encode logic. Aloha-HE on Kintex-7 demonstrates this fits within a few thousand LUTs.
3. **Side-channel surface**: Encrypt's random sampling (CBD/Gaussian) and the secret-key multiply in decrypt are the primary leakage vectors. Constant-time NTT and masked CBD generation are required for RoT-grade deployment — neither Aloha-HE nor Lee et al. address this, so hardening is an open integration task.

---

## NTT cores and modulus flexibility

NTT/INTT is the dominant compute kernel in any CKKS hardware path — it appears in encrypt, decrypt, and every ciphertext operation. For a Caliptra-resident client-side accelerator, the key constraint is supporting RNS primes wide enough for the modulus chain. The standard choice is **50–60-bit primes** (matching OpenFHE/Lattigo defaults). An area-optimized alternative is **32-bit RNS primes**: sufficient NTT-friendly primes exist in the 30–32-bit range to compose a 4-prime chain at 128-bit security for small ring dimensions (N=2^13–2^14), halving the datapath width vs. 54-bit primes at the cost of more primes for the same total modulus budget.

### Available NTT building blocks

| Design | Key properties | Reuse potential for Caliptra CKKS |
|--------|---------------|-----------------------------------|
| **NTTGen** (NSF / Boston U., 2022) [34] | Parametric Verilog generator; supports 45–62-bit moduli; inputs (N, prime, resource budget) | Closest to drop-in for RNS-CKKS. Not maintained as a repo, but the published artifact is usable. |
| **High-Performance Digit-Serial NTT** (arXiv 2507.12418, 2025) [35] | Parametric digit-serial modular reduction; single fabric handles 50–60-bit primes without re-synthesis | Eliminates per-prime re-synthesis — ideal for a fixed RNS chain that may need prime updates. |
| **CASA NTT** (TCHES 2024) [12] | Partial reduction-free arithmetic across the RNS chain | Optimization to adopt: skip full reduction between butterfly stages, reducing critical path. |
| **Zama HPU NTT** (SystemVerilog, Apache 2.0) [24] | TFHE-oriented radix-N butterfly array | Butterfly topology and memory organization are reusable; modular reduction is not. |
| **Sam Reagen / IIT Madras NTT** (Mert et al., TU Graz / Birmingham) | Research NTT cores | Reference designs; less directly reusable. |

### Adams Bridge NTT: what transfers and what does not

Caliptra's Adams Bridge NTT/INTT engine (ChipsAlliance, Apache 2.0) is parameterized for Dilithium's q = 8,380,417 (23-bit). It is **not directly reusable for CKKS** because:

- CKKS uses RNS primes of 50–60 bits; Dilithium uses one 23-bit prime.
- The modular-reduction unit is hard-coded to Solinas form for the Dilithium prime.
- Twiddle ROM contents are prime-specific (roots of unity mod q). Changing to CKKS RNS primes requires regenerating all twiddle constants.

**Reuse directly (hardware modules, unchanged or re-parameterized):**
- Radix-2 pipelined NTT topology (pipeline staging, control FSM)
- Twiddle ROM *structure* (bank layout, address generation, read-port timing) — repopulated with CKKS-prime roots of unity
- Sample buffer (`abr_sample_buffer.sv`) and message buffer interfaces
- Masked arithmetic variants (`abr_masked_*`) — bit-width-parameterized, scale to 54-bit operands

**Reuse pattern only (architecture/approach, requires new implementation):**
- Modular reduction strategy — must be replaced with Barrett or Montgomery for wider primes
- Butterfly datapath width — new reduction logic needed at 54-bit (or 32-bit)

### Recommendation

The most valuable reuse from Adams Bridge is its **side-channel defense infrastructure** (masked primitives, shuffling logic), not the NTT arithmetic itself. Do not attempt to stretch the Dilithium NTT to CKKS primes. Instead:

1. **New datapath**: 50–55-bit Barrett or Montgomery reduction (or digit-serial per [35]) with 4–8 parallel RNS lanes.
2. **Reuse topology**: clone Adams Bridge's pipeline skeleton, twiddle ROM layout, and buffer management.
3. **Reuse masking**: instantiate `abr_masked_N_bit_mult.sv` and `abr_masked_N_bit_Boolean_adder.sv` at the wider bit-width for the critical NTT butterfly multiply-accumulate.
4. **Generator approach**: adapt NTTGen [34] to emit Adams Bridge-compatible SystemVerilog rather than standalone Verilog.

---

## Side-channel defenses for CKKS / RLWE hardware

### Threat model

**Asset**: The CKKS secret key `sk` (a short polynomial with ternary or small-norm coefficients). Compromise of `sk` breaks confidentiality of all ciphertexts encrypted under the corresponding public key.

**Attacker capabilities** (ordered by increasing difficulty):
1. **Passive power/EM observation** during key generation, decryption, or private-key encryption (when the RoT encrypts under its own secret for authenticated ciphertext / hybrid schemes) — the NTT of `sk` leaks coefficient values through operand-dependent switching activity.
2. **Chosen-ciphertext + side-channel** — attacker supplies crafted ciphertexts and observes decryption traces to isolate individual secret coefficients.
3. **Active fault injection** (EMFI, voltage glitch) — zeroing twiddle factors or corrupting NTT butterflies to induce exploitable outputs.

**Critical operations to protect** (client-side):
- `KeyGen`: NTT(sk) — ternary coefficients leak in a single trace.
- `Decrypt`: inner product ⟨ct, sk⟩ — secret-dependent multiplications.
- `Encrypt`: discrete Gaussian / CBD sampling — biased samples weaken ciphertext security.

### Published attacks on CKKS

| Attack | Target | Result | Implication |
|--------|--------|--------|-------------|
| **RevEAL** (Aydin et al., DATE 2022) [36] | SEAL NTT during key generation | 98.3% coefficient recovery, single trace, ML classifier | Unmasked NTT of ternary sk is broken in practice. |
| **"Leaking Secrets in HE"** (Aydin et al., 2023, ePrint 2023/1128) [37] | Extended RevEAL across compiler optimizations; `guard`/`mul_root` ops on ARM Cortex-M4F | 98.6% recovery | Attack generalizes across platforms and optimization levels. |
| **SCA in HE survey** (arXiv 2505.11058, 2025) [38] | Systematization of all CKKS/BFV SCA attacks | — | Confirms NTT and inner-product as primary leakage points. |

**Takeaway**: Any CKKS implementation that performs NTT(sk) or sk·ct without masking is vulnerable to single-trace extraction. This is demonstrated on real hardware, not a theoretical concern.

### Countermeasures: masking and shuffling for NTT

These techniques, developed for PQC (Kyber/Dilithium), transfer directly to CKKS because the NTT structure is identical. Adams Bridge uses the **partial NTT masking** approach from [42]: it masks one INTT layer (processing the most sensitive intermediate values) and shuffles butterfly execution order in the remaining layers to decorrelate traces.

**Masking (randomized secret sharing):**
- **Fritzmann et al. (TCHES 2022)** [39]: Masked hardware NTT accelerators + RISC-V ISA extensions for Kyber/Saber. Provides the design pattern for a masked butterfly unit. Directly applicable to CKKS.
- **Heinz et al. (TCHES 2022)** [40]: First-order masked NTT for Kyber on Cortex-M4. Masks twiddle constants to defeat DPA. Hardware-implementable.
- **Bos et al. (TCHES 2021)** [41]: Foundational masked NTT — first- and higher-order implementations for Kyber.
- **Partial NTT masking** (arXiv 2604.03813, 2025) [42]: Masking only 3 consecutive mid-layers creates an unrecoverable gap for attackers at ~43% overhead vs. full masking. This is the cost/security tradeoff Adams Bridge uses.

**Arithmetic masking conversions:**
- **A2B / B2A** (Coron, Großschädl, Vadnala): Required when transitioning between arithmetic shares (NTT domain) and Boolean shares (comparison/rejection logic).

**Constant-time sampling** (critical for encrypt):
- Karmakar et al. (TCHES 2018): Knuth-Yao for discrete Gaussian [43].
- Constant-time binary-Gaussian (Information Processing Letters, 2022) [44].
- CDT and Bernoulli on FPGA [45].

**Fault detection** (defense against active attacks):
- **Fault-resistant NTT by polynomial evaluation/interpolation** (CHES 2025) [46]: Detects twiddle-zeroing attacks via algebraic redundancy.
- **Lightweight fault detection for NTT on FPGA** (arXiv 2508.03062, 2025) [47]: Low-cost redundancy check for NTT integrity.

### What Caliptra already provides: Adams Bridge masked primitives

Caliptra's `submodules/adams-bridge/src/abr_libs/rtl/` ships, under Apache 2.0, the following masked SystemVerilog modules:

**Boolean-domain primitives:**
- `abr_masked_AND.sv`, `abr_masked_OR.sv`, `abr_masked_MUX.sv`

**Arithmetic primitives (parameterized bit-width):**
- `abr_masked_full_adder.sv`, `abr_masked_N_bit_Boolean_adder.sv`, `abr_masked_N_bit_Boolean_sub.sv`
- `abr_masked_N_bit_Arith_adder.sv`
- `abr_masked_N_bit_mult.sv`, `abr_masked_N_bit_mult_two_share.sv`

**Domain conversions:**
- `abr_masked_A2B_conv.sv`, `abr_masked_B2A_conv.sv`

**Infrastructure:**
- `abr_masked_add_sub_mod_Boolean.sv`
- `abr_delay_masked_shares.sv`, `abr_sample_buffer.sv`

These compose a **first-order masked datapath**. The Adams Bridge paper (ePrint 2026/256) [48] reports masking one INTT layer + shuffling the rest, achieving measured CPA complexities of 2^46 (ML-DSA) / 2^96 (ML-KEM) and TVLA evaluation up to 1 M traces showing no first-order leakage in critical datapaths. The independent analysis "Why 'Adams Bridge' Leaks" (Saarinen et al., HardwearIO 2025) [49] challenges some of those claims — read both to calibrate expectations.

### What to build for CKKS (gap analysis)

The Adams Bridge masked library covers NTT butterfly arithmetic. Two CKKS-specific gaps remain:

1. **Masked discrete Gaussian / CBD sampler for encrypt.** The sampler must produce secret error polynomials without leaking their distribution through timing or power. Adapt `abr_sample_buffer.sv` + Keccak PRNG; apply constant-time techniques from [43][44][45].

2. **Masked secret-key inner product for decrypt.** The polynomial multiplication `sk · ct[1]` must be computed in shares. Use `abr_masked_N_bit_mult.sv` instantiated at 54-bit width across RNS lanes; combine with masked NTT per the partial-masking strategy of [42].

Both have direct analogues in the masked Kyber/Saber literature [39][40][41] — adaptation, not invention, is required.

---

## Industrial / DARPA DPRIVE

DARPA DPRIVE funded four teams (Intel, Galois/Niobium, Duality, SRI) to build datacenter FHE ASICs capable of processing encrypted data at near-plaintext speed. Phase 3 silicon remains mostly under NDA. Heracles [19] (Intel 3 nm, ISSCC 2026) is the first public chip disclosure. Adjacent commercial efforts (Cornami, Optalysys) claim extreme speedups but publish no verifiable RTL. **None of these efforts address client-side encoding, side-channel hardening, or RoT integration** — they assume ciphertexts arrive pre-formed from a trusted client.

| Team | Project | Status |
|---|---|---|
| Intel Federal | Heracles [19] | Silicon disclosed ISSCC 2026; Intel 3 nm, 200 mm², 176 W, BGV/BFV/CKKS. |
| Galois / Niobium Microsystems | Basalisc [18] | 12 nm GF tape-out, BGV-first; spun out as Niobium; closed. |
| Duality Technologies | Trebuchet [17] | Tile-based 128-bit ALU, OpenFHE integration; tape-out status undisclosed. |
| SRI International | undisclosed | DPRIVE awardee; no published silicon. |
| Cornami | TruStream / FracTLcore [51] | Reconfigurable fabric; claims 1,000,000×; closed; not strictly DPRIVE. |
| Optalysys | Photonic FHE [52] | Optical FFT for ring multiply; no silicon RTL. |
| Intel HEXL [26] | Software (AVX-512) | Open-source NTT/modmul library; informs HW pipeline design. |
| OpenFHE [27] | Software (C++) | Community reference (Duality, Samsung, Intel, MIT, UCSD). |
| Lattigo [28] | Software (Go) | Cleanest CKKS reference; multiparty support. |

---

## Gaps and opportunities for a Caliptra-resident CKKS accelerator

### Design scope: client-side only

A Caliptra-resident accelerator performs **encode → encrypt** (protecting plaintext before it leaves the RoT) and **decrypt → decode** (recovering plaintext inside the RoT). It does NOT perform bootstrapping, key-switching, or homomorphic evaluation — those happen on untrusted servers operating on already-protected ciphertext.

### Block-by-block status and reuse plan

> **Note on Aloha-HE and NTT:** Aloha-HE includes NTT/INTT units — they are integral to its encrypt/decrypt path (polynomial multiplication in R_q requires NTT). However, Aloha-HE's NTT is VHDL with a single fixed modulus and no side-channel hardening. NTTGen [34] is listed separately because it provides a parametric generator targeting arbitrary RNS primes and ring dimensions — useful for producing the wider-word, multi-prime NTT lanes a Caliptra CKKS block requires.

| Block | Published state of the art | What Caliptra needs | Reuse path |
|-------|---------------------------|---------------------|------------|
| **Datacenter bootstrapping** | Mature (F1→SHARP, REED, Heracles) | **Not needed** — requires hundreds of MB of HBM | n/a |
| **Encode (iFFT + scaling)** | Aloha-HE [22]; CKKS encoding tutorial [29] | Small radix-2 complex Cooley–Tukey, 10–14 stages for N=2^13; floating-point or wide fixed-point | Port Aloha-HE FP datapath; or fixed-point per Lee et al. [30] |
| **Encrypt (NTT + sample + add)** | Aloha-HE [22] | RNS-NTT of plaintext polynomial + sampled error; add to public-key ciphertext | Aloha-HE design, re-implemented in SV |
| **Decrypt (NTT + inner product)** | Aloha-HE [22], Lee et al. [30] | Inner product ⟨ct, sk⟩ in NTT domain; INTT; rounding | Same |
| **Decode (FFT + unscaling)** | Aloha-HE [22] | Inverse of encode | Same |
| **RNS-NTT/INTT core** | NTTGen [34], CASA [12], digit-serial 2025 [35], Adams Bridge | Parameterized 4–8 lane NTT for 50–55-bit or 32-bit primes | Adams Bridge `abr_ntt_*` topology with new prime arithmetic |
| **Discrete Gaussian / CBD sampler** | Karmakar 2018 [43], constant-time binary 2022 [44], FPGA Gaussian 2016 [45] | Constant-time CBD or rounded-Gaussian, masked | Adapt `abr_sample_buffer.sv` + Keccak |
| **Masked NTT + masked arithmetic** | Fritzmann [39], Heinz [40], Adams Bridge [48] | Mask 1 NTT layer + shuffle remaining (same recipe as Adams Bridge ML-DSA) | `abr_masked_*.sv` library directly |
| **A2B/B2A, masked AND/MUX** | Adams Bridge | Reuse as-is at wider bit-width | `abr_masked_A2B_conv.sv`, `abr_masked_B2A_conv.sv` |
| **Bus integration** | Adams Bridge AHB interface | AHB ↔ Caliptra mailbox; DMA for polynomial buffers | Extend existing Caliptra mailbox interface |
| **Leakage validation (TVLA)** | Adams Bridge measured to 1 M traces [48]; TVLA methodology [53] | Apply same fixed-vs-random test plan to CKKS datapaths | `Caliptra_TestPlan` framework already in this repo |
| **Parameter selection** | HE Standard [54], OpenFHE [27], Lattigo [28] | Generate parameter sets in software; bake fixed RNS primes into accelerator ROM | OpenFHE param-gen utility |

### Bus bandwidth consideration

CKKS polynomials are large. A single ciphertext at N=2^14 with a 4-prime RNS chain at 54-bit limbs:

> ciphertext = 2 polynomials × N coefficients × 4 RNS limbs × 7 bytes/limb
> = 2 × 16384 × 4 × 7 = 917,504 bytes ≈ **896 KB**

With 32-bit primes (4 bytes/limb): 2 × 16384 × 4 × 4 = 524,288 bytes = **512 KB**.

The existing Caliptra mailbox (64–256 KB configurable) and AHB-Lite single-beat bus (32-bit data) create a bottleneck — loading one ciphertext via MMIO takes ~230K cycles at one word/cycle. Mitigation options: (1) add a DMA channel (like the existing AXI-DMA block) to stream polynomial data directly into accelerator SRAM banks; (2) increase mailbox size to accommodate full ciphertexts; (3) operate on polynomial coefficients in-place within the accelerator's own banked SRAM (Aloha-HE's approach), moving only plaintext/ciphertext headers through the mailbox. **Option (3) is likely sufficient for client-side-only flows** where throughput demand is low (one encrypt/decrypt per attestation cycle).

### Concrete build recommendation

**Target configuration:**
- Ring dimension: N=2^13 or N=2^14
- RNS chain: 4 primes, each 54-bit (multiplicative depth ~3); 32-bit primes viable for reduced-precision applications per [33]
- Use cases: encrypted-input attestation, sealed key transport, privacy-preserving telemetry

**Architecture:**
- Pattern on Aloha-HE's datapath, re-implemented in Adams Bridge-style SystemVerilog
- 4–8 parallel RNS-NTT lanes with Barrett or Montgomery reduction (or digit-serial [35])
- Masked NTT using partial-layer strategy [42] with Adams Bridge `abr_masked_*.sv` primitives
- Constant-time CBD sampler built on `abr_sample_buffer.sv` + Keccak DRBG

**SCA validation:**
- TVLA test plan inherited from Adams Bridge; target 1 M traces with |t| < 4.5 threshold
- CPA attack campaign on NTT(sk) and sk·ct to verify masking effectiveness

**Expected footprint:** ~250–400 K gates incremental (comparable to Adams Bridge today).

**Why this matters:** This would be the **first published RoT-resident CKKS encrypt/decrypt block with measured TVLA results** — occupying a clear unfilled niche between Aloha-HE (research FPGA, no side-channel hardening) and Heracles (datacenter ASIC, no RoT integration). The combination of client-side scope, masked implementation, and formal leakage evaluation does not exist in the literature today.

---

## Bibliography

1. Feldmann, Samardzic, Krastev, Devadas, Dreslinski, Peikert, Sanchez. *F1: A Fast and Programmable Accelerator for Fully Homomorphic Encryption.* MICRO 2021. <https://arxiv.org/abs/2109.05371>
2. Samardzic, Feldmann, Krastev, Manohar, Genise, Devadas, Eldefrawy, Peikert, Sanchez. *CraterLake: A Hardware Accelerator for Efficient Unbounded Computation on Encrypted Data.* ISCA 2022. <https://people.csail.mit.edu/devadas/pubs/craterlake.pdf>
3. Kim, Kim, Kim, Jung, Rhu, Kim, Ahn. *BTS: An Accelerator for Bootstrappable Fully Homomorphic Encryption.* ISCA 2022. <https://arxiv.org/abs/2112.15479>
4. Kim, Lee, Lee, Park, Choi, Lee, Park, Ahn. *ARK: Fully Homomorphic Encryption Accelerator with Runtime Data Generation and Inter-Operation Key Reuse.* MICRO 2022. <https://arxiv.org/abs/2205.00922>
5. Kim, Kim, Choi, Park, Kim, Ahn. *SHARP: A Short-Word Hierarchical Accelerator for Robust and Practical Fully Homomorphic Encryption.* ISCA 2023. <https://dl.acm.org/doi/pdf/10.1145/3579371.3589053>
6. Riazi, Laine, Pelton, Dai. *HEAX: An Architecture for Computing on Encrypted Data.* ASPLOS 2020. <https://arxiv.org/abs/1909.09731>
7. Turan, Roy, Verbauwhede. *HEAWS: An Accelerator for Homomorphic Encryption on the Amazon AWS FPGA.* IEEE TC 2020. <https://ieeexplore.ieee.org/document/9072637/>
8. Mert, Aikata, Kwon, Shin, Yoo, Lee, Sinha Roy. *Medha: Microcoded Hardware Accelerator for Computing on Encrypted Data.* TCHES 2023. <https://eprint.iacr.org/2022/480>
9. Yang, Xia, Zhang, Zhang, Wang, Han, Wei. *Poseidon: Practical Homomorphic Encryption Accelerator.* HPCA 2023. <https://ieeexplore.ieee.org/document/10070984/>
10. Agrawal, de Castro, Yang, Juvekar, Yazicigil, Chandrakasan, Vaikuntanathan, Joshi. *FAB: An FPGA-based Accelerator for Bootstrappable Fully Homomorphic Encryption.* HPCA 2023. <https://arxiv.org/abs/2207.11872>
11. Van Beirendonck, D'Anvers, Turan, Verbauwhede. *FPT: a Fixed-Point Accelerator for Torus Fully Homomorphic Encryption.* CCS 2023. <https://eprint.iacr.org/2022/1635>. Repo: <https://github.com/KULeuven-COSIC/fpt-demo>
12. He, Oliva Madrigal, Tehrani, Azarderakhsh, Mozaffari Kermani. *CASA: A Compact and Scalable Accelerator for Approximate Homomorphic Encryption.* TCHES 2024. <https://tches.iacr.org/index.php/TCHES/article/view/11436>
13. Kim, Jung, Kim, Lee, Park, Ahn. *CiFHER: A Chiplet-Based FHE Accelerator with a Resizable Structure.* MICRO 2024. <https://arxiv.org/abs/2308.04890>
14. Aikata, Mert, Kwon, Deryabin, Sinha Roy. *REED: Chiplet-Based Scalable Hardware Accelerator for Fully Homomorphic Encryption.* TCHES 2025. <https://arxiv.org/abs/2308.02885>
15. Fan et al. *Taiyi: A High-Performance CKKS Accelerator for Practical Fully Homomorphic Encryption.* arXiv 2024. <https://arxiv.org/abs/2403.10188>
16. Deng, Fan, et al. *Trinity: A General Purpose FHE Accelerator.* MICRO 2024. <https://arxiv.org/abs/2410.13405>
17. Soni et al. *TREBUCHET: Fully Homomorphic Encryption Accelerator for Deep Computation.* arXiv 2304.05237. <https://eprint.iacr.org/2023/521>
18. Geelen, Van Beirendonck, Pereira, et al. *BASALISC: Programmable Hardware Accelerator for BGV Fully Homomorphic Encryption.* TCHES 2023 / ePrint 2022/657. <https://eprint.iacr.org/2022/657>
19. Intel. *Heracles FHE accelerator.* ISSCC 2026 / Tom's Hardware coverage. <https://www.tomshardware.com/tech-industry/cyber-security/intels-heracles-chip-computes-fully-encrypted-data-without-decrypting-it-chip-is-1-074-to-5-547-times-faster-than-a-24-core-intel-xeon-in-fhe-math-operations>
20. Agrawal, Chandrakasan, Joshi. *HEAP: A Fully Homomorphic Encryption Accelerator with Parallelized Bootstrapping.* ISCA 2024. <https://bu-icsg.github.io/publications/2024/fhe_parallelized_bootstrapping_isca_2024.pdf>
21. Agrawal, de Castro, Juvekar, Chandrakasan, Vaikuntanathan, Joshi. *MAD: Memory-Aware Design Techniques for Accelerating Fully Homomorphic Encryption.* MICRO 2023. <https://dspace.mit.edu/bitstream/handle/1721.1/153275/3613424.3614302.pdf>
22. Krieger, Hirner, Mert, Sinha Roy. *Aloha-HE: A Low-Area Hardware Accelerator for Client-Side Operations in Homomorphic Encryption.* DATE 2024. <https://eprint.iacr.org/2023/1736>. Repo: <https://github.com/flokrieger/Aloha-HE>
23. Vervaeck. *Master's thesis: NEORV32 + Aloha-HE integration for CKKS.* 2024. <https://github.com/Sam-Vervaeck/NEORV32_AlohaHE_thesis>
24. Zama. *Homomorphic Processing Unit (HPU) on FPGA.* 2025. <https://github.com/zama-ai/hpu_fpga>
25. Intel. *HEXL-FPGA.* <https://github.com/intel/hexl-fpga>
26. Boemer, Kim, Seifu, de Souza, Vaikuntanathan. *Intel HEXL: Accelerating Homomorphic Encryption with Intel AVX512-IFMA52.* WAHC 2021. <https://arxiv.org/abs/2103.16400>. Repo: <https://github.com/IntelLabs/hexl>
27. OpenFHE Project. <https://github.com/openfheorg/openfhe-development>
28. Mouchet, Bossuat, Troncoso-Pastoriza, Hubaux. *Lattigo: Multiparty Homomorphic Encryption in Go.* <https://github.com/tuneinsight/lattigo>
29. Kun. *CKKS — Polynomials, the Canonical Embedding, and Encoding.* <https://www.jeremykun.com/2026/04/29/ckks-polynomials-the-canonical-embedding-and-encoding/>
30. Lee, Duong, Lee. *Configurable Encryption and Decryption Architectures for CKKS-Based Homomorphic Encryption.* Sensors 23(17), 2023. <https://pmc.ncbi.nlm.nih.gov/articles/PMC10490559/>
31. *DNA-HHE: Dual-mode Near-network Accelerator for Hybrid Homomorphic Encryption on the Edge.* arXiv 2512.18589. <https://arxiv.org/html/2512.18589>
32. Krieger, Hirner, Mert, Sinha Roy. *Invited Paper: Enhancing Privacy-Preserving Computing with Optimized CKKS Encryption: A Hardware Acceleration Approach.* ICCAD 2024. <https://dl.acm.org/doi/10.1145/3676536.3698872>
33. Bossuat, Mouchet, Troncoso-Pastoriza, Hubaux. *High-precision RNS-CKKS on fixed but smaller word-size architectures.* ePrint 2023/1462. <https://eprint.iacr.org/2023/1462>
34. Mert, Aikata, Sinha Roy et al. *NTTGen: A Framework for Generating Low Latency NTT Implementations on FPGA.* GLSVLSI 2022. <https://par.nsf.gov/servlets/purl/10336851>
35. *High-Performance Pipelined NTT Accelerators with Homogeneous Digit-Serial Modulo Arithmetic.* arXiv 2507.12418, 2025. <https://arxiv.org/pdf/2507.12418>
36. Aydin, Karabulut, Hadayeghparast, Cammarota, Aysu. *RevEAL: Single-Trace Side-Channel Leakage of the SEAL Homomorphic Encryption Library.* DATE 2022. <https://www.semanticscholar.org/paper/RevEAL:-Single-Trace-Side-Channel-Leakage-of-the-Aydin-Karabulut/350c44347904dc96ad6fb9148526a532f464367f>
37. Aydin et al. *Leaking Secrets in Homomorphic Encryption with Side-Channel Attacks.* ePrint 2023/1128. <https://eprint.iacr.org/2023/1128.pdf>
38. *Side Channel Analysis in Homomorphic Encryption (Survey).* arXiv 2505.11058 / ePrint 2025/867, 2025. <https://eprint.iacr.org/2025/867.pdf>
39. Fritzmann, Van Beirendonck, Basu Roy, Karl, Schamberger, Verbauwhede, Sigl. *Masked Accelerators and Instruction Set Extensions for Post-Quantum Cryptography.* TCHES 2022. <https://tches.iacr.org/index.php/TCHES/article/view/9303>
40. Heinz, Kannwischer, Land, Pöppelmann, Schwabe, Sprenkels. *First-Order Masked Kyber on ARM Cortex-M4.* TCHES 2022. <https://www.semanticscholar.org/paper/First-Order-Masked-Kyber-on-ARM-Cortex-M4-Heinz-Kannwischer/06fdfbe9982338c571c177af9da178e9b86c3686>
41. Bos, Gourjon, Renes, Schneider, van Vredendaal. *Masking Kyber: First- and Higher-Order Implementations.* TCHES 2021. <https://tches.iacr.org/index.php/TCHES/article/view/9064>
42. *Partial Number Theoretic Transform Masking in Post Quantum Cryptography Hardware: A Security Margin Analysis.* arXiv 2604.03813, 2025. <https://arxiv.org/abs/2604.03813>
43. Karmakar, Roy, Vercauteren, Verbauwhede. *Constant-Time Discrete Gaussian Sampling.* TCHES 2018. <https://www.researchgate.net/publication/323711017_Constant-Time_Discrete_Gaussian_Sampling>
44. *A constant-time sampling algorithm for binary Gaussian distribution over the integers.* Information Processing Letters, 2022. <https://www.sciencedirect.com/science/article/abs/pii/S0020019022000035>
45. Du, Bai. *High Precision Discrete Gaussian Sampling on FPGAs.* 2016. <https://www.researchgate.net/publication/294281600_High_Precision_Discrete_Gaussian_Sampling_on_FPGAs>
46. *A Fault-Resistant NTT by Polynomial Evaluation and Interpolation.* Springer 2025. <https://link.springer.com/chapter/10.1007/978-3-032-01405-4_9>
47. *Lightweight Fault Detection Architecture for NTT on FPGA.* arXiv 2508.03062, 2025. <https://arxiv.org/html/2508.03062v1>
48. Aikata, Mert, Sinha Roy, et al. *Adams Bridge Accelerator: Bridging the Post-Quantum Transition.* ePrint 2026/256. <https://eprint.iacr.org/2026/256>
49. Saarinen, et al. *Why "Adams Bridge" Leaks: Attacking a PQC Root-of-Trust.* HardwearIO 2025. <https://mjos.fi/doc/20250530-hardwear-abr.pdf>
50. Niobium Microsystems product page. <https://niobiummicrosystems.com/products/fhe-solutions/>; EE Times tape-out coverage. <https://www.eetimes.com/niobuim-raises-5-5-million-tapes-out-fhe-chip/>
51. Cornami TruStream. <https://cornami.com/trustream/>
52. Optalysys photonic FHE accelerator. <https://www.future-of-computing.com/optalysys-shaping-the-future-of-photonic-accelerators-for-fully-homomorphic-encryption/>
53. Jayasena, Andrews, Bhunia. *TVLA: Test Vector Leakage Assessment on Hardware Implementations of Asymmetric Cryptography Algorithms.* IEEE TVLSI 2023. <https://www.cise.ufl.edu/research/cad/Publications/tvlsi23tvla.pdf>
54. Homomorphic Encryption Standard. <https://homomorphicencryption.org/standard/>
55. Reagen, Choi, Ko, Lee, Wei, Lee, Brooks. *Cheetah: Optimizing and Accelerating Homomorphic Encryption for Private Inference.* HPCA 2021. <https://hsienhsinlee.github.io/MARS/pub/hpca2021-cheetah.pdf>
56. Mahdavi et al. *SoK: Fully Homomorphic Encryption Accelerators.* ACM Computing Surveys, 2024. <https://arxiv.org/abs/2212.01713>
57. FxHENN. *FxHENN: FPGA-based acceleration framework for homomorphic encrypted CNN inference.* HPCA 2023. <https://ieeexplore.ieee.org/iel7/10070856/10070923/10071133.pdf>
58. ChipsAlliance Caliptra (and Adams Bridge submodule). <https://github.com/chipsalliance/Caliptra>
