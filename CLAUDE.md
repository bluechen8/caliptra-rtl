# Caliptra Area Optimization Project

## Goal
Reduce Caliptra core area for tapeout by:
1. Making Adams Bridge (ABR) removable via a config flag
2. Making SRAM sizes (ROM, ICCM, DCCM, Mailbox) configurable/reducible

## Repositories & Branches

| Repo | Fork | Branch | Base Commit | Path |
|------|------|--------|-------------|------|
| caliptra-rtl | bluechen8/caliptra-rtl | `area-optimized` | `611728d0` | `/scratch/boru/chipyard/generators/caliptra-wrapper/src/main/resources/caliptra/vsrc/caliptra` |
| caliptra-sw | bluechen8/caliptra-sw | `area-optimized` | `8efce033` | `/scratch/boru/caliptra_workspace/caliptra-sw` |
| caliptra-wrapper | bluechen8/caliptra-wrapper | — | — | `/scratch/boru/chipyard/generators/caliptra-wrapper` |

- caliptra-wrapper `.gitmodules` updated to point caliptra-rtl submodule to `bluechen8/caliptra-rtl` branch `area-optimized`

## Part 1: Adams Bridge Removal

### Current State
- `abr_top` is **unconditionally instantiated** in `src/integration/rtl/caliptra_top.sv` (~line 1099-1127)
- No existing feature flag or `#ifdef` to disable it
- ABR interrupt vectors: `VEER_INTR_VEC_ABR_ERROR` (#23), `VEER_INTR_VEC_ABR_NOTIF` (#24)
- ABR files listed in `src/integration/config/compile.yml`, `caliptra_top.vf`, `caliptra_top_ss_mode.vf`

### Chipyard/Wrapper Integration (DONE)
- [x] `CaliptraParams.noAdamsBridge` field added (`CaliptraTile.scala`)
- [x] `CaliptraCoreBlackbox` accepts `noAdamsBridge` param, passes `CALIPTRA_NO_ADAMS_BRIDGE=1` to make
- [x] `WithCaliptra(noAdamsBridge = true)` config fragment exposed for chipyard configs
- [x] `Makefile` adds `+define+CALIPTRA_NO_ADAMS_BRIDGE` to verilator when flag is set

### RTL Changes (DONE)
- [x] Wrap `abr_top` instantiation in `caliptra_top.sv` with `ifndef CALIPTRA_NO_ADAMS_BRIDGE`
- [x] Tie-off `abr_busy`, `abr_error_intr`, `abr_notif_intr` to 0 when disabled
- [x] Tie-off AHB responder (MLDSA slave): `hreadyout=1`, `hresp=0`, `hrdata=0`
- [x] Wrap `abr_mem_top` in `CaliptraCoreBlackbox.sv` with `ifndef CALIPTRA_NO_ADAMS_BRIDGE`
- [ ] Update AHB address map / decoder if needed (may not be required — bus won't hang)

### SW Changes (DONE)
- [x] `no-mldsa` feature flag propagated through `caliptra-rom` -> `caliptra-kat`, `caliptra_common`
- [x] Build with `make NO_MLDSA=1` (sets `--features no-mldsa`, forces `PQC_KEY_TYPE=3` LMS only)
- [x] KAT: gated `mldsa87_kat` module and execute_kat call
- [x] Common: gated `mldsa87` in verifier and debug_unlock
- [x] ROM: gated MLDSA imports, struct fields, constructors, cert signing, key derivation across all cold_reset flows
- [x] Standard ROM build with `NO_MLDSA=1` tested — compiles and boots successfully
- [ ] (deferred) Measure ROM binary size with/without MLDSA to determine IMEM savings

### Testing Status
- [x] ABR disable tested end-to-end with **fake ROM** — boots successfully
- [x] Full test with standard ROM (no-MLDSA) — boots successfully

## Part 2: Flexible SRAM Sizes

### Current Defaults & How to Change

| Memory | Default | How to Resize | Config Location |
|--------|---------|---------------|-----------------|
| ROM (IMEM) | 96 KB | Change `CALIPTRA_IMEM_BYTE_SIZE` define (auto-sizes via `$clog2`) | `src/integration/rtl/config_defines.svh:97` |
| Mailbox | 256 KB | Change `CPTRA_MBOX_SIZE_KB` param (auto-sizes via `$clog2`) | `src/soc_ifc/rtl/soc_ifc_pkg.sv:39-51` |
| ICCM | 256 KB | Set `iccmSizeKB` in `WithCaliptra()` — auto-generates VeeR config | `CaliptraTile.scala` / `vsrc/Makefile` |
| DCCM | 256 KB | Set `dccmSizeKB` in `WithCaliptra()` — auto-generates VeeR config | `CaliptraTile.scala` / `vsrc/Makefile` |

**VeeR config integration:** `Cores-VeeR-EL2` is a submodule of caliptra-wrapper (commit `8d9457af`, branch `2.0-patches`). When non-default ICCM/DCCM sizes are used, the Makefile auto-runs `veer.config` to generate a snapshot at `vsrc/snapshots/caliptra_iccm<N>_dccm<M>/`, caches it, and generates a modified `.vf` that overrides VeeR param files. Default sizes (256/256) use the stock caliptra-rtl files with no generation step.

### Boot Flow & Memory Usage

**Boot:** ROM (in IMEM) → loads FMC+Runtime from **mailbox** into ICCM → launches FMC → FMC hands off to Runtime.
- **ROM uses DCCM** for stack (62 KB) + exception stacks (2 KB) + persistent data (at fixed offsets from 0x50000400)
- **Mailbox must be ≥ firmware bundle** (manifest 1KB + FMC image + Runtime image)
- **Output:** `cprintln!` writes to SOC_IFC generic output wires (no real UART)

### SW Image Sizes (Current Full Firmware)

| Component | Text | Rodata | Total | Runs In |
|-----------|------|--------|-------|---------|
| ROM | 76.7 KB | 10.0 KB | ~87 KB | IMEM (0x00000000) |
| FMC | 24.8 KB | 8.6 KB | ~33.5 KB | ICCM (0x40000000) |
| Runtime | 138.8 KB | 7.2 KB | ~146 KB | ICCM (0x40009000) |

**DCCM layout:** Persistent data starts at 0x50000400 (~110 KB: manifests 34K + datavault 15K + FHT 2K + MLDSA keys/certs 20K + cert buffers + DPE state etc.) + FMC/RT data (93 KB region) + stack (14 KB FMC/RT, 40 KB ROM) + exception stacks (2 KB)

### Design Points

#### A) Full Firmware (with no-mldsa, current binaries)
| Memory | Current | Target | Rationale |
|--------|---------|--------|-----------|
| ROM | 96 KB | 64 KB | ~15-30K MLDSA savings (needs measurement) |
| ICCM | 256 KB | 192 KB | FMC 33.5K + RT 146K = 182K, fits in 192K |
| DCCM | 256 KB | 192 KB | ~169K used, fits in 192K |
| Mailbox | 256 KB | 192 KB | Bundle ~180K (manifest + FMC + RT) |
| **Total savings** | | | **~224 KB SRAM** |

#### B) Minimal Demo (FMC prints → jumps to RT → RT prints)
Custom tiny FMC & RT that just print a banner and hand off:
- **Minimal FMC:** init + print + jump to RT → ~2-4 KB code
- **Minimal RT:** init + print + halt → ~2-4 KB code
- **Mailbox:** manifest (1K) + tiny FMC + tiny RT → **16 KB sufficient**
- **DCCM:** ROM still uses DCCM for stack + persistent data. Persistent data at fixed offsets spans ~100 KB. ROM stack needs up to 62 KB. → **128 KB minimum** (needs validation: do all persistent data fields get written, or only a subset in fake-ROM flow?)
- **ICCM:** only holds tiny FMC + RT → **32 KB sufficient**
- **ROM:** unchanged, use fake ROM (small) → **96 KB** (or could reduce if fake ROM binary is smaller)

| Memory | Current | Minimal Demo | Savings |
|--------|---------|--------------|---------|
| ROM | 96 KB | 96 KB (keep) | 0 KB |
| ICCM | 256 KB | 32 KB | 224 KB |
| DCCM | 256 KB | 256 KB (keep, PersistentData ~110K + stack 40K) | 0 KB |
| Mailbox | 256 KB | 16 KB | 240 KB |
| **Total savings** | | | **464 KB SRAM** |

**Resolved:** DCCM cannot be reduced — `PersistentData` struct is ~110K (manifests 34K, cert buffers 24K, DPE 5K, auth manifest metadata 10K, CSR envelopes 18K, etc.) and ROM stack needs ~40K for DICE chain crypto. Reducing PersistentData would require gating MLDSA-related fields (~20K) with `no-mldsa` feature, which is a significant code change.

### Plan

#### Step 1: Build minimal demo FMC & RT (SW) — DONE
- [x] `minimal-demo` feature added to test-fmc (`Cargo.toml`, `main.rs`): prints banner, reads `data_vault.rt_entry_point()`, jumps via `transfer_control` assembly
- [x] test-rt already minimal (prints banner, exits)
- [x] `MINIMAL_DEMO=1` Makefile flag wired to `build-test-fmc` features
- [x] Verified: `make run DEVICE_LIFECYCLE=manufacturing NO_MLDSA=1 MINIMAL_DEMO=1` — FMC prints → jumps to RT → RT prints Caliptra RT banner → success
- [x] Binary sizes: test-fmc .text=472 bytes, test-rt .text=1140 bytes (both tiny, ~1.6 KB combined code)
- [ ] Trace fake-ROM boot to determine which DCCM persistent data offsets are actually written

#### Step 2: RTL — Mailbox & ROM size reduction — DONE
- [x] Override `CPTRA_MBOX_SIZE_KB` in `soc_ifc_pkg.sv` via `ifdef CALIPTRA_MBOX_SIZE_KB` compile define
- [x] Override `CALIPTRA_IMEM_BYTE_SIZE` in `config_defines.svh` via `ifndef` guard (overrideable via `+define+`)
- [x] Wire size params through chipyard wrapper: `CaliptraParams.mboxSizeKB/imemSizeKB` → `CaliptraCoreBlackbox` → Makefile → verilator `+define+`
- [x] Fixed hardcoded `98304` in `CaliptraCoreBlackbox.scala` and `CaliptraTile.scala` (imem_waddr width now derived from `imemSizeKB`)
- [x] Updated `CaliptraRocketMinimalDemoConfig` with `mboxSizeKB=32`
- [x] Verified: preprocessed RTL shows `CPTRA_MBOX_SIZE_KB = 32`

#### Step 3: RTL — ICCM & DCCM reduction via VeeR config tool — DONE
- [x] Added `Cores-VeeR-EL2` as submodule in caliptra-wrapper (`vsrc/Cores-VeeR-EL2`, pinned to commit `8d9457af`)
- [x] Integrated VeeR config generation into `vsrc/Makefile`:
  - `CALIPTRA_ICCM_SIZE_KB` / `CALIPTRA_DCCM_SIZE_KB` params (default 256)
  - `veer-config` target auto-generates VeeR snapshot at `vsrc/snapshots/caliptra_iccm<N>_dccm<M>/`
  - Snapshots cached — only regenerated if not present
  - Generated `.vf` in snapshot dir overrides `el2_param.vh`, `el2_pdef.vh`, `common_defines.sv`
  - Post-processing: renames `common_defines.vh` → `.sv`, comments out `RV_TOP` define (conflicts with caliptra's `config_defines.svh`)
- [x] Wired through chipyard: `CaliptraParams.iccmSizeKB/dccmSizeKB` → `CaliptraCoreBlackbox` → make args
- [x] Added `CaliptraRocketMinimalDemoConfig` (noAdamsBridge=true, iccm=32KB, dccm=256KB, mbox=32KB)
- [x] Verified: elaboration succeeds, preprocessed RTL has `ICCM_SIZE=14'h0020` (32KB), `DCCM_SIZE=14'h0080` (128KB)

#### Step 4: SW linker script adjustments — DONE
- [x] Update `memory_layout.rs` with new ICCM/DCCM sizes (ICCM=32K, STACK=40K, ROM_STACK=40K)
- [x] Update linker scripts (rom.ld, fmc.ld, rt.ld) memory regions and stack positions
- [x] Update `common/src/lib.rs` FMC_SIZE=8K, RUNTIME_SIZE=24K
- **Key finding:** DCCM must stay at 256K — `PersistentData` is ~110K, leaving only ~14K for stack at 128K DCCM. ROM DICE chain needs ~40K+ stack. Stack overflow at 128K DCCM corrupts `dot_owner_pk_hash` in PersistentData, causing `IMAGE_VERIFIER_ERR_DOT_OWNER_PUB_KEY_DIGEST_MISMATCH` (0x000B005E).
- Used `gen_memory_layout.py`: `--iccm-kb 32 --dccm-kb 256 --fmc-kb 8 --rt-kb 24 --total-stack-kb 40 --rom-stack-kb 40 --fmc-rt-stack-kb 14 --lib-fmc-kb 8 --lib-rt-kb 24`

#### Step 5: End-to-end verification — DONE
- [x] Build with all size reductions + ABR disabled
- [x] Test with fake ROM boot
- [x] Verify FMC prints → RT prints → success

## Key Config Files Reference
- `src/integration/rtl/caliptra_top.sv` — top-level integration (ABR instantiation)
- `src/integration/rtl/config_defines.svh` — IMEM size, AHB params, interrupt vectors
- `src/riscv_core/veer_el2/rtl/el2_param.vh` — ICCM/DCCM sizes, VeeR core params
- `src/soc_ifc/rtl/soc_ifc_pkg.sv` — Mailbox size
- `src/integration/config/compile.yml` — compilation targets and defines

## Progress Log
- 2026-03-08: Forked caliptra-rtl and caliptra-sw to bluechen8, created `area-optimized` branches, updated caliptra-wrapper submodule pointer
- 2026-03-08: Added `CALIPTRA_NO_ADAMS_BRIDGE` plumbing: Makefile define, CaliptraCoreBlackbox param, CaliptraParams field, WithCaliptra config fragment
- 2026-03-08: RTL ifdef guards added: `caliptra_top.sv` (abr_top + tie-offs), `CaliptraCoreBlackbox.sv` (abr_mem_top)
- 2026-03-08: SW `no-mldsa` feature flag implemented across caliptra-sw (kat, common, rom/dev) — ABR SW removal complete
- 2026-03-08: ABR disable tested end-to-end with fake ROM — boots successfully. Standard ROM test deferred.
- 2026-03-08: Part 2 planning: analyzed SRAM sizes, SW image sizes, VeeR config tool flow. Two design points: full firmware (224 KB savings) vs minimal demo (592 KB savings). Next: build minimal demo FMC/RT, then resize SRAMs.
- 2026-03-08: Minimal demo FMC/RT working — `minimal-demo` feature in test-fmc jumps to RT via `transfer_control`. Tested with `make run DEVICE_LIFECYCLE=manufacturing NO_MLDSA=1 MINIMAL_DEMO=1`. Next: resize SRAMs in RTL.
- 2026-03-08: ICCM/DCCM VeeR config integrated into caliptra-wrapper Makefile. Cores-VeeR-EL2 added as submodule (commit `8d9457af`). Snapshot-based caching with auto-generated `.vf`. Fixed `RV_TOP` redefine conflict. `CaliptraRocketMinimalDemoConfig` elaborates successfully with ICCM=32KB, DCCM=128KB.
- 2026-03-09: SW linker scripts adjusted for ICCM=32K (FMC 8K + RT 24K). Discovered DCCM must stay at 256K: PersistentData ~110K + ROM stack 40K exceeds 128K. Stack overflow at 128K DCCM corrupts PersistentData.dot_owner_pk_hash → fatal error 0x000B005E. Updated memory_layout.rs, rom.ld, fmc.ld, rt.ld, common/src/lib.rs via gen_memory_layout.py.
- 2026-03-09: Mailbox & ROM size reduction (Step 2) complete. Made `CPTRA_MBOX_SIZE_KB` overrideable via `ifdef` in `soc_ifc_pkg.sv`, `CALIPTRA_IMEM_BYTE_SIZE` via `ifndef` in `config_defines.svh`. Wired `mboxSizeKB`/`imemSizeKB` through CaliptraParams → CaliptraCoreBlackbox → Makefile → verilator +define+. Fixed hardcoded 98304 in Scala. MinimalDemoConfig now: noABR, ICCM=32K, DCCM=256K, mbox=32K. Elaboration verified.
- 2026-03-09: End-to-end verification (Step 5) passed. MinimalDemoConfig with all size reductions + ABR disabled boots successfully: FMC prints → RT prints → success.
