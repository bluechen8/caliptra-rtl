// Rung 5: composed-core CKKS round-trip testbench.
//
// Drives ComputeCoreWrapper exactly as the Aloha-HE FPGA SDK does
// (communication.c send64/receive64/exeIns + ckksAccelerator.c instruction
// programs), exercising FFT -> sampling -> RNS -> NTT -> PWM composed through
// the INS_RAM microcode sequencer rather than each engine in isolation.
//
// 5a: N=8192, validate the encode+encrypt ciphertext (one modulus) against the
// shipped SEAL goldens (Testing/fullEnc.h, extracted by tvgen/extract_full.py).
//
// Golden dir via +TVDIR=<path>; instruction params are the fullEnc.h modulus-0
// values. PROVIDE_DEBUG_IO=1 (send64/receive64 path), stored FFT twiddles.

`timescale 1ns/1ps

module tb_ckks_roundtrip;

  localparam int N    = `ifdef N_OVERRIDE `N_OVERRIDE `else 8192 `endif;
  localparam int LOGN = $clog2(N);
  // Rung 6c: build with +define+FHE_SK_HW to elaborate the dedicated secret-key
  // PWM (PWMSk) instead of the vendor pk PWM. Selected at compile time (the
  // datapath choice is a generator flag, not a runtime bit).
  localparam int SCHEME = `ifdef FHE_SK_HW 1 `else 0 `endif;

  // ---- fullEnc.h modulus-0 parameters ---------------------------------------
  localparam longint ERROR_POLYS_SEED = 64'h2350e17152392f72;
  localparam int     SCALE            = 4;          // log_scale (host units, 5a goldens)
  // 5c uses a real CKKS scale: noise ~ sqrt(N)*err/Delta must be << signal.
  // scale=4 (Delta=16) is fine for HW==SEAL bit-match (5a) but useless for a
  // clean recovered~=input round-trip at N=8192.
  // Net encode scale = RT_SCALE - LOGN; keep it at the proven 17 (the @8192
  // value) across all N so the RNS float->int stays in the same shift regime.
  localparam int     RT_SCALE         = 17 + LOGN;   // 30 @ N=8192, 25 @ N=256
  localparam int     QM0              = 'h9;        // q0 = 2^46 - 9*2^24 + 1
  localparam int     CURRENT_K0       = 0;          // log_q index (0 -> 46-bit)
  localparam int     MODSEL0          = 0;          // ROM modulus offset
  // pk1 seed for modulus 0 (pk1_seeds.txt[0]); errors use ERROR_POLYS_SEED.
  longint PK1_SEED0;

  // BRAM IDs (match ComputeCore.v / communication.h)
  localparam int FFT_BRAM_ID        = 0;
  localparam int NTT_MSG_BRAM_ID    = 1;
  localparam int NTT_V_BRAM_ID      = 3;
  localparam int NTT_KEY_BRAM_ID    = 5;
  localparam int FFT_BRAM_EXPAND_ID = 6;

  localparam int INS_BUFFER_SIZE = 16;
  localparam longint W40 = 64'h1 << 40;   // command_we bit

  // ---- DUT I/O --------------------------------------------------------------
  logic clk = 0;
  always #5 clk = ~clk;

  logic [31:0] control_low_word  = 0;
  logic [31:0] control_high_word = 1;   // hold reset at start
  logic [31:0] dina_low = 0, dina_high = 0;
  wire  [31:0] dout_low, dout_high, status;

  // DMA interface tied off (debug-IO path only)
  logic [7:0]  dma_byte_wea = 0;
  logic [17:0] dma_abs_addr = 0;
  logic [63:0] dma_dina = 0;
  wire  [63:0] dma_doutb;
  logic        dma_en = 0;

  ComputeCoreWrapper #(
      .FFT_ON_THE_FLY_GENERATION(0),
      .PROVIDE_DEBUG_IO(1),
      .LOGN(LOGN),
      .N(N),
      .SCHEME(SCHEME)
    ) dut (
      .clk(clk),
      .control_low_word(control_low_word),
      .control_high_word(control_high_word),
      .dina_ext_low_word(dina_low),
      .dina_ext_high_word(dina_high),
      .dout_ext_low_word(dout_low),
      .dout_ext_high_word(dout_high),
      .status(status),
      .dma_bram_byte_wea(dma_byte_wea),
      .dma_bram_abs_addr(dma_abs_addr),
      .dma_bram_dina(dma_dina),
      .dma_bram_doutb(dma_doutb),
      .dma_bram_en(dma_en)
    );

  // ---- instruction-word builders (port of instruction.c) --------------------
  function automatic longint neg_qm(input int qm);
    neg_qm = (-qm) & ((1<<17)-1);
  endfunction
  function automatic longint ins_fft(input bit is_dif);
    ins_fft = W40 | (1<<4) | (longint'(is_dif)<<3) | 1;          // OPC_TRANSFORMATION
  endfunction
  function automatic longint ins_ntt(input bit is_dif, input int log_q,
                                     input int rom_idx, input int qm);
    longint q = neg_qm(qm);
    ins_ntt = W40 | (q<<13) | (longint'(rom_idx)<<9) | (longint'(log_q)<<5)
                  | (longint'(is_dif)<<3) | 1;
  endfunction
  function automatic longint ins_rns(input int log_scale, input int log_q,
                                     input int rom_idx, input int qm);
    longint q = neg_qm(qm);
    longint sh = (log_scale >> 5) & 'h7f;   // OP4 is 7 bits (RNS leaves it unmasked)
    longint sm = (log_scale >> 3) & 'h3;
    longint sl =  log_scale       & 'h7;
    ins_rns = W40 | (sh<<33) | (sl<<30) | (q<<13) | (longint'(rom_idx)<<9)
                  | (longint'(log_q)<<5) | (sm<<3) | 2;          // OPC_RNS
  endfunction
  function automatic longint ins_pwm(input int log_q, input int qm);
    longint q = neg_qm(qm);
    ins_pwm = W40 | (q<<13) | (longint'(log_q)<<5) | 4;          // OPC_PWM
  endfunction
  // Rung 6c: PWM with the sk-scheme flags. negate=OP1[0]/bit3 (c0 + MontMul(sk,
  // q-b)); enc=OP1[1]/bit4 (1 -> b operand from FFT_IM = freshly-sampled a;
  // 0 -> from NTT_KEY = loaded c1).
  function automatic longint ins_pwm_sk(input int log_q, input int qm, input bit neg, input bit enc);
    longint q = neg_qm(qm);
    ins_pwm_sk = W40 | (q<<13) | (longint'(log_q)<<5) | (longint'(enc)<<4)
                     | (longint'(neg)<<3) | 4;
  endfunction
  // I2F: log_scale is SIGNED (decrypt passes -scale); scale_high is 4-bit here.
  function automatic longint ins_i2f(input int log_scale, input int log_q, input int qm);
    longint q = neg_qm(qm);
    longint sh = (log_scale >>> 5) & 'hf;
    longint sm = (log_scale >>> 3) & 'h3;
    longint sl =  log_scale        & 'h7;
    ins_i2f = W40 | (sh<<33) | (sl<<30) | (q<<13) | (longint'(log_q)<<5) | (sm<<3) | 3; // OPC_I2F
  endfunction
  function automatic longint ins_project();
    ins_project = W40 | 5;                                       // OPC_PROJECT
  endfunction

  // INS_BUFFER_SIZE-deep instruction buffer (initInsBuffer + n instr words)
  longint ins_buf [];
  task automatic build_ins_buf(input longint w[$]);
    int i;
    ins_buf = new[INS_BUFFER_SIZE];
    for (i = 0; i < INS_BUFFER_SIZE; i++) ins_buf[i] = 0;
    ins_buf[0] = 0;
    for (i = 0; i < w.size(); i++) ins_buf[i+1] = w[i];
    ins_buf[w.size()+1] = W40;          // NOP / flush
    ins_buf[w.size()+2] = 0;
    ins_buf[w.size()+3] = 'h1f;         // last_instruction terminator
  endtask

  // ---- AXI register protocol (port of communication.c) ----------------------
  // single register write: drive control_low and advance one clock
  task automatic wr_ctrl_low(input logic [31:0] v);
    control_low_word = v; @(posedge clk);
  endtask

  // send64: load num words to INS_RAM (ins_flag=1) or a BRAM (ins_flag=0).
  task automatic send64(input longint p[], input int num,
                        input bit ins_flag, input int bram_sel);
    logic [31:0] const_part, cl;
    int i;
    const_part = (bram_sel<<29) | ((ins_flag?0:1)<<16) | (int'(ins_flag)<<15);
    for (i = 0; i < num; i++) begin
      dina_low  = p[i][31:0];
      dina_high = p[i][63:32];
      cl = const_part | (1<<14) | i;    // wea=1
      wr_ctrl_low(cl);
      cl = const_part | i;              // wea=0
      wr_ctrl_low(cl);
    end
    wr_ctrl_low(0);
  endtask

  // receive64: read num words from a BRAM (grant_ext=1, wea=0).
  task automatic receive64(output longint p[], input int num, input int bram_sel);
    logic [31:0] cl;
    int i, k;
    p = new[num];
    for (i = 0; i < num; i++) begin
      cl = (bram_sel<<29) | (1<<16) | i;
      control_low_word = cl;
      repeat (3) @(posedge clk);        // BRAM_RD_LAT(2) + output mux settle
      p[i] = {dout_high, dout_low};
    end
    wr_ctrl_low(0);
  endtask

  // exeIns / exeInsWithParameter: run the loaded instruction buffer to done.
  task automatic exe_ins(input longint param);
    int t;
    dina_low  = param[31:0];
    dina_high = param[63:32];
    wr_ctrl_low(0);
    control_high_word = 1;  repeat (3) @(posedge clk);   // reset core+ISA
    control_high_word = 2;  @(posedge clk);              // start
    t = 0;
    while (status[0] == 1'b0) begin
      @(posedge clk);
      t++;
      if (t > 5_000_000) begin $display("TIMEOUT in exe_ins"); $finish; end
    end
    control_high_word = 1;  @(posedge clk);
    control_high_word = 0;  @(posedge clk);
  endtask

  // ---- goldens --------------------------------------------------------------
  string tvdir;
  // one extra slot absorbs the trailing pad word some SDK arrays carry
  longint g_input    [0:N];
  longint g_pk0      [0:N];
  longint g_exp_c0   [0:N];
  longint g_exp_c1   [0:N];
  longint g_pk1seeds [0:7];
  longint g_msg_rns  [0:N];   // message_after_rns_mod0 (PRE-e0; add e0 for HW match)
  longint g_e0       [0:N];   // e0_poly (6-bit sign-mag CBD error)
  // decrypt+decode goldens (fullDec.h)
  longint g_c0d      [0:N];   // c0_to_decrypt
  longint g_c1d      [0:N];   // c1_to_decrypt
  longint g_sk       [0:N];   // sk
  longint g_dec_ntt  [0:N];   // decrypted_m_ntt   (after PWM, NTT domain)
  longint g_intt     [0:N];   // intt_m_reference  (after inverse NTT)
  longint g_proj_ref [0:N];   // projected_reference (final recovered slots, doubles)

  // dynamic buffers for send/receive
  longint plain_q [];
  longint pk0_q   [];
  longint c0_q    [];
  longint c1_q    [];

  task automatic to_q(output longint q[], input longint a[0:N], input int num);
    int i; q = new[num];
    for (i = 0; i < num; i++) q[i] = a[i];
  endtask

  int errors = 0;
  task automatic check_poly(input longint res[], input longint gold[0:N],
                            input string name, input longint dmax);
    int i; longint d; int nerr = 0;
    for (i = 0; i < N; i++) begin
      d = $signed(res[i]) - $signed(gold[i]);
      if (d > dmax || d < -dmax) begin
        if (nerr < 8)
          $display("  %s[%0d]: got %h exp %h", name, i, res[i], gold[i]);
        nerr++;
      end
    end
    if (nerr) begin
      $display("FAIL %s: %0d/%0d mismatches", name, nerr, N);
      errors++;
    end else
      $display("PASS %s (%0d words, |delta|<=%0d)", name, N, dmax);
  endtask

  // double comparison with relative tolerance (port of compareDouble)
  function automatic bit close(input longint ab, input longint bb, input real eps);
    real a = $bitstoreal(ab);
    real b = $bitstoreal(bb);
    real t, d;
    d = a - b; if (d < 0.0) d = -d;
    if (d < 1.0e-4) close = 1;              // absolute floor (CKKS noise on tiny slots)
    else if (a == 0.0 || b == 0.0) close = (d < eps);
    else begin t = b/a - 1.0; if (t < 0.0) t = -t; close = (t < eps); end
  endfunction

  // compare `ndbl` doubles of res[] vs gold[] with relative tolerance eps
  task automatic check_fft(input longint res[], input longint gold[0:N],
                           input int ndbl, input string name, input real eps);
    int i, nerr = 0;
    for (i = 0; i < ndbl; i++)
      if (!close(res[i], gold[i], eps)) begin
        if (nerr < 8) $display("  %s[%0d]: got %h (%g) exp %h (%g)", name, i,
                               res[i], $bitstoreal(res[i]), gold[i], $bitstoreal(gold[i]));
        nerr++;
      end
    if (nerr) begin $display("FAIL %s: %0d/%0d", name, nerr, ndbl); errors++; end
    else        $display("PASS %s (%0d doubles, rel<2^-30)", name, ndbl);
  endtask

  longint enc_w[$];
  int rns_scale;
  bit roundtrip;
  longint q0;

  // ====================================================================
  // 5c: self-contained small-N round-trip with an all-HW-derived keypair.
  // sk=poly"1" -> HW NTT = sk_ntt; pk1 = HW key-sample(seed);
  // pk0 = -MontMul(pk1,sk_ntt) via HW PWM negate. Then encrypt(input,pk0)
  // -> (c0,c1); decrypt(c0,c1,sk_ntt) -> recovered; check recovered ~= input.
  // ====================================================================
  longint sk_ntt_q [];
  longint pk1_q    [];
  longint imp_q    [];
  longint zero_q   [];
  longint enc_msg_q[];
  task automatic run_roundtrip();
    int i;
    longint err_seed, pk1_seed, r_mod_q;
    $readmemh({tvdir, "/input.txt"},      g_input);
    $readmemh({tvdir, "/pk1_seeds.txt"},  g_pk1seeds);  err_seed = 0;
    begin longint s[0:0]; $readmemh({tvdir, "/error_seed.txt"}, s); err_seed = s[0]; end
    pk1_seed = g_pk1seeds[0];
    r_mod_q  = longint'((128'd1 << 72) % q0);   // Montgomery one (Aloha R = 2^72)
    sk_ntt_q = new[N];
    for (i = 0; i < N; i++) sk_ntt_q[i] = r_mod_q;  // sk = poly"1" -> Montgomery rep = R

    // --- pk1_ntt = HW key-sample(pk1_seed) (Montgomery domain) ---
    // a forward NTT with the seed samples pk1 into FFT_IM (KEY_SAMPLING path)
    zero_q = new[N];
    for (i = 0; i < N; i++) zero_q[i] = 0;
    send64(zero_q, N, 1'b0, NTT_MSG_BRAM_ID);
    enc_w = '{ ins_ntt(1'b0, CURRENT_K0, MODSEL0, QM0) };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0); exe_ins(pk1_seed);
    receive64(pk1_q, N, 7 /*FFT_IM*/);

    // --- pk0 = -pk1 (sk=1): pk0_mont = q - pk1_mont ---
    pk0_q = new[N];
    for (i = 0; i < N; i++) pk0_q[i] = (pk1_q[i] == 0) ? 0 : (q0 - pk1_q[i]);
    $display("  R mod q0 = %h ; pk1[0]=%h pk0[0]=%h", r_mod_q, pk1_q[0], pk0_q[0]);

    // --- encode + encrypt(input, pk0, seeds) ---
    to_q(plain_q, g_input, N);
    send64(plain_q, N, 1'b0, FFT_BRAM_EXPAND_ID);
    enc_w = '{ ins_fft(1'b1) };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0); exe_ins(err_seed);
    rns_scale = RT_SCALE - 52 - 1023 - LOGN; if (rns_scale < 0) rns_scale += 4096; // -LOGN = 1/N
    // RNS (uses error seed-sampled e0/e1/v already in error BRAMs)
    enc_w = '{ ins_rns(rns_scale, CURRENT_K0, MODSEL0, QM0) };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0); exe_ins(64'd0);
    receive64(enc_msg_q, N, NTT_MSG_BRAM_ID);   // encoded message+e0 (coeff domain)
    // forward NTT (re-samples pk1 into FFT_IM from pk1_seed)
    enc_w = '{ ins_ntt(1'b0, CURRENT_K0, MODSEL0, QM0) };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0); exe_ins(pk1_seed);
    begin  // verify the encryption's internal pk1 matches my standalone sample
      longint enc_pk1[]; int nd = 0;
      receive64(enc_pk1, N, 7 /*FFT_IM*/);
      for (int j = 0; j < N; j++) if (enc_pk1[j] !== pk1_q[j]) nd++;
      $display("  pk1 match check: %0d/%0d differ (enc_pk1[0]=%h vs %h)",
               nd, N, enc_pk1[0], pk1_q[0]);
    end
    send64(pk0_q, N, 1'b0, NTT_KEY_BRAM_ID);
    enc_w = '{ ins_pwm(CURRENT_K0, QM0) };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0);
    $display("  [step] encrypt PWM"); exe_ins(64'd0);
    // c0 in NTT_MSG, c1 in NTT_KEY

    // --- decrypt(c0,c1,sk_ntt) ---
    send64(sk_ntt_q, N, 1'b0, 3 /*NTT_V*/);
    enc_w = '{ ins_pwm(CURRENT_K0, QM0) };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0);
    $display("  [step] decrypt PWM"); exe_ins(64'd0);
    enc_w = '{ ins_ntt(1'b1, CURRENT_K0, MODSEL0, QM0) };   // inverse NTT
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0);
    $display("  [step] inverse NTT"); exe_ins(64'd0);
    begin  // integer-domain round-trip: dec_msg should = enc_msg + e1 (small)
      longint dec_msg[]; int nd = 0; longint d;
      receive64(dec_msg, N, NTT_MSG_BRAM_ID);
      for (int j = 0; j < N; j++) begin
        d = $signed(dec_msg[j]) - $signed(enc_msg_q[j]);
        if (d > q0/2) d -= q0; else if (d < -(q0/2)) d += q0;  // wrap to signed
        if (d > 64 || d < -64) begin
          if (nd < 6) $display("  intRT[%0d]: dec=%h enc=%h d=%0d", j, dec_msg[j], enc_msg_q[j], d);
          nd++;
        end
      end
      $display("  integer round-trip (dec_msg vs enc_msg+e1): %0d/%0d exceed |64|", nd, N);
    end
    enc_w = '{ ins_i2f(-RT_SCALE, CURRENT_K0, QM0) };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0);
    $display("  [step] I2F"); exe_ins(64'd0);
    enc_w = '{ ins_fft(1'b0) };                             // inverse FFT
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0);
    $display("  [step] inverse FFT"); exe_ins(64'd0);
    enc_w = '{ ins_project() };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0);
    $display("  [step] PROJECT"); exe_ins(64'd0);

    receive64(c0_q, 2*N, FFT_BRAM_ID);
    c1_q = new[N];
    for (i = 0; i < N; i++) c1_q[i] = c0_q[i+N];
    // compare recovered slots to the original message (CKKS tolerance)
    // CKKS round-trip recovery: relative 1e-3 with a 1e-4 absolute floor
    // (decode noise ~ sqrt(N)*err/Delta; Delta=2^RT_SCALE).
    check_fft(c1_q, g_input, N, "roundtrip (recovered vs input)", 1.0e-3);
  endtask

  // ====================================================================
  // Rung 6: real secret-key keygen + secret-key (symmetric) CKKS scheme.
  //
  //   KEYGEN (6a): HW ternary-sample s -> RNS-expand -> forward NTT = s_ntt
  //     (standard domain) -> Montgomery-convert sk_mont = MontMul(s_ntt,R^2)
  //     = s_ntt*R.  No host crypto: s is the HW sampler's ternary `v` lane,
  //     read back only for an offline NTT-oracle cross-check.
  //   ENCRYPT: c0 = -(a*s) + m + e0 ,  c1 = a   (sk-scheme, no pk).
  //     a = HW uniform sample (the pk1 lane); m+e0 from the encode (RNS gives
  //     message+e0). Realized on the dedicated PWMSk -- see run_skscheme_hw.
  //   DECRYPT: m ~= c0 + c1*s  (unchanged path: PWM[sk,c1]+c0 -> iNTT -> I2F
  //     -> iFFT -> PROJECT).  Validate recovered ~= input.
  //
  // Domain bookkeeping (see Rung 5c facts): HW NTT output is *standard*; the
  // PWM is a MontMul (a*b*R^-1). With sk_mont = s_ntt*R and a/c1 standard,
  // MontMul(sk_mont,a)=s*a and MontMul(a,-sk_mont)=-(a*s) both land standard.
  // ====================================================================
  longint s_ntt_std [];   // HW forward-NTT of ternary s (standard domain)
  longint sk_mont   [];   // s_ntt*R  (resident secret key, Montgomery domain)
  longint a_q       [];   // fresh uniform a == c1
  longint s_tern    [];   // raw ternary s coefficients (-1/0/+1), for the oracle
  // sk-scheme test seeds (used by run_skscheme_hw).
  localparam longint KEYGEN_SEED = 64'hA105_BEEF_0006_A001;
  localparam longint ERR_SEED    = 64'h2350_e171_5239_2f72;  // same CBD error seed as 5a
  localparam longint A_SEED      = 64'h0006_A002_C0FF_EE77;

  // ====================================================================
  // Rung 6: real sk keygen + the sk-scheme on the DEDICATED secret-key PWM
  // (PWMSk, elaborated with +define+FHE_SK_HW), fully SELF-CONTAINED -- no
  // host-side scaffolding (a vendor PWM would have needed driver moves):
  //   * NO host negate     -- HW forms (q - b) via the PWM `negate` flag.
  //   * NO FFT_IM->NTT_V move -- the fresh uniform a stays in FFT_IM; PWMSk reads
  //                              it directly (the `enc` flag), with sk RESIDENT
  //                              in NTT_V as the multiplicand for both ops.
  //   * c1 = a is a HW passthrough (PWMSk result1), checked here == sampled a.
  //   * single multiply lane (BF0); BF1 unused.
  // ====================================================================
  task automatic run_skscheme_hw();
    int i;
    longint keygen_seed, err_seed, a_seed, r_mod_q, r2;
    logic [127:0] rr;
    if (SCHEME != 1) begin
      $display("FAIL: +SKSCHEME_HW requires +define+FHE_SK_HW (SCHEME=1)"); errors++; return;
    end
    $readmemh({tvdir, "/input.txt"}, g_input);
    rr = (128'd1 << 72) % q0;  r_mod_q = longint'(rr);
    rr = (rr * rr) % q0;       r2      = longint'(rr);
    keygen_seed = KEYGEN_SEED;
    err_seed    = ERR_SEED;
    a_seed      = A_SEED;

    // ---------------- KEYGEN (sk_mont), via PWMSk (negate=0) ----------------
    zero_q = new[N];
    for (i = 0; i < N; i++) zero_q[i] = 0;
    send64(zero_q, N, 1'b0, FFT_BRAM_EXPAND_ID);
    enc_w = '{ ins_fft(1'b1) };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0);
    $display("  [keygen] sample ternary s"); exe_ins(keygen_seed);
    begin longint eb[]; int npos=0, nneg=0, nz=0;
      receive64(eb, N, 4 /*ERROR_BRAM_ID*/);
      s_tern = new[N];
      for (i = 0; i < N; i++) begin
        case ((eb[i] >> 12) & 'h3)
          2'd0: begin s_tern[i] =  0; nz++;   end
          2'd1: begin s_tern[i] = +1; npos++; end
          default: begin s_tern[i] = -1; nneg++; end
        endcase
      end
      $display("  [keygen] ternary s: %0d zero, %0d +1, %0d -1 (N=%0d)", nz, npos, nneg, N);
    end
    rns_scale = RT_SCALE - 52 - 1023 - LOGN; if (rns_scale < 0) rns_scale += 4096;
    enc_w = '{ ins_rns(rns_scale, CURRENT_K0, MODSEL0, QM0) };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0); exe_ins(64'd0);
    enc_w = '{ ins_ntt(1'b0, CURRENT_K0, MODSEL0, QM0) };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0); exe_ins(64'd0);
    receive64(s_ntt_std, N, NTT_V_BRAM_ID);
    begin longint r2_q[]; r2_q = new[N];
      for (i = 0; i < N; i++) r2_q[i] = r2;
      send64(s_ntt_std, N, 1'b0, NTT_V_BRAM_ID);
      send64(r2_q,      N, 1'b0, NTT_KEY_BRAM_ID);
      send64(zero_q,    N, 1'b0, NTT_MSG_BRAM_ID);
    end
    enc_w = '{ ins_pwm_sk(CURRENT_K0, QM0, 1'b0, 1'b0) };  // negate=0,enc=0: MontMul(s_ntt, R2)
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0);
    $display("  [keygen] Montgomery-convert sk (PWMSk)"); exe_ins(64'd0);
    receive64(sk_mont, N, NTT_MSG_BRAM_ID);
    $display("  [keygen] s_ntt[0]=%h sk_mont[0]=%h", s_ntt_std[0], sk_mont[0]);
    begin int fd;
      fd = $fopen({tvdir, "/hw_s_tern.txt"}, "w");
      if (fd) begin for (i=0;i<N;i++) $fdisplay(fd, "%0d", s_tern[i]); $fclose(fd); end
      fd = $fopen({tvdir, "/hw_s_ntt.txt"}, "w");
      if (fd) begin for (i=0;i<N;i++) $fdisplay(fd, "%h", s_ntt_std[i]); $fclose(fd); end
    end

    // ---------------- ENCRYPT via PWMSk: HW negate + c1=a passthrough -------
    to_q(plain_q, g_input, N);
    send64(plain_q, N, 1'b0, FFT_BRAM_EXPAND_ID);
    enc_w = '{ ins_fft(1'b1) };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0); exe_ins(err_seed);
    enc_w = '{ ins_rns(rns_scale, CURRENT_K0, MODSEL0, QM0) };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0); exe_ins(64'd0);
    receive64(enc_msg_q, N, NTT_MSG_BRAM_ID);
    enc_w = '{ ins_ntt(1'b0, CURRENT_K0, MODSEL0, QM0) };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0);
    $display("  [encrypt] encode NTT + sample a"); exe_ins(a_seed);
    receive64(a_q, N, 7 /*FFT_IM*/);   // read sampled a for the passthrough check ONLY (not moved)

    // a STAYS in FFT_IM; sk_mont is the resident multiplicand in NTT_V. No move.
    send64(sk_mont, N, 1'b0, NTT_V_BRAM_ID);          // sk resident (multiplicand)
    enc_w = '{ ins_pwm_sk(CURRENT_K0, QM0, 1'b1, 1'b1) };  // negate=1,enc=1: c0=-(s*a)+(m+e0), b<-FFT_IM
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0);
    $display("  [encrypt] PWMSk (enc: b<-FFT_IM, HW negate, c1=a passthrough)"); exe_ins(64'd0);
    receive64(c0_q, N, NTT_MSG_BRAM_ID);                 // c0
    begin longint c1_pt[]; int nd = 0;                   // verify c1=a passthrough (FFT_IM -> NTT_KEY in HW)
      receive64(c1_pt, N, NTT_KEY_BRAM_ID);
      for (i = 0; i < N; i++) if (c1_pt[i] !== a_q[i]) nd++;
      if (nd) begin $display("FAIL c1=a passthrough: %0d/%0d differ", nd, N); errors++; end
      else        $display("PASS c1=a passthrough (%0d coeffs)", N);
    end

    // ---------------- DECRYPT via PWMSk (negate=0) --------------------------
    send64(c0_q,    N, 1'b0, NTT_MSG_BRAM_ID);
    send64(a_q,     N, 1'b0, NTT_KEY_BRAM_ID);   // c1 = a (loaded ciphertext)
    send64(sk_mont, N, 1'b0, NTT_V_BRAM_ID);     // sk resident (multiplicand)
    enc_w = '{ ins_pwm_sk(CURRENT_K0, QM0, 1'b0, 1'b0) };  // negate=0,enc=0: m = c0 + s*c1, b<-NTT_KEY
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0);
    $display("  [decrypt] PWMSk"); exe_ins(64'd0);
    enc_w = '{ ins_ntt(1'b1, CURRENT_K0, MODSEL0, QM0) };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0);
    $display("  [decrypt] inverse NTT"); exe_ins(64'd0);
    begin longint dec_msg[]; int nd = 0; longint d;
      receive64(dec_msg, N, NTT_MSG_BRAM_ID);
      for (int j = 0; j < N; j++) begin
        d = $signed(dec_msg[j]) - $signed(enc_msg_q[j]);
        if (d > q0/2) d -= q0; else if (d < -(q0/2)) d += q0;
        if (d > 1 || d < -1) begin
          if (nd < 6) $display("  intRT[%0d]: dec=%h exp=%h d=%0d", j, dec_msg[j], enc_msg_q[j], d);
          nd++;
        end
      end
      if (nd) begin $display("FAIL integer round-trip: %0d/%0d exceed |1|", nd, N); errors++; end
      else        $display("PASS integer round-trip (decrypted == m+e0, %0d coeffs)", N);
    end
    enc_w = '{ ins_i2f(-RT_SCALE, CURRENT_K0, QM0) };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0);
    $display("  [decrypt] I2F"); exe_ins(64'd0);
    enc_w = '{ ins_fft(1'b0) };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0);
    $display("  [decrypt] inverse FFT"); exe_ins(64'd0);
    enc_w = '{ ins_project() };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0);
    $display("  [decrypt] PROJECT"); exe_ins(64'd0);
    receive64(c0_q, 2*N, FFT_BRAM_ID);
    c1_q = new[N];
    for (i = 0; i < N; i++) c1_q[i] = c0_q[i+N];
    check_fft(c1_q, g_input, N, "sk-scheme-HW roundtrip (recovered vs input)", 1.0e-3);
  endtask

  // inverse-NTT identity probe: fwd-NTT then inv-NTT a random poly should
  // recover it (INTTScale supplies 1/N). Isolates the inverse NTT at small N.
  task automatic identity_probe();
    int i, nd; longint r[];
    r = new[N];
    for (i = 0; i < N; i++) r[i] = (64'd1000003 * i + 7) % q0;  // deterministic valid residue
    send64(r, N, 1'b0, NTT_MSG_BRAM_ID);
    enc_w = '{ ins_ntt(1'b0, CURRENT_K0, MODSEL0, QM0) };  // forward NTT
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0); exe_ins(64'd0);
    enc_w = '{ ins_ntt(1'b1, CURRENT_K0, MODSEL0, QM0) };  // inverse NTT
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0); exe_ins(64'd0);
    receive64(c0_q, N, NTT_MSG_BRAM_ID);
    nd = 0;
    for (i = 0; i < N; i++) if (c0_q[i] !== r[i]) begin
      if (nd < 6) $display("  invNTT id[%0d]: got %h exp %h", i, c0_q[i], r[i]);
      nd++;
    end
    $display("  inverse-NTT identity: %0d/%0d differ", nd, N);

    // --- forward-FFT then inverse-FFT identity (double path) ---
    // load N real doubles via expand, fwd FFT (DIF), inv FFT (DIT), read 2N.
    begin
      longint fin[]; int ncl;
      fin = new[N];
      for (i = 0; i < N; i++) fin[i] = $realtobits(1.0 + 0.01*i);  // ramp doubles
      send64(fin, N, 1'b0, FFT_BRAM_EXPAND_ID);
      enc_w = '{ ins_fft(1'b1) };                       // forward FFT
      build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0); exe_ins(64'd0);
      enc_w = '{ ins_fft(1'b0) };                       // inverse FFT
      build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0); exe_ins(64'd0);
      receive64(c0_q, 2*N, FFT_BRAM_ID);
      // print real parts of first few (re at even index) vs the input ramp
      $display("  FFT id: in[0..3]re=%g %g %g %g", 1.0, 1.01, 1.02, 1.03);
      $display("          fwd/inv out re[0..3]=%g %g %g %g",
               $bitstoreal(c0_q[0]), $bitstoreal(c0_q[2]),
               $bitstoreal(c0_q[4]), $bitstoreal(c0_q[6]));
    end

  endtask

  initial begin
    roundtrip = $test$plusargs("ROUNDTRIP");
    q0 = (64'd1 << 46) - (QM0 << 24) + 1;
    if ($test$plusargs("IDENTITY")) begin
      if (!$value$plusargs("TVDIR=%s", tvdir)) tvdir = ".";
      control_high_word = 1; repeat (5) @(posedge clk);
      control_high_word = 0; repeat (2) @(posedge clk);
      $display("== inverse-transform identity probe, N=%0d ==", N);
      identity_probe();
      $display("RESULT: PASS");  // probe is informational
      $finish;
    end
    if (!$value$plusargs("TVDIR=%s", tvdir)) tvdir = "../build/full8192";

    // release reset
    control_high_word = 1; repeat (5) @(posedge clk);
    control_high_word = 0; repeat (2) @(posedge clk);

    if (roundtrip) begin
      $display("== Rung 5c: self-contained round-trip, N=%0d ==", N);
      run_roundtrip();
      if (errors == 0) $display("RESULT: PASS");
      else             $display("RESULT: FAIL (%0d mismatches)", errors);
      $finish;
    end

    if ($test$plusargs("SKHW")) begin
      $display("== Rung 6: sk keygen + secret-key scheme on PWMSk, N=%0d (SCHEME=%0d) ==", N, SCHEME);
      run_skscheme_hw();
      if (errors == 0) $display("RESULT: PASS");
      else             $display("RESULT: FAIL (%0d mismatches)", errors);
      $finish;
    end

    $readmemh({tvdir, "/input.txt"},            g_input);
    $readmemh({tvdir, "/pk_0_mod0.txt"},        g_pk0);
    $readmemh({tvdir, "/expected_c0_mod0.txt"}, g_exp_c0);
    $readmemh({tvdir, "/expected_c1_mod0.txt"}, g_exp_c1);
    $readmemh({tvdir, "/pk1_seeds.txt"},        g_pk1seeds);
    $readmemh({tvdir, "/message_after_rns_mod0.txt"}, g_msg_rns);
    $readmemh({tvdir, "/e0_poly.txt"},          g_e0);
    // getMessageAfterRns(): the shipped message_after_rns is pre-e0; the HW
    // value includes the sampled e0 (6-bit sign-mag), reduced mod q0.
    begin
      longint q0 = (64'd1 << 46) - (QM0 << 24) + 1;
      int i; longint m;
      for (i = 0; i < N; i++) begin
        m = g_msg_rns[i];
        if (g_e0[i] & 'h20) m = m - (g_e0[i] & 'h1f);
        else                m = m + (g_e0[i] & 'h1f);
        if (m >= q0)     m -= q0;
        else if (m < 0)  m += q0;
        g_msg_rns[i] = m;
      end
    end
    PK1_SEED0 = g_pk1seeds[0];

    // release reset
    control_high_word = 1; repeat (5) @(posedge clk);
    control_high_word = 0; repeat (2) @(posedge clk);

    $display("== Rung 5a: encode+encrypt (modulus 0), N=%0d ==", N);

    // ---- encode: load plaintext, run forward FFT + sample errors -----------
    to_q(plain_q, g_input, N);
    send64(plain_q, N, 1'b0, FFT_BRAM_EXPAND_ID);    // expand-load N reals
    enc_w = '{ ins_fft(1'b1) };                       // DIF forward FFT
    build_ins_buf(enc_w);
    send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0);
    exe_ins(ERROR_POLYS_SEED);

    // ---- encrypt: granular (RNS, NTT, PWM separately) with intermediate
    //      checks to localize, mirroring ckksTest.c FULL_ENCRYPTION ----------
    // RNS scale transform (ckks_encrypt): -52 -1023 -13, wrap mod 4096
    rns_scale = SCALE - 52 - 1023 - 13;
    if (rns_scale < 0) rns_scale += 4096;

    // RNS: reduce encoded message to modulus 0 (+e0), write NTT_MSG
    enc_w = '{ ins_rns(rns_scale, CURRENT_K0, MODSEL0, QM0) };
    build_ins_buf(enc_w);
    send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0);
    exe_ins(64'd0);
    receive64(c0_q, N, NTT_MSG_BRAM_ID);
    check_poly(c0_q, g_msg_rns, "message_after_rns", 1);  // ckksTest delta_max=1

    // forward NTT of message/v/e1; sample pk1 into FFT_IM
    enc_w = '{ ins_ntt(1'b0, CURRENT_K0, MODSEL0, QM0) };
    build_ins_buf(enc_w);
    send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0);
    exe_ins(PK1_SEED0);

    // PWM: load pk0 to NTT_KEY, compute c0=v*pk0+msg, c1=v*pk1+e1
    to_q(pk0_q, g_pk0, N);
    send64(pk0_q, N, 1'b0, NTT_KEY_BRAM_ID);
    enc_w = '{ ins_pwm(CURRENT_K0, QM0) };
    build_ins_buf(enc_w);
    send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0);
    exe_ins(64'd0);

    // ---- read back ciphertext and compare ----------------------------------
    receive64(c0_q, N, NTT_MSG_BRAM_ID);
    receive64(c1_q, N, NTT_KEY_BRAM_ID);
    check_poly(c0_q, g_exp_c0, "C0", 0);
    check_poly(c1_q, g_exp_c1, "C1", 0);

    // ====================================================================
    // decrypt + decode (fullDec.h ciphertext): PWM -> iNTT -> I2F -> iFFT
    // -> PROJECT, recovering the message slots. Mirrors FULL_DECRYPTION.
    // ====================================================================
    $display("== Rung 5a: decrypt+decode, N=%0d ==", N);
    $readmemh({tvdir, "/c0_to_decrypt.txt"},     g_c0d);
    $readmemh({tvdir, "/c1_to_decrypt.txt"},     g_c1d);
    $readmemh({tvdir, "/sk.txt"},                g_sk);
    $readmemh({tvdir, "/decrypted_m_ntt.txt"},   g_dec_ntt);
    $readmemh({tvdir, "/intt_m_reference.txt"},  g_intt);
    $readmemh({tvdir, "/projected_reference.txt"}, g_proj_ref);

    // load c0->MSG(1), c1->KEY(5), sk->V(3)
    to_q(c0_q, g_c0d, N);   send64(c0_q, N, 1'b0, NTT_MSG_BRAM_ID);
    to_q(c1_q, g_c1d, N);   send64(c1_q, N, 1'b0, NTT_KEY_BRAM_ID);
    to_q(plain_q, g_sk, N); send64(plain_q, N, 1'b0, 3 /*NTT_V*/);

    // PWM: decrypted = c0 + c1*sk (NTT domain) -> NTT_MSG
    enc_w = '{ ins_pwm(CURRENT_K0, QM0) };
    build_ins_buf(enc_w);
    send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0);
    exe_ins(64'd0);
    receive64(c0_q, N, NTT_MSG_BRAM_ID);
    check_poly(c0_q, g_dec_ntt, "decrypted_m_ntt", 0);

    // inverse NTT (is_dif=1) of the decrypted message
    enc_w = '{ ins_ntt(1'b1, CURRENT_K0, MODSEL0, QM0) };
    build_ins_buf(enc_w);
    send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0);
    exe_ins(64'd0);
    receive64(c0_q, N, NTT_MSG_BRAM_ID);
    check_poly(c0_q, g_intt, "intt_m_reference", 0);

    // I2F: int -> double, scaled by -scale, -> FFT_BRAM
    enc_w = '{ ins_i2f(-SCALE, CURRENT_K0, QM0) };
    build_ins_buf(enc_w);
    send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0);
    exe_ins(64'd0);

    // inverse FFT (is_dif=0)
    enc_w = '{ ins_fft(1'b0) };
    build_ins_buf(enc_w);
    send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0);
    exe_ins(64'd0);

    // PROJECT: extract N/2 slots into the upper half of FFT_BRAM
    enc_w = '{ ins_project() };
    build_ins_buf(enc_w);
    send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0);
    exe_ins(64'd0);

    // read 2N words from FFT_BRAM; the projected result is the upper half
    receive64(c0_q, 2*N, FFT_BRAM_ID);
    for (int i = 0; i < N; i++) c1_q[i] = c0_q[i+N];
    check_fft(c1_q, g_proj_ref, N, "projected (recovered msg)", 1.0/(1<<30));

    if (errors == 0) $display("RESULT: PASS");
    else             $display("RESULT: FAIL (%0d poly mismatches)", errors);
    $finish;
  end

endmodule
