# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Goal

Explore adding a **FHE (CKKS) encoding/decoding + encryption/decryption accelerator** to Caliptra, modeled after the existing **Adams Bridge (ABR)** PQC accelerator that lives in `submodules/adams-bridge/`. Adams Bridge implements ML-DSA / ML-KEM and is the cleanest in-tree example of a complex crypto accelerator integrated into the Caliptra core as an AHB-Lite responder with KeyVault hooks and a SystemRDL register file. The new FHE block should follow the same integration pattern.

Branch for this work: `fhe-ckks-accelerator-exploration` (forked off `area-optimized`).

## Build / Test Commands

This repo is consumed by `caliptra-wrapper` (chipyard generator) above it; the wrapper's `Makefile` drives Verilator builds. The native Caliptra build flow uses `tools/scripts/Makefile`:

```bash
# environment
export CALIPTRA_ROOT=$PWD                         # repo root (this directory)
export CALIPTRA_WORKSPACE=$(dirname $PWD)         # parent
export CALIPTRA_PRIM_ROOT=$CALIPTRA_ROOT/src/caliptra_prim_generic
export CALIPTRA_PRIM_MODULE_PREFIX=caliptra_prim_generic

# Build & run a test in Verilator (default TESTNAME=iccm_lock)
make -C <run_dir> -f $CALIPTRA_ROOT/tools/scripts/Makefile TESTNAME=smoke_test_mldsa verilator

# VCS
make -C <run_dir> -f $CALIPTRA_ROOT/tools/scripts/Makefile TESTNAME=smoke_test_mldsa vcs

# Full L0 regression
python3 $CALIPTRA_ROOT/tools/scripts/run_verilator_l0_regression.py
```

Useful `make` overrides (defined in `tools/scripts/Makefile`):
- `CALIPTRA_INTERNAL_TRNG=1` — must match between firmware compile and HW compile.
- `CALIPTRA_MODE_SUBSYSTEM=1` — switches register set to `src/integration/rtl/caliptra_reg_ss/`.
- `debug=1` — produce VCD waveform.

Firmware-only compile (produces `program.hex`, `iccm.hex`, `dccm.hex`, `mailbox.hex`):
```bash
make -f $CALIPTRA_ROOT/tools/scripts/Makefile TESTNAME=smoke_test_mldsa program.hex
```
Tests live under `src/integration/test_suites/<TESTNAME>/`. The MLDSA/ABR-touching ones (`smoke_test_mldsa*`, `randomized_mldsa_invalid_verify`, `smoke_test_kv_mldsa`) are the templates to copy when writing CKKS firmware tests.

### Register (RDL) regeneration

Whenever you change a `*_reg.rdl`, regenerate the SV register block + UVM model + HTML docs:
```bash
bash tools/scripts/reg_gen.sh        # regenerates every block listed in the script
python3 tools/scripts/reg_gen.py <path/to/your_reg.rdl>   # one block
bash tools/scripts/reg_doc_gen.sh    # rebuilds top-level address map / HTML
```
A new accelerator with its own RDL must be added to `reg_gen.sh`. Required tooling versions are pinned in `README.md` under "RDL Compiler" (peakrdl-regblock 0.21.0, etc.).

## High-Level Architecture

### Top-level integration

`src/integration/rtl/caliptra_top.sv` is the SoC top. Every IP block is instantiated here as an AHB-Lite responder hanging off `responder_inst[`CALIPTRA_SLAVE_SEL_*]`. The AHB fabric (`src/ahb_lite_bus/`) is parameterized by:
- `CALIPTRA_AHB_SLAVES_NUM` — total responder count (defined in `src/integration/rtl/config_defines.svh`).
- A flat slave name / base-address / mask-address array (`CALIPTRA_SLAVE_NAMES`, `CALIPTRA_SLAVE_BASE_ADDR`, `CALIPTRA_SLAVE_MASK_ADDR`). The order in those arrays must match the `CALIPTRA_SLAVE_SEL_*` index defines. **Add a new slave by extending all three arrays and the `CALIPTRA_AHB_SLAVES_NUM` count.**
- A per-slave address-width macro `CALIPTRA_SLAVE_ADDR_WIDTH(n)` is derived automatically from base/mask.

VeeR-EL2 (RISC-V CPU running ROM/FMC/Runtime) is the only AHB requester. Interrupts route into VeeR via the `intr[VEER_INTR_VEC_*-1]` vector; vector indices are defined in `config_defines.svh`. The existing ABR block uses `VEER_INTR_VEC_ABR_ERROR` (23) and `VEER_INTR_VEC_ABR_NOTIF` (24). **A new FHE block needs two new vectors** appended after `VEER_INTR_VEC_AXI_DMA_NOTIF`, and `VEER_INTR_VEC_MAX_ASSIGNED` updated.

### Adams Bridge — the template to follow

Adams Bridge lives in `submodules/adams-bridge/` as a git submodule (`.gitmodules` → `https://github.com/chipsalliance/adams-bridge`). Key files for a new FHE block to mirror:

