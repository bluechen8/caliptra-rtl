// SPDX-License-Identifier: Apache-2.0
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
//======================================================================
//
// fhe_params_pkg.sv
// -----------------
// Common params and defines for the CKKS FHE client-side accelerator.
//
// Modeled on abr_params_pkg.sv. Knobs N (ring dimension), L (RNS chain
// length), and BATCH (concurrent ciphertexts) are overridable from the
// Chipyard wrapper Makefile via +define+ (FHE_N / FHE_L / FHE_BATCH);
// defaults below target N=2^14, L=4, batch=1. Word length is fixed 32 b.
// This version is UNMASKED (FHE_NUM_SHARES = 1).
//
//======================================================================

`ifndef FHE_PARAMS_PKG
`define FHE_PARAMS_PKG

// --- Wrapper-overridable knobs (threaded as +define+ from vsrc/Makefile) ---
`ifndef FHE_N
  `define FHE_N 16384      // ring dimension, power of two in 2^13..2^16
`endif
`ifndef FHE_L
  `define FHE_L 4          // RNS chain length = number of 32-bit primes / max level
`endif
`ifndef FHE_BATCH
  `define FHE_BATCH 1      // ciphertexts resident / processed at a time
`endif

package fhe_params_pkg;

  //----------------------------------------------------------------
  // Core geometry
  //----------------------------------------------------------------
  parameter FHE_WORD       = 32;                 // fixed RNS limb width
  parameter FHE_N          = `FHE_N;             // ring dimension
  parameter FHE_LOGN       = $clog2(FHE_N);      // 14 for N=2^14
  parameter FHE_L          = `FHE_L;             // RNS chain length
  parameter FHE_LEVEL_W    = $clog2(FHE_L) + 1;  // bits to encode a target level (1..L)
  parameter FHE_BATCH      = `FHE_BATCH;         // concurrent ciphertexts
  parameter FHE_BATCH_W    = (FHE_BATCH == 1) ? 1 : $clog2(FHE_BATCH);

  // Lanes / parallelism
  parameter COEFF_PER_CLK  = 4;                  // butterflies per cycle per NTT lane
  parameter FHE_NUM_NTT    = 1;                  // spatial NTT lane groups (1..L) -- area<->throughput knob
  parameter FHE_NUM_SHARES = 1;                  // UNMASKED in this version

  // Fixed-point encode scale: plaintext is scaled by Delta = 2^FHE_LOG_DELTA
  parameter FHE_LOG_DELTA  = 25;

  //----------------------------------------------------------------
  // Memory interface geometry
  //   bank word  = COEFF_PER_CLK coefficients, one 32-bit limb each
  //   poly words = N / COEFF_PER_CLK per limb
  //   full ct    = BATCH * L * poly_words words
  //----------------------------------------------------------------
  parameter FHE_MEM_DATA_WIDTH = COEFF_PER_CLK * FHE_WORD;          // 128
  parameter FHE_POLY_WORDS     = FHE_N / COEFF_PER_CLK;             // 4096 @ N=2^14
  parameter FHE_CT_WORDS       = FHE_BATCH * FHE_L * FHE_POLY_WORDS;

  // Per-bank depths (in COEFF_PER_CLK-wide words). In-place (Aloha-HE style)
  // operation bounds resident polynomials; see plan Work area 5.
  parameter FHE_MEM_C0_DEPTH      = FHE_CT_WORDS;                   // ciphertext c0, all limbs
  parameter FHE_MEM_C1_DEPTH      = FHE_CT_WORDS;                   // ciphertext c1, all limbs
  parameter FHE_MEM_SCRATCH_DEPTH = 2 * FHE_L * FHE_POLY_WORDS;     // NTT in-place / a / accum
  parameter FHE_MEM_KEY_DEPTH     = 2 * FHE_L * FHE_POLY_WORDS;     // pk/evk/galois staging
  parameter FHE_MEM_ENCODE_DEPTH  = FHE_POLY_WORDS;                 // fixed-point (i)FFT scratch
  parameter FHE_MEM_SK_DEPTH      = FHE_L * FHE_POLY_WORDS;         // NTT-domain sk during decrypt

  parameter FHE_MEM_C0_ADDR_W      = $clog2(FHE_MEM_C0_DEPTH);
  parameter FHE_MEM_C1_ADDR_W      = $clog2(FHE_MEM_C1_DEPTH);
  parameter FHE_MEM_SCRATCH_ADDR_W = $clog2(FHE_MEM_SCRATCH_DEPTH);
  parameter FHE_MEM_KEY_ADDR_W     = $clog2(FHE_MEM_KEY_DEPTH);
  parameter FHE_MEM_ENCODE_ADDR_W  = $clog2(FHE_MEM_ENCODE_DEPTH);
  parameter FHE_MEM_SK_ADDR_W      = $clog2(FHE_MEM_SK_DEPTH);

  //----------------------------------------------------------------
  // RNS prime set (per-prime constants).
  //   Each prime p_i is a 32-bit NTT-friendly prime, p_i = 1 (mod 2N).
  //   NOTE: the values below are placeholders for the Stage-0 integration
  //   stub (no actual modular arithmetic runs yet). Stage A pins a verified
  //   software-generated table (primes + Barrett mu + N^-1) for the chosen N.
  //----------------------------------------------------------------
  parameter [FHE_L-1:0][FHE_WORD-1:0] FHE_PRIMES = '{default: 32'h0}; // TODO(Stage A): real primes

  //----------------------------------------------------------------
  // Command opcodes (mirror mldsa_cmd_e convention)
  //----------------------------------------------------------------
  typedef enum logic [2:0] {
    FHE_NONE    = 3'b000,
    FHE_ENCRYPT = 3'b001, // svc1: encode + encrypt (fresh L-limb ct -> DRAM)
    FHE_KEYGEN  = 3'b010, // svc2: keygen (sk->KeyVault, emit pk + evk)
    FHE_REENC   = 3'b011, // svc3: decrypt + decode + re-encrypt to TARGET_LEVEL
    FHE_DECRYPT = 3'b100  // standalone decrypt (test hook)
  } fhe_cmd_e;

  parameter [63:0] FHE_CORE_NAME    = 64'h00000000_53_4B_4B_43; // "CKKS"
  parameter [63:0] FHE_CORE_VERSION = 64'h00000000_3030312e;    // "1.00"

endpackage

`endif
//======================================================================
// EOF fhe_params_pkg.sv
//======================================================================
