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
//   Turns one high-level command (KEYGEN / ENCRYPT / DECRYPT) into the
//   sequence of Aloha-HE ComputeCore engine passes that implements it, by
//   driving the ComputeCoreWrapper debug-IO pins (control_low_word /
//   control_high_word / dina_ext / status / dout_ext) -- i.e. it is a HARDWARE
//   send64 / receive64 / exe_ins sequencer. Driving the *native* debug-IO
//   protocol (rather than a new internal port) is deliberate: the walker's
//   pin trace is then identical to the green cosim_* testbench trace, which is
//   exactly the B' correctness criterion (see design-review/
//   fhe-ckks-bprime-microsequencer.md sections 5.1/5.2/9).
//
//   This is the 2a deliverable: walker + ROMs only. No DMA, no real
//   ComputeCore -- external poly data flows over ext_* ports the TB drives.
//   Decrypt is L=1 (multi-limb deferred).
//
//   Macro-op word + ROM layout: see microsequencer doc section 5.1/5.2.
//
module fhe_microseq
  import fhe_params_pkg::*;
#(
  parameter int LOGN = 13,
  parameter int N    = 1 << LOGN
)(
  input  logic        clk,
  input  logic        rst_b,
  input  logic        zeroize,

  // command issue (1-cycle pulse)
  input  logic        cmd_valid,
  input  fhe_cmd_e    cmd,

  // runtime inputs (registers in fhe_top; CSRNG/Trivium in C')
  input  logic [63:0] keygen_seed,
  input  logic [63:0] a_seed,
  input  logic [63:0] err_seed,
  // Scale fields. enc/dec scales are PER-COMMAND inputs: Caliptra firmware
  // computes them (it knows Delta / level / whether the ct is a product or
  // rescaled) and writes them when issuing the ENCRYPT / DECRYPT command. The
  // keygen scale is service-internal (not user-facing precision) so it stays a
  // fixed CONFIG-derived value.
  input  logic [31:0] rns_scale_kg,   // RT_SCALE-52-1023-LOGN   (keygen RNS, internal)
  input  logic [31:0] rns_scale_enc,  // encode RNS scale        (ENCRYPT command input)
  input  logic [31:0] i2f_scale_dec,  // signed decode I2F scale (DECRYPT command input)
  input  logic [3:0]  num_limbs,      // CONFIG.L (encrypt); decrypt forced to 1

  // per-limb R^2 mod q_i constant for keygen Montgomery-convert (CONST R2MODQ)
  input  logic [63:0] r2modq [0:FHE_L-1],

  // ----- ComputeCoreWrapper debug-IO master (the pins we drive) -----
  output logic [31:0] control_low_word,
  output logic [31:0] control_high_word,
  output logic [31:0] dina_low,
  output logic [31:0] dina_high,
  input  logic [31:0] dout_low,
  input  logic [31:0] dout_high,
  input  logic [31:0] status,

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

  output logic        busy,
  output logic        done,           // 1-cycle pulse
  output logic        error
);

  // =====================================================================
  // Macro-op encoding (FROZEN -- doc section 5.1)
  // =====================================================================
  localparam logic [3:0] OP_NOP=4'd0, OP_DMA_IN=4'd1, OP_DMA_OUT=4'd2,
                         OP_CONST=4'd3, OP_LDINS=4'd4, OP_EXE=4'd5,
                         OP_MOVE=4'd6, OP_LIMB=4'd7, OP_DONE=4'd8;

  // BANK ids (mirror Aloha bram_sel; SK=8 is new in B'/C')
  localparam logic [3:0] B_FFT=4'd0, B_NTTMSG=4'd1, B_NTTV=4'd3,
                         B_ERR=4'd4, B_NTTKEY=4'd5, B_FFTEXP=4'd6,
                         B_FFTIM=4'd7, B_SK=4'd8;

  // PARAMSEL (EXE seed source)
  localparam logic [1:0] PS_ZERO=2'd0, PS_KG=2'd1, PS_A=2'd2, PS_ERR=2'd3;
  // SCALESEL (INS scale-field patch source)
  localparam logic [1:0] SC_NONE=2'd0, SC_RNSKG=2'd1, SC_RNSENC=2'd2, SC_I2F=2'd3;
  // write-data source for a send64 word (the cur_cid selector)
  localparam logic [1:0] C_ZEROS=2'd0, C_R2=2'd1, C_DIN=2'd3;  // C_DIN = DMA_IN (ext_din)

  // INS-template indices
  localparam int unsigned T_FFTDIF=0, T_FFTDIT=1, T_RNS=2, T_NTTFWD=3,
                          T_NTTINV=4, T_PWMENC=5, T_PWMDEC=6, T_I2F=7, T_PROJ=8;

  // =====================================================================
  // INS-template ROM (raw 64-bit inner words, pre-patch). doc section 5.2.
  //   build_ins_buf framing + the per-limb (neg_qm,modsel,k)+scale patch are
  //   applied by the LDINS handler below. W40 = command_we bit (1<<40).
  // =====================================================================
  localparam logic [63:0] W40 = 64'h1 << 40;

  // base template words (opcode + fixed flags only)
  function automatic logic [63:0] tmpl_base(input int unsigned t);
    case (t)
      T_FFTDIF: tmpl_base = W40 | (64'd1<<4) | (64'd1<<3) | 64'd1; // FFT is_dif=1
      T_FFTDIT: tmpl_base = W40 | (64'd1<<4) |              64'd1; // FFT is_dif=0
      T_RNS   : tmpl_base = W40 | 64'd2;                          // RNS
      T_NTTFWD: tmpl_base = W40 |              64'd1;             // NTT is_dif=0
      T_NTTINV: tmpl_base = W40 | (64'd1<<3) | 64'd1;            // NTT is_dif=1
      T_PWMENC: tmpl_base = W40 | (64'd1<<4) | (64'd1<<3) | 64'd4;// PWM enc=1,neg=1
      T_PWMDEC: tmpl_base = W40 | 64'd4;                          // PWM enc=0,neg=0
      T_I2F   : tmpl_base = W40 | 64'd3;                          // I2F
      T_PROJ  : tmpl_base = W40 | 64'd5;                          // PROJECT
      default : tmpl_base = W40;
    endcase
  endfunction
  // which fields the template needs patched
  function automatic logic tmpl_use_q  (input int unsigned t);
    tmpl_use_q  = (t==T_RNS)||(t==T_NTTFWD)||(t==T_NTTINV)||(t==T_PWMENC)||(t==T_PWMDEC)||(t==T_I2F);
  endfunction
  function automatic logic tmpl_use_rom(input int unsigned t);
    tmpl_use_rom = (t==T_RNS)||(t==T_NTTFWD)||(t==T_NTTINV);
  endfunction

  // =====================================================================
  // Limb-param table (FROZEN, B' L<=2): {qm, k, modsel}. Rung-7 chain.
  //   q0 = 2^46-9*2^24+1 : qm=9,  k=0, modsel=0
  //   q1 = 2^47-2^24+1   : qm=1,  k=1, modsel=1
  // =====================================================================
  // {qm, k, modsel} per limb as a table (frozen 2-prime chain; extend for L>2).
  localparam logic [16:0] LP_QM [0:1] = '{17'd9, 17'd1};
  localparam logic [3:0]  LP_K  [0:1] = '{4'd0,  4'd1};
  localparam logic [3:0]  LP_MS [0:1] = '{4'd0,  4'd1};
  function automatic logic [16:0] lp_qm (input logic [3:0] i); lp_qm = LP_QM[i[0]]; endfunction
  function automatic logic [3:0]  lp_k  (input logic [3:0] i); lp_k  = LP_K [i[0]]; endfunction
  function automatic logic [3:0]  lp_ms (input logic [3:0] i); lp_ms = LP_MS[i[0]]; endfunction
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
  // LDINS : ins_addr[27:20] ins_len[19:16] patch[15] scalesel[14:13]
  function automatic logic [27:0] pl_ldins(input logic [7:0] addr, input logic [3:0] len, input logic patch, input logic [1:0] sc);
    pl_ldins = {addr, len, patch, sc, 13'd0};
  endfunction
  // EXE : paramsel[27:26]
  function automatic logic [27:0] pl_exe(input logic [1:0] ps); pl_exe = {ps, 26'd0}; endfunction
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
  function automatic logic [7:0]  f_iadr(input logic [31:0] w); f_iadr = w[27:20]; endfunction
  function automatic logic [3:0]  f_ilen(input logic [31:0] w); f_ilen = w[19:16]; endfunction
  function automatic logic        f_pat (input logic [31:0] w); f_pat  = w[15];    endfunction
  function automatic logic [1:0]  f_sc  (input logic [31:0] w); f_sc   = w[14:13]; endfunction
  function automatic logic [1:0]  f_ps  (input logic [31:0] w); f_ps   = w[27:26]; endfunction
  function automatic logic [3:0]  f_sb  (input logic [31:0] w); f_sb   = w[27:24]; endfunction
  function automatic logic [3:0]  f_db  (input logic [31:0] w); f_db   = w[23:20]; endfunction
  function automatic logic        f_ss  (input logic [31:0] w); f_ss   = w[19];    endfunction
  function automatic logic        f_ds  (input logic [31:0] w); f_ds   = w[18];    endfunction
  function automatic logic [7:0]  f_bl  (input logic [31:0] w); f_bl   = w[27:20]; endfunction
  function automatic logic        f_irq (input logic [31:0] w); f_irq  = w[27];    endfunction

  // =====================================================================
  // Program ROM (FROZEN -- doc section 7). One contiguous ROM, per-cmd entry.
  // =====================================================================
  localparam int PROG_N = 48;
  localparam int KG_ENTRY  = 0;
  localparam int ENC_ENTRY = 16;
  localparam int DEC_ENTRY = 32;

  logic [31:0] PROG [0:PROG_N-1];
  initial begin
    integer i;
    for (i=0;i<PROG_N;i=i+1) PROG[i] = mk(OP_NOP, 28'd0);

    // ---------- KEYGEN (entry 0) ----------
    PROG[KG_ENTRY+0]  = mk(OP_CONST, pl_const(B_FFTEXP, C_ZEROS));
    PROG[KG_ENTRY+1]  = mk(OP_LDINS, pl_ldins(T_FFTDIF[7:0], 4'd1, 1'b0, SC_NONE));
    PROG[KG_ENTRY+2]  = mk(OP_EXE,   pl_exe(PS_KG));
    PROG[KG_ENTRY+3]  = mk(OP_LIMB,  pl_limb(8'd9));        // body = next 9 words
    PROG[KG_ENTRY+4]  = mk(OP_LDINS, pl_ldins(T_RNS[7:0],    4'd1, 1'b1, SC_RNSKG));
    PROG[KG_ENTRY+5]  = mk(OP_EXE,   pl_exe(PS_ZERO));
    PROG[KG_ENTRY+6]  = mk(OP_LDINS, pl_ldins(T_NTTFWD[7:0], 4'd1, 1'b1, SC_NONE));
    PROG[KG_ENTRY+7]  = mk(OP_EXE,   pl_exe(PS_ZERO));
    PROG[KG_ENTRY+8]  = mk(OP_CONST, pl_const(B_NTTKEY, C_R2));
    PROG[KG_ENTRY+9]  = mk(OP_CONST, pl_const(B_NTTMSG, C_ZEROS));
    PROG[KG_ENTRY+10] = mk(OP_LDINS, pl_ldins(T_PWMDEC[7:0], 4'd1, 1'b1, SC_NONE));
    PROG[KG_ENTRY+11] = mk(OP_EXE,   pl_exe(PS_ZERO));
    PROG[KG_ENTRY+12] = mk(OP_MOVE,  pl_move(B_NTTMSG, B_SK, 1'b0, 1'b1)); // NTT_MSG->SK[limb]
    PROG[KG_ENTRY+13] = mk(OP_DONE,  pl_done(1'b0));

    // ---------- ENCRYPT (entry 16) ----------
    PROG[ENC_ENTRY+0]  = mk(OP_DMA_IN, pl_dma(B_FFTEXP, 3'd0, 1'b0, 2'd0, 1'b0)); // PTR0=msg
    PROG[ENC_ENTRY+1]  = mk(OP_LDINS,  pl_ldins(T_FFTDIF[7:0], 4'd1, 1'b0, SC_NONE));
    PROG[ENC_ENTRY+2]  = mk(OP_EXE,    pl_exe(PS_ERR));
    PROG[ENC_ENTRY+3]  = mk(OP_LIMB,   pl_limb(8'd9));
    PROG[ENC_ENTRY+4]  = mk(OP_LDINS,  pl_ldins(T_RNS[7:0],    4'd1, 1'b1, SC_RNSENC));
    PROG[ENC_ENTRY+5]  = mk(OP_EXE,    pl_exe(PS_ZERO));
    PROG[ENC_ENTRY+6]  = mk(OP_LDINS,  pl_ldins(T_NTTFWD[7:0], 4'd1, 1'b1, SC_NONE));
    PROG[ENC_ENTRY+7]  = mk(OP_EXE,    pl_exe(PS_A));
    PROG[ENC_ENTRY+8]  = mk(OP_MOVE,   pl_move(B_SK, B_NTTV, 1'b1, 1'b0)); // SK[limb]->NTT_V
    PROG[ENC_ENTRY+9]  = mk(OP_LDINS,  pl_ldins(T_PWMENC[7:0], 4'd1, 1'b1, SC_NONE));
    PROG[ENC_ENTRY+10] = mk(OP_EXE,    pl_exe(PS_ZERO));
    PROG[ENC_ENTRY+11] = mk(OP_DMA_OUT,pl_dma(B_NTTMSG, 3'd2, 1'b1, 2'd0, 1'b0)); // c0->PTR2
    PROG[ENC_ENTRY+12] = mk(OP_DMA_OUT,pl_dma(B_NTTKEY, 3'd3, 1'b1, 2'd0, 1'b0)); // c1->PTR3
    PROG[ENC_ENTRY+13] = mk(OP_DONE,   pl_done(1'b0));

    // ---------- DECRYPT (entry 32, L=1) ----------
    PROG[DEC_ENTRY+0]  = mk(OP_DMA_IN, pl_dma(B_NTTMSG, 3'd0, 1'b0, 2'd0, 1'b0)); // c0<-PTR0
    PROG[DEC_ENTRY+1]  = mk(OP_DMA_IN, pl_dma(B_NTTKEY, 3'd1, 1'b0, 2'd0, 1'b0)); // c1<-PTR1
    PROG[DEC_ENTRY+2]  = mk(OP_MOVE,   pl_move(B_SK, B_NTTV, 1'b0, 1'b0));        // SK[0]->NTT_V
    PROG[DEC_ENTRY+3]  = mk(OP_LDINS,  pl_ldins(T_PWMDEC[7:0], 4'd1, 1'b1, SC_NONE));
    PROG[DEC_ENTRY+4]  = mk(OP_EXE,    pl_exe(PS_ZERO));
    PROG[DEC_ENTRY+5]  = mk(OP_LDINS,  pl_ldins(T_NTTINV[7:0], 4'd1, 1'b1, SC_NONE));
    PROG[DEC_ENTRY+6]  = mk(OP_EXE,    pl_exe(PS_ZERO));
    PROG[DEC_ENTRY+7]  = mk(OP_LDINS,  pl_ldins(T_I2F[7:0],    4'd1, 1'b1, SC_I2F));
    PROG[DEC_ENTRY+8]  = mk(OP_EXE,    pl_exe(PS_ZERO));
    PROG[DEC_ENTRY+9]  = mk(OP_LDINS,  pl_ldins(T_FFTDIT[7:0], 4'd1, 1'b0, SC_NONE));
    PROG[DEC_ENTRY+10] = mk(OP_EXE,    pl_exe(PS_ZERO));
    PROG[DEC_ENTRY+11] = mk(OP_LDINS,  pl_ldins(T_PROJ[7:0],   4'd1, 1'b0, SC_NONE));
    PROG[DEC_ENTRY+12] = mk(OP_EXE,    pl_exe(PS_ZERO));
    PROG[DEC_ENTRY+13] = mk(OP_DMA_OUT,pl_dma(B_FFT, 3'd2, 1'b0, 2'd0, 1'b1));    // out<-upper N of 2N
    PROG[DEC_ENTRY+14] = mk(OP_DONE,   pl_done(1'b0));
  end

  // =====================================================================
  // FSM
  // =====================================================================
  typedef enum logic [4:0] {
    S_IDLE, S_FETCH, S_DECODE,
    S_DMA_REQ,
    S_WR, S_WR_LO,
    S_RD,
    S_EXE_DINA, S_EXE_RST, S_EXE_START, S_EXE_POLL, S_EXE_CLR1, S_EXE_CLR0,
    S_DONE
  } state_e;

  state_e      st;
  logic [7:0]  pc;
  logic [31:0] op_w;             // current macro-op word

  // limb loop
  logic        limb_active;
  logic [3:0]  limb_idx;
  logic [3:0]  limb_cnt;         // = num_limbs for this cmd (1 if decrypt)
  logic [7:0]  limb_base;        // pc of first body word
  logic [7:0]  limb_len;

  // word loop (send64 / receive64)
  logic [LOGN:0] widx;
  logic [LOGN:0] wn;             // word count target
  logic [3:0]    cur_bank;
  logic          cur_ins;        // ins_flag
  logic [1:0]    cur_cid;        // write-data source (C_ZEROS / C_R2 / C_DIN)
  logic [2:0]    cur_ptr;
  logic          cur_off;        // read upper-N offset
  logic [63:0]   wdata;          // data being written this word
  logic [2:0]    rd_wait;

  // INS build (current LDINS)
  logic [63:0]   ins_patched;    // template word with patch applied
  logic [3:0]    ins_len_r;

  // exe
  logic [2:0]    exe_rstc;

  // DMA descriptor (B' 2c-step-2): captured at a DMA op decode, presented to the
  // DMA engine in S_DMA_REQ. The word stream then flows with valid/ready.
  logic          desc_wr_r;
  logic [2:0]    desc_ptr_r;
  logic [3:0]    desc_limb_r;
  assign dma_desc_valid = (st == S_DMA_REQ) && dma_ready;
  assign dma_desc_wr    = desc_wr_r;
  assign dma_desc_ptr   = desc_ptr_r;
  assign dma_desc_limb  = desc_limb_r;
  // pop a DMA_IN word the cycle the walker consumes it (S_WR, not stalled)
  assign dma_rd_pop     = (st == S_WR) && !cur_ins && !cur_sk && (cur_cid == C_DIN) && dma_rd_valid;

  // sk-bank: the walker's resident +sk_ntt store (an SRAM macro in fhe_mem_top
  // for real N; a reg array here). NOT addressed over the 3-bit Aloha bram_sel
  // -- MOVE moves between this local store and a core bank via send64/receive64.
  logic [63:0]   sk_mem [0:N*FHE_L-1];
  logic          cur_sk;          // current op touches sk_mem
  logic [3:0]    mv_limb;         // limb whose sk slice this MOVE uses

  // ---- scale patch (replicates ins_rns / ins_i2f bit math) ----
  // replicate ins_rns / ins_i2f scale-field packing exactly. RNS: sh masked
  // 7-bit, logical shift (scale >= 0). I2F: sh masked 4-bit, ARITHMETIC shift
  // (scale is signed/negative). sm 2-bit, sl 3-bit in both.
  function automatic logic [63:0] scale_bits(input logic [1:0] sc);
    logic signed [31:0] s;
    logic [6:0] sh; logic [1:0] sm; logic [2:0] sl;
    if (sc == SC_I2F) begin
      s  = i2f_scale_dec;
      sh = (s >>> 5) & 7'h0f;          // 4-bit mask
      sm = (s >>> 3) & 2'h3;
      sl =  s        & 3'h7;
    end else begin
      s  = (sc == SC_RNSKG) ? rns_scale_kg : rns_scale_enc;
      sh = (s >> 5) & 7'h7f;           // 7-bit mask
      sm = (s >> 3) & 2'h3;
      sl =  s       & 3'h7;
    end
    scale_bits = (64'(sh) << 33) | (64'(sl) << 30) | (64'(sm) << 3);
  endfunction

  // build the patched INS template word for the current limb
  function automatic logic [63:0] patch_word(input logic [7:0] taddr, input logic patch, input logic [1:0] sc, input logic [3:0] li);
    logic [63:0] w; int unsigned t;
    t = taddr;
    w = tmpl_base(t);
    if (patch) begin
      if (tmpl_use_q(t))   w = w | (64'(neg_qm(lp_qm(li))) << 13);
      if (tmpl_use_rom(t)) w = w | (64'(lp_ms(li)) << 9);
      if (tmpl_use_q(t))   w = w | (64'(lp_k(li))  << 5);
      if (sc != SC_NONE)   w = w | scale_bits(sc);
    end
    patch_word = w;
  endfunction

  // INS buffer word j (build_ins_buf framing for ins_len inner words)
  function automatic logic [63:0] ins_word(input logic [LOGN:0] j, input logic [63:0] inner, input logic [3:0] ilen);
    if (j == 0)                      ins_word = 64'd0;
    else if (j <= {{(LOGN-3){1'b0}}, ilen}) ins_word = inner;          // 1..ilen
    else if (j == {{(LOGN-3){1'b0}}, ilen} + 1) ins_word = W40;        // NOP
    else if (j == {{(LOGN-3){1'b0}}, ilen} + 3) ins_word = 64'h1f;     // terminator
    else                             ins_word = 64'd0;
  endfunction

  localparam int INS_BUFFER_SIZE = 16;

  // control_low constructor (matches send64/receive64 packing)
  function automatic logic [31:0] mk_ctrl(input logic [3:0] bank, input logic grant, input logic ins_flag, input logic wea, input logic [LOGN:0] addr);
    mk_ctrl = (32'(bank[2:0]) << 29) | (32'(grant) << 16) | (32'(ins_flag) << 15) | (32'(wea) << 14) | 32'(addr);
  endfunction

  wire [63:0] dout = {dout_high, dout_low};

  // write-data source for the current send64 word
  function automatic logic [63:0] cur_wr_data();
    if (cur_ins)              cur_wr_data = ins_word(widx, ins_patched, ins_len_r);
    else if (cur_sk)          cur_wr_data = sk_mem[mv_limb*N + widx]; // SK-load
    else if (cur_cid == C_DIN) cur_wr_data = ext_din;       // DMA_IN
    else if (cur_cid == C_R2) cur_wr_data = r2modq[limb_idx];
    else                      cur_wr_data = 64'd0;          // CONST ZEROS
  endfunction

  // ext_sel/ext_idx are combinational so ext_din (comb in the TB on these) is
  // valid the same cycle dina is latched.
  always_comb begin
    ext_sel = 3'd0;
    ext_idx = '0;
    if ((st == S_WR) && !cur_ins && (cur_cid == C_DIN)) begin
      ext_sel = cur_ptr; ext_idx = widx;
    end else if (st == S_RD) begin
      ext_sel = cur_ptr; ext_idx = widx;
    end
  end

  always_ff @(posedge clk or negedge rst_b) begin
    if (!rst_b) begin
      st <= S_IDLE; pc <= 8'd0;
      control_low_word <= 32'd0; control_high_word <= 32'd1; // hold reset
      dina_low <= 32'd0; dina_high <= 32'd0;
      busy <= 1'b0; done <= 1'b0; error <= 1'b0;
      ext_dout_we <= 1'b0; ext_dout <= 64'd0; cur_sk <= 1'b0;
      limb_active <= 1'b0; limb_idx <= 4'd0; limb_cnt <= 4'd1;
      widx <= '0; wn <= '0; rd_wait <= 3'd0;
    end else if (zeroize) begin
      st <= S_IDLE; busy <= 1'b0; done <= 1'b0; error <= 1'b0;
      control_low_word <= 32'd0; control_high_word <= 32'd1;
      ext_dout_we <= 1'b0; limb_active <= 1'b0;
    end else begin
      done <= 1'b0; ext_dout_we <= 1'b0;
      unique case (st)
        // -------------------------------------------------------------
        S_IDLE: begin
          control_high_word <= 32'd0;   // release reset, idle
          control_low_word  <= 32'd0;
          if (cmd_valid && (cmd != FHE_NONE)) begin
            busy        <= 1'b1;
            error       <= 1'b0;
            limb_active <= 1'b0;
            limb_idx    <= 4'd0;
            limb_cnt    <= (cmd == FHE_KEYGEN || cmd == FHE_ENCRYPT)
                             ? ((num_limbs==4'd0)?4'd1:num_limbs) : 4'd1;
            pc <= (cmd == FHE_KEYGEN)  ? KG_ENTRY[7:0] :
                  (cmd == FHE_ENCRYPT) ? ENC_ENTRY[7:0] : DEC_ENTRY[7:0];
            st <= S_FETCH;
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
              op_w     <= PROG[limb_base];
            end else begin
              limb_active <= 1'b0;
              op_w        <= PROG[pc];
            end
          end else begin
            op_w <= PROG[pc];
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
            OP_EXE: begin
              logic [63:0] seed;
              seed = (f_ps(op_w)==PS_KG)  ? keygen_seed :
                     (f_ps(op_w)==PS_A )  ? a_seed      :
                     (f_ps(op_w)==PS_ERR) ? err_seed    : 64'd0;
              dina_low  <= seed[31:0];
              dina_high <= seed[63:32];
              control_low_word <= 32'd0;
              st <= S_EXE_DINA;
            end
            OP_CONST: begin
              cur_bank <= f_bank(op_w); cur_ins <= 1'b0; cur_sk <= 1'b0;
              cur_cid  <= f_cid(op_w);  cur_ptr <= 3'd7; // n/a
              widx <= '0; wn <= (LOGN+1)'(N);
              st <= S_WR;
            end
            OP_DMA_IN: begin
              cur_bank <= f_bank(op_w); cur_ins <= 1'b0; cur_sk <= 1'b0;
              cur_cid  <= C_DIN;        cur_ptr <= f_ptr(op_w);
              widx <= '0; wn <= (LOGN+1)'(N);
              desc_wr_r <= 1'b0; desc_ptr_r <= f_ptr(op_w); desc_limb_r <= limb_idx;
              st <= S_DMA_REQ;          // kick the DMA read, then stream into the core
            end
            OP_LDINS: begin
              cur_bank <= 4'd0; cur_ins <= 1'b1; cur_sk <= 1'b0;
              ins_patched <= patch_word(f_iadr(op_w), f_pat(op_w), f_sc(op_w), limb_idx);
              ins_len_r   <= f_ilen(op_w);
              widx <= '0; wn <= (LOGN+1)'(INS_BUFFER_SIZE);
              st <= S_WR;
            end
            OP_DMA_OUT: begin
              cur_bank <= f_bank(op_w); cur_ptr <= f_ptr(op_w); cur_sk <= 1'b0;
              cur_off  <= f_off(op_w);
              widx <= '0; wn <= (LOGN+1)'(N); rd_wait <= 3'd0;
              control_low_word <= mk_ctrl(f_bank(op_w), 1'b1, 1'b0, 1'b0,
                                          f_off(op_w) ? (LOGN+1)'(N) : '0);
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
                cur_bank <= f_db(op_w); cur_ins <= 1'b0;
                st <= S_WR;
              end else begin
                // SK-store: receive64 from src core bank into sk_mem
                cur_bank <= f_sb(op_w); cur_off <= 1'b0;
                control_low_word <= mk_ctrl(f_sb(op_w), 1'b1, 1'b0, 1'b0, '0);
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
        S_WR: begin
          // DMA_IN read stall: hold until the DMA engine presents the next word.
          if ((cur_cid == C_DIN) && !cur_ins && !cur_sk && !dma_rd_valid) begin
            control_low_word <= 32'd0;
          end else begin
            wdata = cur_wr_data();
            dina_low  <= wdata[31:0];
            dina_high <= wdata[63:32];
            control_low_word <= mk_ctrl(cur_bank, !cur_ins, cur_ins, 1'b1, widx);
            st <= S_WR_LO;
          end
        end
        S_WR_LO: begin
          control_low_word <= mk_ctrl(cur_bank, !cur_ins, cur_ins, 1'b0, widx);
          if (widx == wn - 1) begin
            // last word done -> idle control, advance program
            control_low_word <= 32'd0;
            pc <= pc + 8'd1;
            st <= S_FETCH;
          end else begin
            widx <= widx + 1'b1;
            st <= S_WR;
          end
        end
        // ------------ receive64 word loop (DMA_OUT) -------------------
        S_RD: begin
          if (rd_wait < 3'd2) begin
            rd_wait <= rd_wait + 1'b1;
          end else if (!cur_sk && !dma_wr_ready) begin
            // DMA_OUT write stall: the DMA FIFO is full; hold this beat (rd_wait
            // stays at 2, core read address held) until it can accept the word.
          end else begin
            if (cur_sk) sk_mem[mv_limb*N + widx] <= dout;  // SK-store
            else begin ext_dout <= dout; ext_dout_we <= 1'b1; end // DMA_OUT push
            if (widx == wn - 1) begin
              control_low_word <= 32'd0;
              pc <= pc + 8'd1;
              st <= S_FETCH;
            end else begin
              widx <= widx + 1'b1;
              rd_wait <= 3'd0;
              control_low_word <= mk_ctrl(cur_bank, 1'b1, 1'b0, 1'b0,
                                          cur_off ? ((LOGN+1)'(N) + widx + 1'b1) : (widx + 1'b1));
            end
          end
        end
        // ------------ exe_ins control dance --------------------------
        S_EXE_DINA: begin
          control_high_word <= 32'd1;  // reset core+ISA
          exe_rstc <= 3'd0;
          st <= S_EXE_RST;
        end
        S_EXE_RST: begin
          if (exe_rstc < 3'd2) exe_rstc <= exe_rstc + 1'b1;
          else begin control_high_word <= 32'd2; st <= S_EXE_START; end // start
        end
        S_EXE_START: begin
          control_high_word <= 32'd2;
          st <= S_EXE_POLL;
        end
        S_EXE_POLL: begin
          if (status[0]) begin control_high_word <= 32'd1; st <= S_EXE_CLR1; end
        end
        S_EXE_CLR1: begin
          control_high_word <= 32'd0;
          st <= S_EXE_CLR0;
        end
        S_EXE_CLR0: begin
          // advance program
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
            st          <= S_IDLE;
          end
        end
        default: st <= S_IDLE;
      endcase
    end
  end

endmodule