| Adams Bridge file | Purpose | FHE analogue to create |
|---|---|---|
| `submodules/adams-bridge/src/abr_top/rtl/abr_top.sv` | Top wrapper: AHB slave interface, KeyVault r/w ports, status/interrupts | `fhe_top.sv` |
| `…/abr_top/rtl/abr_ctrl.sv` | Command FSM (`MLDSA_CMD_KEYGEN`/`SIGNING`/`VERIFYING`, etc.) | `fhe_ctrl.sv` (CKKS encode/decode/enc/dec) |
| `…/abr_top/rtl/abr_reg.rdl` | SystemRDL register map (CMD/STATUS/seed/msg/key/sig regs + interrupt block) | `fhe_reg.rdl` |
| `…/abr_top/rtl/abr_params_pkg.sv` | Modulus, polynomial dimensions, sample widths (ML-DSA: Q=8380417, N=256) | `fhe_params_pkg.sv` (CKKS Q, ring dim N, slot count, scaling factor) |
| `…/abr_top/rtl/abr_mem_if.sv` + `abr_mem_top.sv` | Memory interface bundle + instantiated SRAMs (banks for polynomials/keys) | `fhe_mem_if.sv` + `fhe_mem_top.sv` |
| `…/ntt_top/` | Number-Theoretic Transform datapath (butterflies, modular mult) | CKKS uses NTT/INTT over the same kind of ring — heavy reuse opportunity |
| `…/abr_libs/rtl/abr_ahb_slv_sif.sv` | Stock AHB-Lite slave interface | Reuse as-is or copy |
| `submodules/adams-bridge/src/abr_top/config/compile.yml` | Playbook fileset declaration | `fhe_top/config/compile.yml` |

Adams Bridge instantiation in the SoC top is at `src/integration/rtl/caliptra_top.sv:1101-1145`. Around line 1102 you'll see the full port wiring: AHB responder slice, KeyVault read/write indices (`kv_read[7:6]+kv_read[2]`, `kv_write[1]`), `pcr_signing_data`, busy/intr outputs, and the `abr_memory_export` SRAM interface. The area-optimized config wraps the whole instance in `\`ifndef CALIPTRA_NO_ADAMS_BRIDGE` with tie-offs in the `\`else` branch — **mirror this pattern** so the FHE block can be compiled out by integrators who don't need it.

### Memory & KeyVault interfaces

- Accelerator SRAMs are *not* instantiated inside the IP — they're declared in a `<block>_mem_top.sv` module that is hoisted up to `CaliptraCoreBlackbox.sv` (in `caliptra-wrapper/src/main/resources/`) for chipyard so the wrapper can swap in real SRAMs. Inside the IP, the `<block>_mem_if` modport exposes per-bank `we/waddr/wdata/re/raddr/rdata` lines. See `abr_mem_top.sv` for the `\`ABR_MEM` macro pattern (mixes plain and byte-enabled banks).
- **KeyVault** (`src/keyvault/`) is a shared per-IP r/w mailbox used to move secrets without exposing them on the AHB bus. Each consumer is assigned fixed `kv_read[i]` slots and `kv_write[KV_WRITE_IDX_<IP>]` slots in `caliptra_top.sv`. A new FHE block that consumes/produces key material should claim new indices.
- **PCR signing** (`pcr_signing_data` into ABR): a side-channel for signing PCR digests. Likely not needed for CKKS unless attesting ciphertexts.

### Filelists & build descriptor (Playbook `compile.yml`)

Two parallel filelist mechanisms must both stay in sync:

1. **`.vf` files** under `src/integration/config/` — flat absolute-path filelists consumed by Verilator/VCS via `caliptra_top_tb.vf`. Adams Bridge sources are explicitly enumerated at `src/integration/config/caliptra_top.vf` (and `caliptra_top_ss_mode.vf`) starting around line 23 (incdir) and line 288 (source files), ~93 entries. **Adding an FHE block means appending equivalent `+incdir+` and source-file lines** to both `caliptra_top.vf` and `caliptra_top_ss_mode.vf`.
2. **Playbook `compile.yml`** under each `<block>/config/` and the top-level `src/integration/config/compile.yml`. The top one lists block-level dependencies by `provides:` name (e.g. `abr_top`). The block-level `compile.yml` in `submodules/adams-bridge/src/abr_top/config/compile.yml` is the canonical example — it provides `abr_defines`, `abr_uvm_pkg`, `abr_top`, `abr_top_tb`, `abr_coverage`, declares `requires:` (other Caliptra blocks), and pins SV-LRM options. **A new FHE block needs its own `compile.yml` and an `fhe_top` entry added to `src/integration/config/compile.yml` requires lists for both `caliptra_top` and `caliptra_top_ss_mode`.**

