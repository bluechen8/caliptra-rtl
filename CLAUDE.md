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
- [ ] Test ROM build with `NO_MLDSA=1` and verify it compiles cleanly
- [ ] Measure ROM binary size with/without MLDSA to determine IMEM savings

## Part 2: Flexible SRAM Sizes

### Current Defaults

| Memory | Size | Config Location |
|--------|------|-----------------|
| ICCM | 256 KB | `src/riscv_core/veer_el2/rtl/el2_param.vh` — `ICCM_SIZE: 14'h0100` |
| DCCM | 256 KB | `src/riscv_core/veer_el2/rtl/el2_param.vh` — `DCCM_SIZE: 14'h0100` |
| ROM (IMEM) | 96 KB | `src/integration/rtl/config_defines.svh` — `CALIPTRA_IMEM_BYTE_SIZE: 98304` |
| Mailbox | 256 KB (16 KB in SS mode) | `src/soc_ifc/rtl/soc_ifc_pkg.sv` — `CPTRA_MBOX_SIZE_KB` |

### TODO (RTL - caliptra-rtl)
- [ ] Determine minimum viable sizes for each SRAM (depends on SW image sizes)
- [ ] Parameterize or use defines to make sizes easily changeable
- [ ] Reduce ICCM size (target TBD)
- [ ] Reduce DCCM size (target TBD)
- [ ] Reduce ROM/IMEM size (target TBD, must fit ROM binary)
- [ ] Reduce Mailbox size (16 KB SS mode value may be a starting point)
- [ ] Verify address map consistency after resizing

### TODO (SW - caliptra-sw) — deferred until RTL sizes are decided
- [ ] Adjust linker scripts if memory map changes
- [ ] Verify firmware builds and runs with reduced SRAMs

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
