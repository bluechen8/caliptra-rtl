# C'-2 Step 2 — free-run PRNG (designed + validated in isolation; NOT integrated)

These files are the **free-run** evolution of the sampler PRNG, staged here so the
main tree stays at the green **Step 1** state (audited `caliptra_prim_trivium` as a
per-pass-reload drop-in). Step 2 needs the **walker** orchestration layer to be
correct (see "Integration gotcha" below), so it is deferred to a dedicated push.

## Goal
One `caliptra_prim_trivium` serves both:
- **keygen's deterministic ternary `s`** — reseed with the KV/keygen seed right
  before the keygen sampling pass (same KV root => same `sk`).
- **per-ciphertext fresh `a`/`e0`** — NO reseed between encrypt passes; the
  keystream continues so `a`/`e0` never repeat by construction.

Per-keygen flow (user-confirmed 2026-07-06): `reseed(KV) -> sample s ->
reseed(CSRNG-sourced entropy) -> free-run`. keygen is a once-per-boot/session
setup (sk_ntt stays resident), so the "drop a/e0 stream + reseed from CSRNG" cost
is rare, and `a`/`e0` are independent of the long-term KV secret + non-repeating
even if keygen re-runs.

## What's proven
`TriviumAdapter_freerun.sv` (free-run + `reseed` pulse, `prng_rst` power-on,
`en_i = valid_q & active`) was validated in isolation by
`tb_trivium_adapter_freerun.sv`:
- reseed(A) -> `random_valid`@cyc19, 12 CONTINUOUS free-run words == SW model
  (stream never restarts without a reseed => a/e0 non-repeating),
- reseed(B) -> valid drops then re-rises, keystream restarts deterministically
  at model(B) word0 (deterministic keygen s).
(That isolation run used `en_i=1`; see the gotcha — the integrated version must
use `en_i = valid_q & active`.)

## Integration gotcha (the reason Step 2 needs the walker)
`RandomSampling`'s per-pass `rst` resets the sampling FSM every pass, but the
Trivium must PERSIST state across passes (free-run) and reload only on `reseed`.
Two cycle-accurate hazards:
1. **Idle drift** — if `en_i` is a constant 1, the keystream advances during the
   post-warm idle gap before the FSM starts consuming, so a reseeded pass no
   longer lines up at word0. FIX: `en_i = valid_q & active`, where
   `active = ~fsm_rst` — the Trivium FREEZES between passes (state kept, not
   advancing) and advances only while a pass is actively consuming.
2. **Stale-valid race** — because `valid` persists across passes, a reseed pulsed
   *at* pass-start (rst 1->0) lets the FSM consume 1 stale word before `valid`
   drops. FIX: the reseed must land **during the inter-pass hold (rst=1)**, so the
   Trivium re-warms and freezes at word0 BEFORE the FSM is released.

Hazard 2 means the reseed cannot be a ComputeCore per-pass default; it must be
sequenced by the **walker** (`fhe_microseq`), which knows keygen-vs-encrypt:
- keygen: hold sampler in rst -> reseed(KV) -> wait warm -> release (sample s) ->
  reseed(CSRNG) during the next hold.
- encrypt: never reseed; the frozen-between/advancing-during-pass Trivium yields
  continuing, non-repeating a/e0.

## Files
- `TriviumAdapter_freerun.sv` — free-run adapter (ports: clk, rst=prng_rst,
  reseed, seed; + `active` gate to add: `en_i = valid_q & active`).
- `RandomSampling_freerun.sv` — adds `prng_rst`+`reseed` inputs, frees the Trivium
  from the per-pass `rst`. (Needs the `active`/`en` gate wired: `.active(~rst)`.)
- `ComputeCore_freerun.diff` — the per-pass reseed-pulse generator (a stopgap;
  replace with walker-driven reseed).
- `tb_trivium_adapter_freerun.sv` — isolation TB (free-run continuity + reseed).

## Remaining Step-2 work
1. Add `active` gate to the adapter (`en_i = valid_q & active`) + `.active(~rst)`
   in RandomSampling.
2. Walker reseed orchestration (keygen KV-reseed during hold + CSRNG-reseed).
3. `fhe_top`: ENTSEED registers + `RNG_SEEDED` status; walker seed-source mux
   (KV / CSRNG-entropy-register).
4. Firmware writes the CSRNG-sourced seed (Caliptra pattern: firmware-written
   `ENTROPY_IF_SEED`-style regs, NOT CSRNG HW app ports).
5. Verification: adapter free-run TB; a/e0 non-repeat across passes; round-trip
   recovery; keygen determinism cross-check; SoC/VCS smokes.