### Firmware-side drivers

Per-IP C drivers live under `src/integration/test_suites/libs/<ip>/` and are linked into tests by their `Makefile`. The MLDSA driver pair (`libs/mldsa/mldsa.{c,h}`) is the model: it defines command opcodes (`MLDSA_CMD_KEYGEN=0x1`, etc.), sizes (`MLDSA87_PRIVKEY_SIZE`), and high-level functions (`mldsa_keygen_flow`, `mldsa_signing_flow`) that poke the RDL-generated `CALIPTRA_MLDSA_REG_*` macros from `caliptra_reg.h`. **Create `libs/fhe_ckks/fhe_ckks.{c,h}` with CKKS-shaped commands** (`FHE_CMD_ENCODE`, `FHE_CMD_DECODE`, `FHE_CMD_ENCRYPT`, `FHE_CMD_DECRYPT`, possibly `FHE_CMD_KEYGEN`/`RELIN_KEYGEN`).

### Test suites

Tests live under `src/integration/test_suites/<name>/` (162 currently). Each has at minimum a `.c`, an `.ld` linker fragment, an ISR header, and a `<name>.yml` (sets seed/testname). The Playbook regression runner picks tests up automatically. Copy `smoke_test_mldsa/` as a starting template for CKKS smoke tests.

## Coordinates of the broader project

This `caliptra-rtl` checkout is a submodule under `caliptra-wrapper` (chipyard generator). The wrapper is responsible for:
- exposing `CaliptraParams` to Scala configs (e.g. `noAdamsBridge`, `mboxSizeKB`, `iccmSizeKB`),
- threading `+define+CALIPTRA_NO_ADAMS_BRIDGE` / size overrides into the Verilator make,
- instantiating SRAMs that this RTL exports out of `abr_mem_top` / mailbox / VeeR.

When adding a new FHE block follow the same convention: gate it with `\`ifndef CALIPTRA_NO_FHE` (or symmetric `\`ifdef CALIPTRA_FHE`) so the wrapper can compile it out, and lift any SRAM instantiation into a `fhe_mem_top` that the wrapper can either keep here or hoist into `CaliptraCoreBlackbox.sv`.

## What to read first when starting work

1. `src/integration/rtl/caliptra_top.sv` lines 1101–1145 — the exact ABR instantiation + tie-off pattern.
2. `src/integration/rtl/config_defines.svh` — slave-select macros, AHB address map arrays, interrupt-vector defines, IMEM sizing. Every new accelerator touches this file.
3. `submodules/adams-bridge/src/abr_top/rtl/abr_top.sv` — the IP top module's port list and module-level pkg imports.
4. `submodules/adams-bridge/src/abr_top/rtl/abr_reg.rdl` — what a Caliptra-style register block looks like (CMD/STATUS, KEYGEN/SIGN/VERIFY, KV interface fields, interrupt regblock import).
5. `submodules/adams-bridge/src/abr_top/config/compile.yml` and `src/integration/config/caliptra_top.vf` — what "register a new IP with the build" actually means.
6. `src/integration/test_suites/libs/mldsa/mldsa.h` and `src/integration/test_suites/smoke_test_mldsa/smoke_test_mldsa.c` — driver & test-suite shape.

## Existing area-optimization work (still in flight)

The branch this was forked from (`area-optimized`) carries an ABR-removal and SRAM-resizing effort. Relevant artifacts still present:
- `\`ifndef CALIPTRA_NO_ADAMS_BRIDGE` guards around `abr_top` instantiation and KeyVault tie-offs in `caliptra_top.sv`.
- Overrideable `CALIPTRA_IMEM_BYTE_SIZE` (`config_defines.svh:97`) and `CPTRA_MBOX_SIZE_KB` (`src/soc_ifc/rtl/soc_ifc_pkg.sv`) via `\`ifdef`/`\`ifndef`.
- ICCM/DCCM sizing is driven from the wrapper's `Cores-VeeR-EL2` config-tool snapshot, not from this repo.

When adding the FHE block, follow these same conventions (compile-out guard + integrator-overridable sizes) — and remember the wrapper's `CaliptraParams` / `CaliptraCoreBlackbox` / Makefile chain must be extended in parallel.
