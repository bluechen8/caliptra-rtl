`timescale 1ns / 1ps
`include "CommonDefinitions.vh"

// C'-2: the sampler PRNG is the audited OpenTitan/Caliptra Trivium
// (`caliptra_prim_trivium`), replacing the vendored `trivium64_update`.  Both are
// the SAME eSTREAM Trivium cipher (taps 66/93/162/177/243/288); the Caliptra
// primitive is the in-tree, verified implementation AES/SHA3 already use.
// "One PRNG, not two" -- the whole design standardises on caliptra_prim_trivium.
//
// The Caliptra primitive uses a different internal state representation and
// key/IV seed mapping, so its keystream differs bit-for-bit from trivium64_update;
// the sampling goldens are regenerated from a SW model of THIS primitive
// (tvgen/trivium.py CaliptraPrimTrivium + gen_sampling.py).
//
// -------------------------------------------------------------------------
// C'-2 STEP 2 (free-run): the Trivium is now FREE-RUNNING and reseeded on an
// explicit `reseed` pulse -- decoupled from the per-pass sampling-FSM reset.
// This lets one instance serve both:
//   * keygen's deterministic ternary `s`  -> reseed with the KV/keygen seed
//     right before the keygen sampling pass (same KV root => same sk), and
//   * per-ciphertext fresh `a`/`e0`        -> NO reseed between encrypt passes,
//     so the keystream continues and a/e0 never repeat by construction
//     (Trivium period ~2^64+ blocks).
// Usage model (driven by the caller / walker): each keygen does
//   reseed(KV seed) -> sample s -> reseed(CSRNG-sourced entropy) -> free-run,
// so a/e0 are independent of the long-term KV secret and non-repeating even if
// keygen re-runs.  See the C'-2 progress notes.
//
// Ports:
//   rst    - active-high power-on/global reset (NOT pulsed per sampling pass).
//            Holds the primitive in its default state; random_valid stays low
//            until the first reseed completes.
//   reseed - pulse (>=1 cycle; internally edge-detected to 1 cycle) to load
//            `seed` as the Trivium key (iv=0) and run the automatic 1152-bit
//            (18 x 64) KeyIv warmup; random_valid drops during warmup and rises
//            when warmup completes.
//   seed   - 64-bit reseed value (sampled at the reseed pulse).
// Between reseeds the Trivium free-runs one 64-bit word per cycle; random_valid
// stays high, so the keystream is continuous across sampling passes.
module TriviumAdapter(
    input        clk,
    input        rst,
    input        reseed,
    input [63:0] seed,
    output [63:0] random_out,
    output        random_valid
  );

  logic rst_n;
  assign rst_n = ~rst;

  // Edge-detect `reseed` -> a clean 1-cycle load pulse.  A 1-cycle pulse is
  // REQUIRED: for SeedTypeKeyIv the primitive ties last_state_part=0, so
  // seed_req latches high; holding seed_ack (=reseed) high would re-load the
  // state every cycle and the init-updates would never complete (seed_done
  // never fires).  Edge detection makes a level-held `reseed` safe too.
  logic reseed_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) reseed_q <= 1'b0;
    else        reseed_q <= reseed;
  end
  logic reseed_pulse;
  assign reseed_pulse = reseed & ~reseed_q;

  // Key/IV seed: 64-bit Aloha seed -> Trivium key (low 64 of 80), iv = 0.
  logic [79:0] seed_key;
  logic [79:0] seed_iv;
  assign seed_key = {16'd0, seed};
  assign seed_iv  = 80'd0;

  logic        seed_done;
  logic [63:0] key_stream;

  // random_valid: low until the first reseed's warmup completes; drops again
  // while a subsequent reseed re-warms; otherwise held high (free-run).
  logic valid_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)            valid_q <= 1'b0;
    else if (reseed_pulse) valid_q <= 1'b0;   // re-warming: invalidate
    else if (seed_done)    valid_q <= 1'b1;    // warmup complete
  end

  caliptra_prim_trivium #(
    .BiviumVariant (1'b0),
    .OutputWidth   (64),
    .SeedType      (caliptra_prim_trivium_pkg::SeedTypeKeyIv)
  ) u_trivium (
    .clk_i                (clk),
    .rst_ni               (rst_n),
    // Advance while the keystream is valid. valid_q PERSISTS across sampling
    // passes (only a `reseed` or prng_rst drops it), so between non-reseeded
    // passes the stream keeps advancing -> a/e0 continue and never repeat.
    // After a reseed, valid_q drops during re-warm so the consumer waits and
    // resumes at word0 (deterministic keygen s). NOT a constant 1: that would
    // advance during the post-warm idle gap and race the keystream past word0.
    .en_i                 (valid_q),
    .allow_lockup_i       (1'b0),
    .seed_en_i            (reseed_pulse),
    .seed_done_o          (seed_done),
    .seed_req_o           (),              // (KeyIv holds this high after seed_en; unused)
    .seed_ack_i           (reseed_pulse),  // one-cycle ack coincident with the request
    .seed_key_i           (seed_key),
    .seed_iv_i            (seed_iv),
    .seed_state_full_i    ('0),
    .seed_state_partial_i ('0),
    .key_o                (key_stream),
    .err_o                ()
  );

  assign random_out   = key_stream;
  assign random_valid = valid_q;

endmodule
