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
// defaults below target N=8192, L=2, batch=1. The 32-bit geometry below
// describes legacy Stage-0 banks only; the real Aloha path has 54-bit residues.
// This version is UNMASKED (FHE_NUM_SHARES = 1).
//
//======================================================================

`ifndef FHE_PARAMS_PKG
`define FHE_PARAMS_PKG

// --- Wrapper-overridable knobs (threaded as +define+ from vsrc/Makefile) ---
`ifndef FHE_N
  `define FHE_N 8192       // validated Aloha default
`endif
`ifndef FHE_L
  `define FHE_L 2          // installed primes = largest level, 1..15
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
  parameter FHE_LOGN       = $clog2(FHE_N);      // 13 for N=8192
  parameter FHE_LOGN_MAX   = 14;                 // N <= 16384 (fhe_profiles.geometry)
  parameter FHE_L          = `FHE_L;             // RNS chain length
  parameter int FHE_L_CATALOG = 15;  // catalog primes; also the 4-bit level fields' limit
  parameter FHE_LEVEL_W    = $clog2(FHE_L) + 1;  // bits to encode a target level (1..L)
  // CROM: a 128-word FFT/RNS prefix, then one (log N + 26)-word NTT seed profile
  // per installed prime (fhe_profiles.geometry); fhe_aloha_mem_if's FHE_CROM_AW
  // is the same width.
  parameter FHE_CROM_WORDS = 128 + FHE_L * (FHE_LOGN + 26);
  parameter FHE_CROM_AW    = $clog2(FHE_CROM_WORDS);
  // Byte-address width of the CROM host window: sized for the full catalog at
  // the largest N, so the register map is the same in every build.
  parameter FHE_CROM_WIN_AW = 4 + $clog2(128 + FHE_L_CATALOG * (FHE_LOGN_MAX + 26));
  // RECOVER returns decrypted coefficients (plaintext-equivalent, no AES), so it
  // exists only in verification builds that define FHE_RECOVER_CMD.
`ifdef FHE_RECOVER_CMD
  parameter bit FHE_RECOVER_EN = 1'b1;
`else
  parameter bit FHE_RECOVER_EN = 1'b0;
