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
// Description:
//   Stage-B' FHE microsequencer (the "walker").
//
//   Turns one high-level command (KEYGEN / ENCRYPT / DECRYPT / RECOVER / REFRESH) into the
//   sequence of Aloha-HE ComputeCore engine passes that implements it. Data
//   moves over the ComputeCoreWrapper debug-IO pins (control_low_word /
//   control_high_word / dina_ext / status / dout_ext) as send64 / receive64;
//   each EXE op is one pass: its 40-bit command, built from a template, is held
//   on core_cmd until the pass is done, and ComputeCore decodes it directly, so
//   the wrapper's ISA_control, INS_RAM and the core's command register are not
//   used. core_cmd is 0 between passes, which holds every unit in reset; the
//   core reset itself is held only while the walker is idle.
//
//   Macro-op word + ROM layout: see microsequencer doc section 5.1/5.2.
//
module fhe_microseq
  import fhe_params_pkg::*;
#(
  parameter bit SRAM_REUSE = 0, // legacy standalone trace/core driver keeps copies
  parameter int LOGN = 13,
  parameter int N    = 1 << LOGN
)(
  input  logic        clk,
  input  logic        step, // logical engine edge; bus-facing pulses remain one base cycle
  input  logic        rst_b,
  input  logic        zeroize,

`ifdef FHE_WALKER
  // One-cycle synchronous single-port resident key SRAM, exported to Chisel.
  output logic sk_en,
  output logic sk_we,
  output logic [$clog2(N*FHE_L)-1:0] sk_addr,
  output logic [53:0] sk_wdata,
  input logic [53:0] sk_rdata,
`endif

  // command issue (1-cycle pulse)
  input  logic        cmd_valid,
  output logic [3:0] active_limb,
  input  fhe_cmd_e    cmd,

  // Per-command instruction scale field (CONFIG.SCALE), written by firmware.
  // KEYGEN/ENCRYPT patch it into the RNS pass (unsigned); DECRYPT patches its
  // low bits into the I2F pass as a signed value.
  input  logic [11:0] scale,
  input  logic [3:0]  num_limbs,      // output/active limbs; slot decrypt forced to 1

  // per-limb R^2 mod q_i constant for keygen Montgomery-convert (CONST R2MODQ)
  input  logic [63:0] r2modq [0:FHE_L-1],

  // ----- ComputeCoreWrapper debug-IO master (the pins we drive) -----
  output logic [31:0] control_low_word,
  output logic [31:0] control_high_word,
  output logic [31:0] dina_low,
  output logic [31:0] dina_high,
  input  logic [31:0] dout_low,
  input  logic [31:0] dout_high,
  input  logic [31:0] status,         // [0] = the loaded pass is done
  // ComputeCore's command (ComputeCoreWrapper EXT_COMMAND=1): EXE presents it
  // for the whole pass; 0 between passes, so its rise is the start.
  output logic [39:0] core_cmd,

  // ----- external poly data (TB/DMA stub in 2a) -----
  output logic [2:0]  ext_sel,        // PTR index of the active DMA stream
  output logic [LOGN:0] ext_idx,      // word index within the poly
  input  logic [63:0] ext_din,        // DMA_IN word (comb. on {ext_sel,ext_idx})
  output logic        ext_dout_we,    // DMA_OUT word strobe
  output logic [63:0] ext_dout,       // DMA_OUT word

  // ----- B' 2c-step-2: DMA engine handshake (latency-tolerant streaming) -----
  // Additive over the 2a/2b ext_* word stream. A descriptor pulse starts a poly
  // transfer; the word stream then flows with valid/ready backpressure. Drive
  // dma_ready/dma_rd_valid/dma_wr_ready all 1 (and ignore the descriptor) to get
  // the legacy zero-latency behaviour the 2a/2b array-model TBs rely on.
  output logic        dma_desc_valid, // 1-cycle pulse at a DMA op start
  output logic        dma_desc_wr,    // 1 = DMA_OUT (write), 0 = DMA_IN (read)
  output logic [2:0]  dma_desc_ptr,   // PTR-register select for the transfer
  output logic [3:0]  dma_desc_limb,  // limb index (DRAM stride)
  input  logic        dma_ready,      // DMA idle: may start a transfer / it has completed
  input  logic        dma_rd_valid,   // a DMA_IN word is available on ext_din
  output logic        dma_rd_pop,     // walker consumed a DMA_IN word this cycle
  input  logic        dma_wr_ready,   // DMA_OUT FIFO can accept a word

  // Hold before the next EXE pass (fhe_top's ENCRYPT input-commit barrier);
  // exe_held = the walker is parked on that EXE.
  input  logic        exe_hold,
  output logic        exe_held,

  // Sampler reseed gate (via fhe_top -> ComputeCoreWrapper): 1 only for the
  // KEYGEN key-sampling pass; every other pass continues the same stream.
  output logic        reseed_en,

  output logic        busy,
  output logic        done,           // 1-cycle pulse
  output logic        error
);

  // Single-seed sampling: KEYGEN's PS_KG pass loads the Trivium from the
  // KeyVault seed (fhe_top sideband); s, then every a and e0, come from that one
  // continuous stream. fhe_top refuses sampling commands until a KEYGEN.

  // =====================================================================
  // Macro-op encoding (FROZEN -- doc section 5.1)
  // =====================================================================
  localparam logic [3:0] OP_NOP=4'd0, OP_DMA_IN=4'd1, OP_DMA_OUT=4'd2,
                         OP_CONST=4'd3, OP_EXE=4'd5,
                         OP_MOVE=4'd6, OP_LIMB=4'd7, OP_DONE=4'd8;

  // BANK ids (mirror Aloha bram_sel; SK=8 is new in B'/C')
  localparam logic [3:0] B_FFT=4'd0, B_NTTMSG=4'd1, B_NTTV=4'd3,
                         B_ERR=4'd4, B_NTTKEY=4'd5, B_FFTEXP=4'd6,
                         B_FFTIM=4'd7, B_SK=4'd8;

  // PARAMSEL (EXE seed source)
  localparam logic [1:0] PS_ZERO=2'd0, PS_KG=2'd1, PS_A=2'd2, PS_ERR=2'd3;
  // SCALESEL (command scale-field patch source). Both RNS codes now patch from the
  // one CONFIG.SCALE field; the two values are kept so the ROM encoding is stable.
  localparam logic [1:0] SC_NONE=2'd0, SC_RNSKG=2'd1, SC_RNSENC=2'd2, SC_I2F=2'd3;
  // write-data source for a send64 word (the cur_cid selector)
  localparam logic [1:0] C_ZEROS=2'd0, C_R2=2'd1, C_DIN=2'd3;  // C_DIN = DMA_IN (ext_din)

  // command-template indices
  localparam int unsigned T_FFTDIF=0, T_FFTDIT=1, T_RNS=2, T_NTTFWD=3,
                          T_NTTINV=4, T_PWMENC=5, T_PWMDEC=6, T_I2F=7, T_PROJ=8,
                          T_SAMPLE=9, T_SNAPSHOT=10, T_LIFT=11, T_PWMKG=12;

  // =====================================================================
  // Command templates: ComputeCore's 40-bit command, pre-patch. doc section 5.2.
  //   The per-limb (neg_qm,modsel,k)+scale patch is applied at EXE decode.
  // =====================================================================

  // base template words (opcode + fixed flags only)
  function automatic logic [39:0] tmpl_base(input int unsigned t);
    case (t)
      T_FFTDIF: tmpl_base = (40'd1<<4) | (40'd1<<3) | 40'd1; // FFT is_dif=1
      T_FFTDIT: tmpl_base = (40'd1<<4) |              40'd1; // FFT is_dif=0
      T_RNS   : tmpl_base = 40'd2;                          // RNS
      T_NTTFWD: tmpl_base =              40'd1;             // NTT is_dif=0
      T_NTTINV: tmpl_base = (40'd1<<3) | 40'd1;            // NTT is_dif=1
      T_PWMENC: tmpl_base = (40'd1<<4) | (40'd1<<3) | 40'd4;// PWM enc=1,neg=1
      // PWM enc=0,neg=0; T_PWMKG adds OP1[6]: b = scalar on dina, zero addend
      T_PWMDEC, T_PWMKG: tmpl_base = (t==T_PWMKG ? 40'd1<<9 : 40'd0) | 40'd4;
      T_I2F   : tmpl_base = 40'd3;                          // I2F
      T_PROJ  : tmpl_base = 40'd5;                          // PROJECT
      T_SAMPLE: tmpl_base = 40'd6;
      T_SNAPSHOT: tmpl_base = (40'd1<<3) | 40'd7;
      T_LIFT: tmpl_base = 40'd7;
      default : tmpl_base = '0;
    endcase
  endfunction
  // which fields the template needs patched
  function automatic logic tmpl_use_q  (input int unsigned t);
    tmpl_use_q  = (t==T_RNS)||(t==T_NTTFWD)||(t==T_NTTINV)||(t==T_PWMENC)||(t==T_PWMDEC)||(t==T_I2F)||(t==T_LIFT)||(t==T_PWMKG);
  endfunction
  function automatic logic tmpl_use_rom(input int unsigned t);
    tmpl_use_rom = (t==T_RNS)||(t==T_NTTFWD)||(t==T_NTTINV);
  endfunction

  // =====================================================================
  // Limb i's prime fields {qm, k, modsel}: catalog prime i (fhe_params_pkg),
  // with k = modsel = i.
  // =====================================================================
  // neg_qm = (-qm) & 0x1ffff  (17-bit), matches TB neg_qm()
  function automatic logic [16:0] neg_qm(input logic [16:0] qm); neg_qm = (~qm + 17'd1); endfunction

  // =====================================================================
  // Macro-op word constructors (so the program ROM reads clearly)
  // =====================================================================
  function automatic logic [31:0] mk(input logic [3:0] op,  input logic [27:0] payload);
    mk = {op, payload};
  endfunction

  // payload field helpers
  // DMA_IN/OUT : bank[27:24] ptr[23:21] strided[20] len[19:18] off[17]
  function automatic logic [27:0] pl_dma(input logic [3:0] bank, input logic [2:0] ptr, input logic strided, input logic [1:0] len, input logic off);
    pl_dma = {bank, ptr, strided, len, off, 17'd0};   // 4+3+1+2+1+17 = 28 (fields top-aligned)
  endfunction
  // CONST : bank[27:24] constid[23:22]
  function automatic logic [27:0] pl_const(input logic [3:0] bank, input logic [1:0] cid);
    pl_const = {bank, cid, 22'd0};
  endfunction
  // EXE : one engine pass. template[27:20] reserved[19:16]=0 patch[15] scalesel[14:13]
  //       paramsel[12:11] r2[10] (dina = R^2 mod q of the active limb during the pass)
  function automatic logic [27:0] pl_exe(input logic [7:0] tmpl, input logic patch, input logic [1:0] sc,
                                         input logic [1:0] ps, input logic r2 = 1'b0);
    pl_exe = {tmpl, 4'd0, patch, sc, ps, r2, 10'd0};
  endfunction
  // MOVE : srcbank[27:24] dstbank[23:20] srcstr[19] dststr[18]
  function automatic logic [27:0] pl_move(input logic [3:0] sb, input logic [3:0] db, input logic ss, input logic ds);
    pl_move = {sb, db, ss, ds, 18'd0};
  endfunction
  // LIMB : bodylen[27:20]
  function automatic logic [27:0] pl_limb(input logic [7:0] bl); pl_limb = {bl, 20'd0}; endfunction
  // DONE : irq[27]
  function automatic logic [27:0] pl_done(input logic irq); pl_done = {irq, 27'd0}; endfunction

  // field extractors
  function automatic logic [3:0]  f_op  (input logic [31:0] w); f_op   = w[31:28]; endfunction
  function automatic logic [3:0]  f_bank(input logic [31:0] w); f_bank = w[27:24]; endfunction
  function automatic logic [2:0]  f_ptr (input logic [31:0] w); f_ptr  = w[23:21]; endfunction
  // f_str/f_len (DMA strided/len) reserved in the encoding but not decoded in B'.
  function automatic logic        f_off (input logic [31:0] w); f_off  = w[17];    endfunction
  function automatic logic [1:0]  f_cid (input logic [31:0] w); f_cid  = w[23:22]; endfunction
  function automatic logic [7:0]  f_tmpl(input logic [31:0] w); f_tmpl = w[27:20]; endfunction
  function automatic logic        f_pat (input logic [31:0] w); f_pat  = w[15];    endfunction
  function automatic logic [1:0]  f_sc  (input logic [31:0] w); f_sc   = w[14:13]; endfunction
  function automatic logic [1:0]  f_ps  (input logic [31:0] w); f_ps   = w[12:11]; endfunction
  function automatic logic        f_r2  (input logic [31:0] w); f_r2   = w[10];    endfunction
  function automatic logic [3:0]  f_sb  (input logic [31:0] w); f_sb   = w[27:24]; endfunction
  function automatic logic [3:0]  f_db  (input logic [31:0] w); f_db   = w[23:20]; endfunction
  function automatic logic        f_ss  (input logic [31:0] w); f_ss   = w[19];    endfunction
  function automatic logic        f_ds  (input logic [31:0] w); f_ds   = w[18];    endfunction
  function automatic logic [7:0]  f_bl  (input logic [31:0] w); f_bl   = w[27:20]; endfunction
  function automatic logic        f_irq (input logic [31:0] w); f_irq  = w[27];    endfunction

  // =====================================================================
  // Program ROM. Existing command entries are stable; recovery starts at 48.
  // =====================================================================
  localparam int PROG_N = 96;
  localparam int KG_ENTRY  = 0;
  localparam int ENC_ENTRY = 16;
  localparam int DEC_ENTRY = 32;
  localparam int REC_ENTRY = 48;
  localparam int REF_ENTRY = 64;

  // KEYGEN with shared storage (entry 0): a sample-only pass draws the secret
  // from the KeyVault seed; per limb, RNS reduces it mod q (ComputeCore feeds
  // its float input zeros during KEYGEN), NTT transforms it, and PWM multiplies
  // by R^2 from dina with a zero addend, writing the resident Montgomery key.
  function automatic logic [31:0] kg_reuse_rom(input logic [7:0] a);
    kg_reuse_rom = mk(OP_NOP, 28'd0);
    case (a)
      KG_ENTRY+0:   kg_reuse_rom = mk(OP_EXE, pl_exe(T_SAMPLE[7:0], 1'b0, SC_NONE, PS_KG));
      KG_ENTRY+1:   kg_reuse_rom = mk(OP_LIMB, pl_limb(8'd3));         // body = next 3 words
      KG_ENTRY+2:   kg_reuse_rom = mk(OP_EXE, pl_exe(T_RNS[7:0], 1'b1, SC_RNSKG, PS_ZERO));
      KG_ENTRY+3:   kg_reuse_rom = mk(OP_EXE, pl_exe(T_NTTFWD[7:0], 1'b1, SC_NONE, PS_ZERO));
      KG_ENTRY+4:   kg_reuse_rom = mk(OP_EXE, pl_exe(T_PWMKG[7:0], 1'b1, SC_NONE, PS_ZERO, 1'b1)); // dina = R^2 mod q_limb
      KG_ENTRY+5:   kg_reuse_rom = mk(OP_DONE,  pl_done(1'b0));
      default: ;
    endcase
  endfunction

  // Combinational ROM: synthesizes as constant decode logic (an `initial`-filled
  // array would be dropped by synthesis). Unlisted addresses decode to NOP.
  function automatic logic [31:0] prog_rom(input logic [7:0] a);
    prog_rom = mk(OP_NOP, 28'd0);
    if (SRAM_REUSE && a < 8'(ENC_ENTRY)) prog_rom = kg_reuse_rom(a);
    else case (a)
      // ---------- KEYGEN, separate-copy trace builds (entry 0) ----------
      // The sampler only runs inside a transform pass here (sample-only needs
      // shared storage), so this sequence keeps the FFT over zeroed FFT_EXP and
      // the CONST fills; its pin trace is what tb_fhe_microseq checks.
      KG_ENTRY+0:   prog_rom = mk(OP_CONST, pl_const(B_FFTEXP, C_ZEROS));
      KG_ENTRY+1:   prog_rom = mk(OP_EXE, pl_exe(T_FFTDIF[7:0], 1'b0, SC_NONE, PS_KG));
      KG_ENTRY+2:   prog_rom = mk(OP_LIMB, pl_limb(8'd6));        // body = next 6 words
      KG_ENTRY+3:   prog_rom = mk(OP_EXE, pl_exe(T_RNS[7:0], 1'b1, SC_RNSKG, PS_ZERO));
      KG_ENTRY+4:   prog_rom = mk(OP_EXE, pl_exe(T_NTTFWD[7:0], 1'b1, SC_NONE, PS_ZERO));
      KG_ENTRY+5:   prog_rom = mk(OP_CONST, pl_const(B_NTTKEY, C_R2));
      KG_ENTRY+6:   prog_rom = mk(OP_CONST, pl_const(B_NTTMSG, C_ZEROS));
      KG_ENTRY+7:   prog_rom = mk(OP_EXE, pl_exe(T_PWMDEC[7:0], 1'b1, SC_NONE, PS_ZERO));
      KG_ENTRY+8:   prog_rom = mk(OP_MOVE,  pl_move(B_NTTMSG, B_SK, 1'b0, 1'b1));
      KG_ENTRY+9:   prog_rom = mk(OP_DONE,  pl_done(1'b0));

      // ---------- ENCRYPT (entry 16) ----------
      ENC_ENTRY+0:  prog_rom = mk(OP_DMA_IN, pl_dma(B_FFTEXP, 3'd0, 1'b0, 2'd0, 1'b0)); // PTR0=msg
      ENC_ENTRY+1:  prog_rom = mk(OP_EXE, pl_exe(T_FFTDIF[7:0], 1'b0, SC_NONE, PS_ERR));
      ENC_ENTRY+2:  prog_rom = mk(OP_LIMB, pl_limb(8'd6));
      ENC_ENTRY+3:  prog_rom = mk(OP_EXE, pl_exe(T_RNS[7:0], 1'b1, SC_RNSENC, PS_ZERO));
      ENC_ENTRY+4:  prog_rom = mk(OP_EXE, pl_exe(T_NTTFWD[7:0], 1'b1, SC_NONE, PS_A));
      ENC_ENTRY+5:  prog_rom = SRAM_REUSE ? mk(OP_NOP, 28'd0) : mk(OP_MOVE,   pl_move(B_SK, B_NTTV, 1'b1, 1'b0));
      ENC_ENTRY+6:  prog_rom = mk(OP_EXE, pl_exe(T_PWMENC[7:0], 1'b1, SC_NONE, PS_ZERO));
      ENC_ENTRY+7:  prog_rom = mk(OP_DMA_OUT,pl_dma(B_NTTMSG, 3'd2, 1'b1, 2'd0, 1'b0)); // c0->PTR2
      ENC_ENTRY+8:  prog_rom = mk(OP_DMA_OUT,pl_dma(B_NTTKEY, 3'd3, 1'b1, 2'd0, 1'b0)); // c1->PTR3
      ENC_ENTRY+9:  prog_rom = mk(OP_DONE,   pl_done(1'b0));

      // ---------- DECRYPT (entry 32, L=1) ----------
      DEC_ENTRY+0:  prog_rom = mk(OP_DMA_IN, pl_dma(B_NTTMSG, 3'd0, 1'b0, 2'd0, 1'b0)); // c0<-PTR0
      DEC_ENTRY+1:  prog_rom = mk(OP_DMA_IN, pl_dma(B_NTTKEY, 3'd1, 1'b0, 2'd0, 1'b0)); // c1<-PTR1
      DEC_ENTRY+2:  prog_rom = SRAM_REUSE ? mk(OP_NOP, 28'd0) : mk(OP_MOVE,   pl_move(B_SK, B_NTTV, 1'b0, 1'b0));
      DEC_ENTRY+3:  prog_rom = mk(OP_EXE, pl_exe(T_PWMDEC[7:0], 1'b1, SC_NONE, PS_ZERO));
      DEC_ENTRY+4:  prog_rom = mk(OP_EXE, pl_exe(T_NTTINV[7:0], 1'b1, SC_NONE, PS_ZERO));
      DEC_ENTRY+5:  prog_rom = mk(OP_EXE, pl_exe(T_I2F[7:0], 1'b1, SC_I2F, PS_ZERO));
      DEC_ENTRY+6:  prog_rom = mk(OP_EXE, pl_exe(T_FFTDIT[7:0], 1'b0, SC_NONE, PS_ZERO));
      DEC_ENTRY+7:  prog_rom = mk(OP_EXE, pl_exe(T_PROJ[7:0], 1'b0, SC_NONE, PS_ZERO));
      DEC_ENTRY+8:  prog_rom = mk(OP_DMA_OUT,pl_dma(B_FFT, 3'd2, 1'b0, 2'd0, 1'b1));    // out<-upper N of 2N
      DEC_ENTRY+9:  prog_rom = mk(OP_DONE,   pl_done(1'b0));
`ifdef FHE_RECOVER_CMD  // FHE_RECOVER_EN; the dispatch below refuses RECOVER otherwise
      // Coefficient recovery: each limb stays in the modular datapath.
      // PTR0/PTR1 input and PTR2 output are limb-major, N u64 words per limb.
      REC_ENTRY+0:  prog_rom = mk(OP_LIMB, pl_limb(8'd6));
      REC_ENTRY+1:  prog_rom = mk(OP_DMA_IN, pl_dma(B_NTTMSG, 3'd0, 1'b1, 2'd0, 1'b0));
      REC_ENTRY+2:  prog_rom = mk(OP_DMA_IN, pl_dma(B_NTTKEY, 3'd1, 1'b1, 2'd0, 1'b0));
      REC_ENTRY+3:  prog_rom = SRAM_REUSE ? mk(OP_NOP, 28'd0) : mk(OP_MOVE, pl_move(B_SK, B_NTTV, 1'b1, 1'b0));
      REC_ENTRY+4:  prog_rom = mk(OP_EXE, pl_exe(T_PWMDEC[7:0], 1'b1, SC_NONE, PS_ZERO));
      REC_ENTRY+5:  prog_rom = mk(OP_EXE, pl_exe(T_NTTINV[7:0], 1'b1, SC_NONE, PS_ZERO));
      REC_ENTRY+6:  prog_rom = mk(OP_DMA_OUT, pl_dma(B_NTTMSG, 3'd2, 1'b1, 2'd0, 1'b0));
      REC_ENTRY+7:  prog_rom = mk(OP_DONE, pl_done(1'b0));
`endif

      // Single q0 input -> raw snapshot R -> fresh e0 -> centre/lift into each target limb.
      REF_ENTRY+0:  prog_rom = mk(OP_DMA_IN, pl_dma(B_NTTMSG, 3'd0, 1'b0, 2'd0, 1'b0));
      REF_ENTRY+1:  prog_rom = mk(OP_DMA_IN, pl_dma(B_NTTKEY, 3'd1, 1'b0, 2'd0, 1'b0));
      REF_ENTRY+2:  prog_rom = mk(OP_EXE, pl_exe(T_PWMDEC[7:0], 1'b1, SC_NONE, PS_ZERO));
      REF_ENTRY+3:  prog_rom = mk(OP_EXE, pl_exe(T_NTTINV[7:0], 1'b1, SC_NONE, PS_ZERO));
      REF_ENTRY+4:  prog_rom = mk(OP_EXE, pl_exe(T_SNAPSHOT[7:0], 1'b0, SC_NONE, PS_ZERO));
      REF_ENTRY+5:  prog_rom = mk(OP_EXE, pl_exe(T_SAMPLE[7:0], 1'b0, SC_NONE, PS_ERR));
      REF_ENTRY+6:  prog_rom = mk(OP_LIMB, pl_limb(8'd5));
      REF_ENTRY+7:  prog_rom = mk(OP_EXE, pl_exe(T_LIFT[7:0], 1'b1, SC_NONE, PS_ZERO));
      REF_ENTRY+8:  prog_rom = mk(OP_EXE, pl_exe(T_NTTFWD[7:0], 1'b1, SC_NONE, PS_A));
      REF_ENTRY+9:  prog_rom = mk(OP_EXE, pl_exe(T_PWMENC[7:0], 1'b1, SC_NONE, PS_ZERO));
      REF_ENTRY+10: prog_rom = mk(OP_DMA_OUT, pl_dma(B_NTTMSG, 3'd2, 1'b1, 2'd0, 1'b0));
      REF_ENTRY+11: prog_rom = mk(OP_DMA_OUT, pl_dma(B_NTTKEY, 3'd3, 1'b1, 2'd0, 1'b0));
      REF_ENTRY+12: prog_rom = mk(OP_DONE, pl_done(1'b0));
      default: ;
    endcase
  endfunction

  // =====================================================================
  // FSM
  // =====================================================================
  typedef enum logic [4:0] {
    S_IDLE, S_FETCH, S_DECODE,
    S_DMA_REQ,
    S_WR, S_WR_LO, S_SK_READ,
    S_RD,
    S_EXE_POLL,
    S_DONE
  } state_e;

  state_e      st;
  logic [7:0]  pc;
  logic [31:0] op_w;             // current macro-op word

  // limb loop
  logic        limb_active;
  logic [3:0]  limb_idx;
  assign active_limb = limb_idx;
  wire [63:0] r2_cur = r2modq[limb_idx];  // R^2 mod q of the active limb
  logic [3:0]  limb_cnt;         // = num_limbs for this cmd (1 if decrypt)
  logic [7:0]  limb_base;        // pc of first body word
  logic [7:0]  limb_len;
  wire         recover = FHE_RECOVER_EN && (cmd == FHE_RECOVER);  // constant 0 without RECOVER

  // word loop (send64 / receive64)
  logic [LOGN:0] widx;
  logic [LOGN:0] wn;             // word count target
  logic [3:0]    cur_bank;
  logic [1:0]    cur_cid;        // write-data source (C_ZEROS / C_R2 / C_DIN)
  logic [2:0]    cur_ptr;
  logic          cur_off;        // read upper-N offset
  logic [63:0]   wdata;          // data being written this word
  logic [2:0]    rd_wait;
  logic          cur_sk;         // word loop is an SK-load / SK-store (MOVE)

  // receive64 streams: one read address per step, retired RD_LAT steps later
  // (address register, bank read, output register). Retired words wait in rdq
  // while the bridge is not ready; a read issues only when its word already
  // has a slot, so nothing in flight is ever dropped.
  localparam int RD_LAT = 3;
  logic [LOGN:0]     rd_iss;       // next word index to issue
  logic [RD_LAT-1:0] rd_pipe;      // rd_pipe[k]: a read issued k+1 steps ago
  logic [63:0]       rdq [0:RD_LAT-1];
  logic [1:0]        rdq_n;
  // DMA_OUT push, like dma_rd_pop: valid in the step that hands the word over
  // (the queue head, or the word retiring now), so ready and valid meet on one edge.
  wire rd_retire = rd_pipe[RD_LAT-1];
  wire rd_push   = step && (st == S_RD) && !cur_sk && ((rdq_n != 0) || rd_retire) && dma_wr_ready;
  assign ext_dout_we = rd_push;

  // Command of the current pass; core_cmd presents it in S_EXE_POLL
  logic [39:0]   pass_cmd;

  // DMA descriptor (B' 2c-step-2): captured at a DMA op decode, presented to the
  // DMA engine in S_DMA_REQ. The word stream then flows with valid/ready.
  logic          desc_wr_r;
  logic [2:0]    desc_ptr_r;
  logic [3:0]    desc_limb_r;

  // Resident +sk_ntt: one synchronous read/write port. The integrated path
  // exports this storage; the trace-only walker TB uses the same latency model.
  logic [3:0]    mv_limb;
`ifndef FHE_WALKER
  logic sk_en, sk_we;
  logic [$clog2(N*FHE_L)-1:0] sk_addr;
  logic [53:0] sk_wdata, sk_rdata;
  logic [53:0] sk_mem [0:N*FHE_L-1];
  always_ff @(posedge clk) begin
    if (sk_en) begin
      if (sk_we) sk_mem[sk_addr] <= sk_wdata;
      else sk_rdata <= sk_mem[sk_addr];
    end
  end
`endif
  assign sk_we = (st == S_RD) && cur_sk && (rd_wait >= 3'd2);
  assign sk_en = step && rst_b && !zeroize && ((st == S_SK_READ) || sk_we);
  assign sk_addr = $clog2(N*FHE_L)'(mv_limb*N + widx);
  assign sk_wdata = {dout_high[21:0], dout_low};

  assign dma_desc_valid = step && (st == S_DMA_REQ) && dma_ready;
  assign exe_held       = (st == S_DECODE) && (f_op(op_w) == OP_EXE) && exe_hold;
  assign dma_desc_wr    = desc_wr_r;
  assign dma_desc_ptr   = desc_ptr_r;
  assign dma_desc_limb  = desc_limb_r;
  // pop a DMA_IN word the cycle the walker consumes it (S_WR, not stalled)
  assign dma_rd_pop     = step && (st == S_WR) && !cur_sk && (cur_cid == C_DIN) && dma_rd_valid;

  // ---- scale patch (replicates ins_rns / ins_i2f bit math) ----
  // replicate ins_rns / ins_i2f scale-field packing exactly. RNS: sh masked
  // 7-bit, logical shift (scale >= 0). I2F: sh masked 4-bit, ARITHMETIC shift
  // (scale is signed/negative). sm 2-bit, sl 3-bit in both.
  function automatic logic [39:0] scale_bits(input logic [1:0] sc);
    logic signed [31:0] s;
    logic [6:0] sh; logic [1:0] sm; logic [2:0] sl;
    if (sc == SC_I2F) begin
      s  = 32'(signed'(scale));       // sign-extend the 12-bit field
      sh = (s >>> 5) & 7'h0f;          // 4-bit mask
      sm = (s >>> 3) & 2'h3;
      sl =  s        & 3'h7;
    end else begin
      s  = 32'(scale);
      sh = (s >> 5) & 7'h7f;           // 7-bit mask
      sm = (s >> 3) & 2'h3;
      sl =  s       & 3'h7;
    end
    scale_bits = (40'(sh) << 33) | (40'(sl) << 30) | (40'(sm) << 3);
  endfunction

  // build the patched command template for the current limb
  function automatic logic [39:0] patch_word(input logic [7:0] taddr, input logic patch, input logic [1:0] sc, input logic [3:0] li);
    logic [39:0] w; int unsigned t;
    t = taddr;
    w = tmpl_base(t);
    if (patch) begin
      if (tmpl_use_q(t))   w = w | (40'(neg_qm(fhe_qm(li))) << 13);
      if (tmpl_use_rom(t)) w = w | (40'(li) << 9);
      if (tmpl_use_q(t))   w = w | (40'(li) << 5);
      if (sc != SC_NONE)   w = w | scale_bits(sc);
    end
    patch_word = w;
  endfunction

  // bank word address: off reads the upper N of a 2N-word bank
  function automatic logic [LOGN:0] bank_addr(input logic off, input logic [LOGN:0] idx);
    bank_addr = off ? ((LOGN+1)'(N) + idx) : idx;
  endfunction

  // control_low constructor (send64/receive64 packing; always granted, never INS)
  function automatic logic [31:0] mk_ctrl(input logic [3:0] bank, input logic wea, input logic [LOGN:0] addr);
    mk_ctrl = (32'(bank[2:0]) << 29) | (32'd1 << FHE_CW_GRANT) | (32'(wea) << FHE_CW_WEA) | 32'(addr);
  endfunction

  wire [63:0] dout = {dout_high, dout_low};
  assign ext_dout = (rdq_n != 0) ? rdq[0] : dout;  // DMA_OUT word for rd_push

  // write-data source for the current send64 word
  function automatic logic [63:0] cur_wr_data();
    if (cur_sk)          cur_wr_data = {10'd0, sk_rdata}; // SK-load
    else if (cur_cid == C_DIN) cur_wr_data = ext_din;       // DMA_IN
    else if (cur_cid == C_R2) cur_wr_data = r2_cur;
    else                      cur_wr_data = 64'd0;          // CONST ZEROS
  endfunction

  // ext_sel/ext_idx are combinational so ext_din (comb in the TB on these) is
  // valid the same cycle dina is latched.
  always_comb begin
    ext_sel = 3'd0;
    ext_idx = '0;
    if (((st == S_WR) && (cur_cid == C_DIN)) || (st == S_RD)) begin
      ext_sel = cur_ptr; ext_idx = widx;
    end
  end

  assign core_cmd = (st == S_EXE_POLL) ? pass_cmd : '0;

  always_ff @(posedge clk or negedge rst_b) begin
    if (!rst_b) begin
      st <= S_IDLE; pc <= 8'd0;
      control_low_word <= 32'd0; control_high_word <= 32'd1; // hold reset
      dina_low <= 32'd0; dina_high <= 32'd0;
      busy <= 1'b0; done <= 1'b0; error <= 1'b0;
      cur_sk <= 1'b0;
      limb_active <= 1'b0; limb_idx <= 4'd0; limb_cnt <= 4'd1;
      widx <= '0; wn <= '0; rd_wait <= 3'd0;
      rd_iss <= '0; rd_pipe <= '0; rdq_n <= '0;
      reseed_en <= 1'b0;
    end else if (zeroize) begin
      st <= S_IDLE; busy <= 1'b0; done <= 1'b0; error <= 1'b0;
      control_low_word <= 32'd0; control_high_word <= 32'd1;
      limb_active <= 1'b0;
      reseed_en <= 1'b0;
    end else if (step) begin
      done <= 1'b0;
      unique case (st)
        // -------------------------------------------------------------
        S_IDLE: begin
          // The core stays in reset while idle; a command releases it. That
          // also restarts Expand's slot counter before ENCRYPT's message load.
          control_high_word <= 32'd1;
          control_low_word  <= 32'd0;
          if (cmd_valid && (cmd != FHE_NONE)) begin
            control_high_word <= 32'd0;
            busy        <= 1'b1;
            error       <= 1'b0;
            limb_active <= 1'b0;
            limb_idx    <= 4'd0;
            // KEYGEN always fills every installed key limb.
            limb_cnt    <= (cmd == FHE_KEYGEN) ? 4'(FHE_L) :
                           (cmd == FHE_ENCRYPT || recover || cmd == FHE_REFRESH)
                             ? ((num_limbs==4'd0)?4'd1:num_limbs) : 4'd1;
            pc <= (cmd == FHE_KEYGEN)  ? KG_ENTRY[7:0] :
                  (cmd == FHE_ENCRYPT) ? ENC_ENTRY[7:0] :
                  (cmd == FHE_REFRESH) ? REF_ENTRY[7:0] :
                  recover              ? REC_ENTRY[7:0] : DEC_ENTRY[7:0];
            // Recovery must never address a key/table limb outside this build,
            // and a build without RECOVER has no program for it.
            if (((recover || cmd == FHE_REFRESH) &&
                 (num_limbs == 0 || num_limbs > FHE_L)) ||
                (cmd == FHE_RECOVER && !FHE_RECOVER_EN) ||
                (cmd == FHE_REFRESH && !SRAM_REUSE)) begin
              error <= 1'b1;
              st <= S_DONE;
            end else st <= S_FETCH;
          end
        end
        // -------------------------------------------------------------
        S_FETCH: begin
          // limb-loop body wrap: when the body (limb_len words from limb_base)
          // is exhausted, either re-run it for the next limb or fall through.
          if (limb_active && (pc == (limb_base + limb_len))) begin
            if ((limb_idx + 1'b1) < limb_cnt) begin
              limb_idx <= limb_idx + 1'b1;
              pc       <= limb_base;
              op_w     <= prog_rom(limb_base);
            end else begin
              limb_active <= 1'b0;
              op_w        <= prog_rom(pc);
            end
          end else begin
            op_w <= prog_rom(pc);
          end
          st <= S_DECODE;
        end
        // -------------------------------------------------------------
        S_DECODE: begin
          unique case (f_op(op_w))
            OP_DONE: begin
              error <= f_irq(op_w);
              st    <= S_DONE;
            end
            OP_LIMB: begin
              limb_active <= 1'b1;
              limb_idx    <= 4'd0;
              limb_base   <= pc + 8'd1;
              limb_len    <= f_bl(op_w);
              pc          <= pc + 8'd1;
              st          <= S_FETCH;
            end
            OP_EXE: if (!exe_hold) begin
              // The sampler seed arrives on fhe_top's sideband; only the KEYGEN
              // key-sampling pass reloads it. dina carries no seed; it holds the
              // limb's R^2 for the keygen-convert PWM and is zero otherwise.
              reseed_en <= (f_ps(op_w) == PS_KG);
              {dina_high, dina_low} <= f_r2(op_w) ? r2_cur : 64'd0;
              control_low_word <= 32'd0;
              pass_cmd <= patch_word(f_tmpl(op_w), f_pat(op_w), f_sc(op_w), limb_idx);
              st <= S_EXE_POLL;
            end
            OP_CONST: begin
              cur_bank <= f_bank(op_w); cur_sk <= 1'b0;
              cur_cid  <= f_cid(op_w);  cur_ptr <= 3'd7; // n/a
              widx <= '0; wn <= (LOGN+1)'(N);
              st <= S_WR;
            end
            OP_DMA_IN: begin
              cur_bank <= f_bank(op_w); cur_sk <= 1'b0;
              cur_cid  <= C_DIN;        cur_ptr <= f_ptr(op_w);
              widx <= '0; wn <= (LOGN+1)'(N);
              desc_wr_r <= 1'b0; desc_ptr_r <= f_ptr(op_w); desc_limb_r <= limb_idx;
              st <= S_DMA_REQ;          // kick the DMA read, then stream into the core
            end
            OP_DMA_OUT: begin
              cur_bank <= f_bank(op_w); cur_ptr <= f_ptr(op_w); cur_sk <= 1'b0;
              cur_off  <= f_off(op_w);
              widx <= '0; wn <= (LOGN+1)'(N); rd_wait <= 3'd0;
              rd_iss <= '0; rd_pipe <= '0; rdq_n <= '0;
              control_low_word <= mk_ctrl(f_bank(op_w), 1'b0, bank_addr(f_off(op_w), '0));
              desc_wr_r <= 1'b1; desc_ptr_r <= f_ptr(op_w); desc_limb_r <= limb_idx;
              st <= S_DMA_REQ;          // kick the DMA write, then drain the core into it
            end
            OP_MOVE: begin
              // one side is B_SK (the walker's local sk store), the other a
              // core bank. src==SK -> SK-load (send64 local->core); dst==SK ->
              // SK-store (receive64 core->local). The strided side selects the
              // sk slice limb; for L=1 decrypt that is limb 0.
              cur_sk  <= 1'b1;
              mv_limb <= (f_ss(op_w) || f_ds(op_w)) ? limb_idx : 4'd0;
              widx <= '0; wn <= (LOGN+1)'(N); rd_wait <= 3'd0;
              if (f_sb(op_w) == B_SK) begin
                // SK-load: send64 from sk_mem to dst core bank (cur_sk picks the data)
                cur_bank <= f_db(op_w);
                st <= S_SK_READ;
              end else begin
                // SK-store: receive64 from src core bank into sk_mem
                cur_bank <= f_sb(op_w); cur_off <= 1'b0;
                control_low_word <= mk_ctrl(f_sb(op_w), 1'b0, '0);
                st <= S_RD;
              end
            end
            default: begin // NOP -> advance
              pc <= pc + 8'd1; st <= S_FETCH;
            end
          endcase
        end
        // ------------ DMA descriptor handoff (B' 2c-step-2) -----------
        // Wait for the DMA engine idle, pulse the descriptor (combinational
        // dma_desc_valid), then enter the word loop. For a read, hold the core
        // idle; for a write, the core-read grant set at decode persists.
        S_DMA_REQ: begin
          if (!desc_wr_r) control_low_word <= 32'd0;
          if (dma_ready) st <= desc_wr_r ? S_RD : S_WR;
        end
        // ------------ send64 word loop (wea=1 cycle) ------------------
        S_SK_READ: st <= S_WR; // SRAM captures address; data is ready in S_WR
        S_WR: begin
          // DMA_IN read stall: hold until the DMA engine presents the next word.
          // The stall drops wea: FFT writes pair an even word (staged) with the
          // odd one, and Expand acts on a rising wea.
          if ((cur_cid == C_DIN) && !cur_sk && !dma_rd_valid) begin
            control_low_word <= 32'd0;
          end else begin
            wdata = cur_wr_data();
            dina_low  <= wdata[31:0];
            dina_high <= wdata[63:32];
            control_low_word <= mk_ctrl(cur_bank, 1'b1, widx);
            // Keep wea up and write the next word on the next step; S_WR_LO
            // closes the last word (and paces SK-load words).
            if (!cur_sk && (widx != wn - 1)) widx <= widx + 1'b1;
            else st <= S_WR_LO;
          end
        end
        S_WR_LO: begin
          control_low_word <= mk_ctrl(cur_bank, 1'b0, widx);
          if (widx == wn - 1) begin
            // last word done -> idle control, advance program
            control_low_word <= 32'd0;
            pc <= pc + 8'd1;
            st <= S_FETCH;
          end else begin
            widx <= widx + 1'b1;
            st <= cur_sk ? S_SK_READ : S_WR;
          end
        end
        // ------------ receive64 word loop (DMA_OUT) -------------------
        S_RD: if (!cur_sk) begin
          // Retire the word read RD_LAT steps ago (pushed now, see rd_push, or
          // queued), and issue the next address while every read not yet
          // pushed fits in the queue.
          automatic logic bypass = rd_push && (rdq_n == 0);  // retired word goes straight out
          automatic logic issue  = (rd_iss != wn) && (rd_iss - widx - rd_push < RD_LAT);
          if (rd_push) widx <= widx + 1'b1;
          if (rd_push && !bypass) begin
            for (int i = 0; i < RD_LAT - 1; i++) rdq[i] <= rdq[i+1];
          end
          if (rd_retire && !bypass) rdq[rdq_n - rd_push] <= dout;
          rdq_n   <= rdq_n + rd_retire - rd_push;
          rd_pipe <= {rd_pipe[RD_LAT-2:0], issue};
          if (issue) begin
            control_low_word <= mk_ctrl(cur_bank, 1'b0, bank_addr(cur_off, rd_iss));
            rd_iss <= rd_iss + 1'b1;
          end
          if (rd_push && (widx == wn - 1)) begin
            control_low_word <= 32'd0;
            pc <= pc + 8'd1;
            st <= S_FETCH;
          end
        end else begin
          // SK-store: sk_we writes the word at rd_wait 2, one word per three steps.
          if (rd_wait < 3'd2) begin
            rd_wait <= rd_wait + 1'b1;
          end else if (widx == wn - 1) begin
            control_low_word <= 32'd0;
            pc <= pc + 8'd1;
            st <= S_FETCH;
          end else begin
            widx <= widx + 1'b1;
            rd_wait <= 3'd0;
            control_low_word <= mk_ctrl(cur_bank, 1'b0, bank_addr(cur_off, widx + 1'b1));
          end
        end
        // ------------ pass: core_cmd = pass_cmd until done -------------
        // Leaving the state drops core_cmd to 0, which puts the pass's unit
        // back in reset and clears the wrapper's done before the next pass.
        S_EXE_POLL: if (status[0]) begin
          pc <= pc + 8'd1;
          st <= S_FETCH;
        end
        // -------------------------------------------------------------
        S_DONE: begin
          // Wait for any in-flight DMA write burst to commit before signalling
          // completion, so a following command reads coherent DRAM.
          if (dma_ready) begin
            busy        <= 1'b0;
            done        <= 1'b1;
            limb_active <= 1'b0;
            control_high_word <= 32'd1;  // reset the core for at least the idle step
            st          <= S_IDLE;
          end
        end
        default: st <= S_IDLE;
      endcase
    end else begin
      // Bus-facing event pulses must not stretch across held engine cycles.
      done <= 1'b0;
    end
  end

endmodule