`endif
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
  // Prime catalog (aloha/vendor/Scripts/fhe_profiles.py PRIMES, checked by
  // Scripts/test_constants_rom.py): limb i uses q_i = 2^(46+k_i) - qm_i*2^24 + 1,
  // i = 0..14, and the core selects it by k = k_i and modulus/constants
  // select = i. FHE_L installs the first FHE_L.
  //----------------------------------------------------------------
  // {k_i, qm_i}
  function automatic logic [20:0] fhe_kqm(input logic [3:0] i);
    case (i)
      4'd0:  fhe_kqm = {4'd0, 17'd9};   4'd1:  fhe_kqm = {4'd1, 17'd1};
      4'd2:  fhe_kqm = {4'd2, 17'd40};  4'd3:  fhe_kqm = {4'd3, 17'd5};
      4'd4:  fhe_kqm = {4'd4, 17'd28};  4'd5:  fhe_kqm = {4'd5, 17'd7};
      4'd6:  fhe_kqm = {4'd6, 17'd13};  4'd7:  fhe_kqm = {4'd7, 17'd10};
      4'd8:  fhe_kqm = {4'd7, 17'd14};  4'd9:  fhe_kqm = {4'd7, 17'd31};
      4'd10: fhe_kqm = {4'd7, 17'd34};  4'd11: fhe_kqm = {4'd7, 17'd35};
      4'd12: fhe_kqm = {4'd7, 17'd52};  4'd13: fhe_kqm = {4'd7, 17'd55};
      default: fhe_kqm = {4'd7, 17'd62};
    endcase
  endfunction
  function automatic logic [16:0] fhe_qm(input logic [3:0] i);
    logic [20:0] kqm; kqm = fhe_kqm(i); fhe_qm = kqm[16:0];
  endfunction
  // Bit width of q_i minus 46 (the core's current_k).
  function automatic logic [3:0] fhe_k(input logic [3:0] i);
    logic [20:0] kqm; kqm = fhe_kqm(i); fhe_k = kqm[20:17];
  endfunction
  // Index with a constant; a runtime index builds a shifter (use a genvar table).
  function automatic logic [63:0] fhe_q(input logic [3:0] i);
    fhe_q = (64'd1 << (46 + fhe_k(i))) - (64'(fhe_qm(i)) << 24) + 64'd1;
  endfunction
  // R mod q_i, R = 2^72: the unit of the one-limb key's ternary map, so the
  // forward NTT yields the Montgomery-form key. Elaboration-time only.
  function automatic logic [63:0] fhe_rmodq(input logic [3:0] i);
    logic [63:0] q;
    q = fhe_q(i);
    fhe_rmodq = 64'd1;
    for (int b = 0; b < 72; b++) begin
      fhe_rmodq = fhe_rmodq << 1;
      if (fhe_rmodq >= q) fhe_rmodq = fhe_rmodq - q;
    end
  endfunction
  // Evaluation-key gadget for row j, G_j = P mod q_j, with the key-switching
  // prime P = q_{FHE_L-1} (docs/fhe/21). Plain, not Montgomery: it multiplies
  // the Montgomery-form key limb. Elaboration-time only.
  function automatic logic [63:0] fhe_gadget(input logic [3:0] j);
    fhe_gadget = fhe_q(4'(FHE_L - 1)) % fhe_q(j);
  endfunction

  // Core control word flags, above the [LOGN:0] bank address (N <= 16384).
  // Mirrored as literals in aloha/vendor/Aloha-HE_Common/ComputeCoreWrapper.v.
  localparam int FHE_CW_WEA = 17, FHE_CW_INS = 18, FHE_CW_GRANT = 19;

  //----------------------------------------------------------------
  // Command opcodes (mirror mldsa_cmd_e convention)
  //----------------------------------------------------------------
  typedef enum logic [2:0] {
    FHE_NONE    = 3'b000,
    FHE_ENCRYPT = 3'b001, // svc1: encode + encrypt (fresh L-limb ct -> DRAM)
    FHE_KEYGEN  = 3'b010, // svc2: keygen (sk->KeyVault, emit pk + evk)
    FHE_EVKGEN  = 3'b011, // one evaluation-key row (Galois or relinearization)
    FHE_DECRYPT = 3'b100, // decoded slots, limb zero
    FHE_REFRESH = 3'b110, // single-limb centered level refresh
    FHE_RECOVER = 3'b101 // coefficient residues, all selected limbs; no FFT
  } fhe_cmd_e;

  // Completion error causes (STATUS.ERR_CAUSE).
  typedef enum logic [3:0] {
    FHE_EC_NONE       = 4'd0,
    FHE_EC_NO_KEY     = 4'd1,
    FHE_EC_BAD_L      = 4'd2,
    FHE_EC_BAD_OPCODE = 4'd3,
    FHE_EC_NO_SEED    = 4'd4,
    FHE_EC_KV_READ    = 4'd5,
    FHE_EC_DMA_BUSY   = 4'd6,
    FHE_EC_BAD_LOGN   = 4'd7,
    FHE_EC_BAD_WORD   = 4'd8,
    FHE_EC_BAD_ADDR   = 4'd9,
    FHE_EC_TRANSPORT  = 4'd10,
    FHE_EC_ABORTED    = 4'd11,
    FHE_EC_BAD_GALOIS = 4'd12,
    FHE_EC_BAD_ROW    = 4'd13
  } fhe_err_e;

  //----------------------------------------------------------------
  // Segment routes (docs/fhe/16 "Commands, slots and inputs"). Each slot of a
  // command moves either nothing, its q0 limb, CONFIG.L limbs, or, for an
  // evaluation-key row, L + 1 limbs (the Q limbs and P). Slots that
  // cross the AES boundary (ENCRYPT message in, DECRYPT slots out) go through
  // AES-GCM; every other slot bypasses AES.
  //----------------------------------------------------------------
  // Limbs a command moves through `slot` (0: the slot is unused).
  function automatic logic [3:0] fhe_slot_limbs(fhe_cmd_e cmd, logic [2:0] slot, logic [3:0] l);
    unique case (cmd)
      FHE_ENCRYPT: return (slot == 3'd0) ? 4'd1 : (slot >= 3'd2 && slot <= 3'd3) ? l : 4'd0;
      FHE_DECRYPT: return (slot <= 3'd2) ? 4'd1 : 4'd0;
      FHE_RECOVER: return (slot <= 3'd2) ? l : 4'd0;
      FHE_REFRESH: return (slot <= 3'd1) ? 4'd1 : (slot <= 3'd3) ? l : 4'd0;
      FHE_EVKGEN:  return (slot >= 3'd2 && slot <= 3'd3) ? l + 4'd1 : 4'd0;
      default:     return 4'd0;
    endcase
  endfunction
  function automatic logic fhe_slot_used(fhe_cmd_e cmd, logic [2:0] slot);
    return fhe_slot_limbs(cmd, slot, 4'd1) != 4'd0;
  endfunction
  function automatic logic fhe_slot_aes(fhe_cmd_e cmd, logic [2:0] slot);
    return (cmd == FHE_ENCRYPT && slot == 3'd0) || (cmd == FHE_DECRYPT && slot == 3'd2);
  endfunction
  // The slot carries binary64 message words (checked finite) rather than
  // residues (checked < q).
  function automatic logic fhe_slot_msg(fhe_cmd_e cmd, logic [2:0] slot);
    return cmd == FHE_ENCRYPT && slot == 3'd0;
  endfunction
  // The command's input is unauthenticated until firmware checks its GCM tag:
  // the walker holds before its first EXE pass until CTRL.INPUT_COMMIT.
  function automatic logic fhe_cmd_commits(fhe_cmd_e cmd);
    return cmd == FHE_ENCRYPT;
  endfunction

  // XFER_STATUS layout (fhe_reg.rdl): {LIMB[11:8], SLOT[6:4], DIR[1], ACTIVE[0]}.
  function automatic logic [31:0] fhe_xfer_status(logic active, logic dir, logic [2:0] slot,
                                                  logic [3:0] limb);
    return {20'b0, limb, 1'b0, slot, 2'b0, dir, active};
  endfunction

  parameter [63:0] FHE_CORE_NAME    = 64'h00000000_53_4B_4B_43; // "CKKS"
  parameter [63:0] FHE_CORE_VERSION = 64'h00000000_3030312e;    // "1.00"

endpackage

`endif
//======================================================================
// EOF fhe_params_pkg.sv
//======================================================================
