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
  // Rung 7b-rescale: the second RNS limb q1 = 2^47 - 1*2^24 + 1 = 0x7fffff000001
  // (moduli[1] in GenerateConstantsROM.py; k=1, qm=1, ROM offset 1).
  localparam int     QM1              = 'h1;
  localparam int     CURRENT_K1       = 1;
  localparam int     MODSEL1          = 1;
  longint q1v;                                      // q1 value (set in initial)
  // 2-limb pt*ct uses a LARGER net scale than single-modulus: the product lives
  // in {q0,q1} (~2^93), so net 2^34 is fine, and after rescale (/q1) the q0 scale
  // is ~2^(2*34-47)=2^21 -- ample precision at both N.
  localparam int     RESC_NET         = 34;
  localparam int     LOG2_Q1          = 47;         // round(log2(q1)); rescale residual 2^47/q1 ~ 1+1e-7
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

  // absolute-error floor for close() on tiny slots; raised for pt*ct products
  // (combined per-operand noise on a degree-1 product). Default = round-trip value.
  real fft_abs_floor = 1.0e-4;
  // double comparison with relative tolerance (port of compareDouble)
  function automatic bit close(input longint ab, input longint bb, input real eps);
    real a = $bitstoreal(ab);
    real b = $bitstoreal(bb);
    real t, d;
    d = a - b; if (d < 0.0) d = -d;
    if (d < fft_abs_floor) close = 1;       // absolute floor (CKKS noise on tiny slots)
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
  // Rung 7 cosim: a second ciphertext needs an independent fresh (a, e0).
  localparam longint A_SEED2     = 64'h0006_A003_FEED_FACE;
  localparam longint ERR_SEED2   = 64'h7331_2350_e171_5239;
  // Rung 7b pt*ct uses a LOWER encode net-scale: the product doubles the scale
  // (Delta -> Delta^2) and the unnormalized encode-FFT inflates coeffs by ~sqrt(N),
  // so net 2^17 (the round-trip value) overflows q0. net=12 fits @N=256 but the
  // MAX of N=8192 product coeffs still grazes q0/2 (extreme-value ~4 sigma above
  // typical -> a few wrap -> corrupts the decode). net=10 gives ~4 bits margin at
  // both N; decode noise ~ err/(2^net*sqrt(N)) stays ~1e-4 (the 1/sqrt(N) helps).
  localparam int     MUL_NET     = 10;

  // ---- Rung 7 cosim (client<->server) state ---------------------------------
  longint g_input2  [0:N];   // second plaintext m2 (input2.txt)
  longint g_sum_c0  [0:N];   // server-returned sum ciphertext c0 (sum_c0.txt)
  longint g_sum_c1  [0:N];   // server-returned sum ciphertext c1 (sum_c1.txt)
  longint g_sum_exp [0:N];   // expected recovered slots = m1 + m2 (doubles)
  int     cosim_net;         // encode net-scale exponent (2^cosim_net); 7a add=RT_SCALE-LOGN
  longint ck_sk_mont [];     // resident sk (Montgomery), from cosim_keygen
  longint ck_s_tern  [];     // sampled ternary s (for the keygen cross-check)
  longint ck_s_ntt   [];     // HW forward-NTT of s (standard domain)
  longint reco_q     [];     // recovered slots out of cosim_decrypt
  // Rung 7b-rescale 2-limb state (limb0=q0, limb1=q1)
  longint ck_sk_mont1[];     // sk_mont @ q1
  longint ck_s_ntt1  [];     // HW forward-NTT of s @ q1
  longint c0_l1 [];          // ciphertext c0 @ q1
  longint c1_l1 [];          // ciphertext c1 @ q1
  longint pt_q0 [];          // plaintext pt(m2) @ q0
  longint pt_q1 [];          // plaintext pt(m2) @ q1

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

  // ====================================================================
  // Rung 7 cosim: streamlined sk-scheme helpers (PWMSk path, SCHEME=1).
  // Extracted from run_skscheme_hw so phase 1 (+ENCRYPT) and phase 2
  // (+DECRYPT) can keygen/encrypt/decrypt across two separate sim runs.
  // sk (the secret) NEVER touches disk -- phase 2 re-derives it from the
  // same KEYGEN_SEED; only the *public* ciphertext polys are dumped.
  // ====================================================================
  task automatic dump_hex(input string fname, input longint p[], input int num);
    int fd, i;
    fd = $fopen({tvdir, "/", fname}, "w");
    if (fd == 0) begin $display("FAIL: cannot open %s for write", fname); errors++; return; end
    for (i = 0; i < num; i++) $fdisplay(fd, "%h", p[i]);
    $fclose(fd);
  endtask

  // KEYGEN: ternary s -> RNS-expand -> fwd NTT (s_ntt, standard) ->
  // Montgomery-convert sk_mont = MontMul(s_ntt, R^2). Leaves ck_sk_mont set.
  task automatic cosim_keygen(input longint keygen_seed);
    int i; longint r2; logic [127:0] rr;
    rr = (128'd1 << 72) % q0; rr = (rr * rr) % q0; r2 = longint'(rr);
    rns_scale = RT_SCALE - 52 - 1023 - LOGN; if (rns_scale < 0) rns_scale += 4096;
    zero_q = new[N]; for (i = 0; i < N; i++) zero_q[i] = 0;
    send64(zero_q, N, 1'b0, FFT_BRAM_EXPAND_ID);
    enc_w = '{ ins_fft(1'b1) };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0);
    exe_ins(keygen_seed);                       // sample ternary s into the v lane
    begin longint eb[]; int npos=0, nneg=0, nz=0;
      receive64(eb, N, 4 /*ERROR_BRAM_ID*/);
      ck_s_tern = new[N];
      for (i = 0; i < N; i++) case ((eb[i] >> 12) & 'h3)
        2'd0: begin ck_s_tern[i] =  0; nz++;   end
        2'd1: begin ck_s_tern[i] = +1; npos++; end
        default: begin ck_s_tern[i] = -1; nneg++; end
      endcase
      $display("  [keygen] ternary s: %0d zero, %0d +1, %0d -1 (N=%0d)", nz, npos, nneg, N);
    end
    enc_w = '{ ins_rns(rns_scale, CURRENT_K0, MODSEL0, QM0) };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0); exe_ins(64'd0);
    enc_w = '{ ins_ntt(1'b0, CURRENT_K0, MODSEL0, QM0) };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0); exe_ins(64'd0);
    receive64(ck_s_ntt, N, NTT_V_BRAM_ID);
    begin longint r2_q[]; r2_q = new[N];
      for (i = 0; i < N; i++) r2_q[i] = r2;
      send64(ck_s_ntt, N, 1'b0, NTT_V_BRAM_ID);
      send64(r2_q,     N, 1'b0, NTT_KEY_BRAM_ID);
      send64(zero_q,   N, 1'b0, NTT_MSG_BRAM_ID);
    end
    enc_w = '{ ins_pwm_sk(CURRENT_K0, QM0, 1'b0, 1'b0) };  // sk_mont = MontMul(s_ntt, R^2)
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0); exe_ins(64'd0);
    receive64(ck_sk_mont, N, NTT_MSG_BRAM_ID);
    $display("  [keygen] s_ntt[0]=%h sk_mont[0]=%h", ck_s_ntt[0], ck_sk_mont[0]);
  endtask

  // ENCRYPT (sk-scheme): c0 = -(a*s) + m + e0, c1 = a.  ck_sk_mont must be set.
  task automatic cosim_encrypt(input longint msg[0:N], input longint a_seed,
                               input longint err_seed, output longint c0o[], output longint c1o[]);
    int i; longint a_chk[];
    rns_scale = cosim_net - 52 - 1023; if (rns_scale < 0) rns_scale += 4096;
    to_q(plain_q, msg, N);
    send64(plain_q, N, 1'b0, FFT_BRAM_EXPAND_ID);
    enc_w = '{ ins_fft(1'b1) };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0); exe_ins(err_seed);
    enc_w = '{ ins_rns(rns_scale, CURRENT_K0, MODSEL0, QM0) };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0); exe_ins(64'd0);
    enc_w = '{ ins_ntt(1'b0, CURRENT_K0, MODSEL0, QM0) };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0);
    exe_ins(a_seed);                            // sample fresh uniform a into FFT_IM
    receive64(a_chk, N, 7 /*FFT_IM*/);          // for the c1=a passthrough check only
    send64(ck_sk_mont, N, 1'b0, NTT_V_BRAM_ID); // sk resident multiplicand
    enc_w = '{ ins_pwm_sk(CURRENT_K0, QM0, 1'b1, 1'b1) };  // negate=1, enc=1: b <- FFT_IM(a)
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0); exe_ins(64'd0);
    receive64(c0o, N, NTT_MSG_BRAM_ID);
    receive64(c1o, N, NTT_KEY_BRAM_ID);
    begin int nd = 0;
      for (i = 0; i < N; i++) if (c1o[i] !== a_chk[i]) nd++;
      if (nd) begin $display("FAIL c1=a passthrough: %0d/%0d differ", nd, N); errors++; end
      else        $display("PASS c1=a passthrough (%0d coeffs)", N);
    end
  endtask

  // DECRYPT (sk-scheme): m ~= c0 + c1*s -> iNTT -> I2F -> iFFT -> PROJECT.
  // i2f_scale is the (negative) log2 decode scale: -RT_SCALE for a fresh ct
  // (scale Delta), a larger magnitude for a pt*ct product (scale Delta^2).
  task automatic cosim_decrypt(input longint c0i[], input longint c1i[], input int i2f_scale,
                               output longint reco[]);
    int i;
    send64(c0i, N, 1'b0, NTT_MSG_BRAM_ID);
    send64(c1i, N, 1'b0, NTT_KEY_BRAM_ID);      // c1 = a (loaded ciphertext)
    send64(ck_sk_mont, N, 1'b0, NTT_V_BRAM_ID); // sk resident multiplicand
    enc_w = '{ ins_pwm_sk(CURRENT_K0, QM0, 1'b0, 1'b0) };  // negate=0, enc=0: m = c0 + s*c1
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0); exe_ins(64'd0);
    enc_w = '{ ins_ntt(1'b1, CURRENT_K0, MODSEL0, QM0) };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0); exe_ins(64'd0);
    enc_w = '{ ins_i2f(i2f_scale, CURRENT_K0, QM0) };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0); exe_ins(64'd0);
    enc_w = '{ ins_fft(1'b0) };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0); exe_ins(64'd0);
    enc_w = '{ ins_project() };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0); exe_ins(64'd0);
    begin longint tmp[]; receive64(tmp, 2*N, FFT_BRAM_ID);
      reco = new[N]; for (i = 0; i < N; i++) reco[i] = tmp[i+N];
    end
  endtask

  // ENCODE-only: m2 -> pt(m2) in the NTT/eval domain (standard, mod q0), the
  // *plaintext* the server multiplies the ciphertext by. Same FFT->RNS->NTT as
  // encrypt's message path, but stops before the key/PWM (so no -(a*s) term).
  // A tiny e0 rides along (sampled during the FFT) -- negligible vs Delta.
  task automatic cosim_encode_pt(input longint msg[0:N], input longint seed, output longint pt[]);
    rns_scale = cosim_net - 52 - 1023; if (rns_scale < 0) rns_scale += 4096;
    to_q(plain_q, msg, N);
    send64(plain_q, N, 1'b0, FFT_BRAM_EXPAND_ID);
    enc_w = '{ ins_fft(1'b1) };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0); exe_ins(seed);
    enc_w = '{ ins_rns(rns_scale, CURRENT_K0, MODSEL0, QM0) };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0); exe_ins(64'd0);
    enc_w = '{ ins_ntt(1'b0, CURRENT_K0, MODSEL0, QM0) };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0); exe_ins(64'd0);
    receive64(pt, N, NTT_MSG_BRAM_ID);          // eval-domain encoded m2
  endtask

  // ====================================================================
  // Rung 7b-rescale: 2-limb (q0,q1) keygen / encrypt / encode for a genuine
  // RNS ciphertext the server can pt*ct + RESCALE. The SAME integer polys
  // (s, a, e0, m) are reduced to both moduli: s sampled once -> NTT@q0 & @q1;
  // a/e0/m from a single FFT, RNS'd to each limb (the FFT + error banks persist
  // across the two limb passes, so e0/m are identical integers). a's RNS
  // consistency (a<q0<q1 => a@q1==a@q0) is checked, not assumed.
  // ====================================================================
  // One keygen limb: ternary v (already sampled, resident in the error bank) ->
  // RNS@qi -> fwd NTT@qi = s_ntt (standard) -> Montgomery-convert sk_mont.
  task automatic kg_limb(input int ck, input int ms, input int qm, input longint qv,
                         output longint skm[], output longint sntt[]);
    int i; longint r2; logic [127:0] rr;
    rr = (128'd1 << 72) % qv; rr = (rr*rr) % qv; r2 = longint'(rr);
    enc_w = '{ ins_rns(rns_scale, ck, ms, qm) };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0); exe_ins(64'd0);
    enc_w = '{ ins_ntt(1'b0, ck, ms, qm) };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0); exe_ins(64'd0);
    receive64(sntt, N, NTT_V_BRAM_ID);
    begin longint r2_q[]; r2_q = new[N];
      for (i = 0; i < N; i++) r2_q[i] = r2;
      send64(sntt,  N, 1'b0, NTT_V_BRAM_ID);
      send64(r2_q,  N, 1'b0, NTT_KEY_BRAM_ID);
      send64(zero_q, N, 1'b0, NTT_MSG_BRAM_ID);
    end
    enc_w = '{ ins_pwm_sk(ck, qm, 1'b0, 1'b0) };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0); exe_ins(64'd0);
    receive64(skm, N, NTT_MSG_BRAM_ID);
  endtask

  task automatic cosim_keygen2(input longint keygen_seed);
    int i;
    cosim_net = RESC_NET;
    rns_scale = cosim_net - 52 - 1023; if (rns_scale < 0) rns_scale += 4096;
    zero_q = new[N]; for (i = 0; i < N; i++) zero_q[i] = 0;
    send64(zero_q, N, 1'b0, FFT_BRAM_EXPAND_ID);
    enc_w = '{ ins_fft(1'b1) };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0);
    $display("  [keygen2] sample ternary s"); exe_ins(keygen_seed);
    begin longint eb[]; int npos=0, nneg=0, nz=0;
      receive64(eb, N, 4 /*ERROR_BRAM_ID*/);
      ck_s_tern = new[N];
      for (i = 0; i < N; i++) case ((eb[i] >> 12) & 'h3)
        2'd0: begin ck_s_tern[i] =  0; nz++;   end
        2'd1: begin ck_s_tern[i] = +1; npos++; end
        default: begin ck_s_tern[i] = -1; nneg++; end
      endcase
      $display("  [keygen2] ternary s: %0d zero, %0d +1, %0d -1", nz, npos, nneg);
    end
    kg_limb(CURRENT_K0, MODSEL0, QM0, q0,  ck_sk_mont,  ck_s_ntt);   // limb0 @q0
    kg_limb(CURRENT_K1, MODSEL1, QM1, q1v, ck_sk_mont1, ck_s_ntt1);  // limb1 @q1
    $display("  [keygen2] sk_mont@q0[0]=%h  sk_mont@q1[0]=%h", ck_sk_mont[0], ck_sk_mont1[0]);
  endtask

  // 2-limb sk-encrypt: c0 = -(a*s)+m+e0, c1 = a, at both q0 and q1. FFT once
  // (samples e0); per-limb RNS/NTT/PWM. a is sampled at each limb with the SAME
  // seed -- checked equal (a<q0<q1 => RNS-consistent) so the ct is a valid 2-limb
  // RNS object. Outputs c0_q/c1_q (@q0) + c0_l1/c1_l1 (@q1).
  task automatic cosim_encrypt2(input longint msg[0:N], input longint a_seed, input longint err_seed);
    int i; longint a0[], a1[];
    cosim_net = RESC_NET;
    rns_scale = cosim_net - 52 - 1023; if (rns_scale < 0) rns_scale += 4096;
    to_q(plain_q, msg, N);
    send64(plain_q, N, 1'b0, FFT_BRAM_EXPAND_ID);
    enc_w = '{ ins_fft(1'b1) };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0); exe_ins(err_seed);
    // ---- limb 0 @q0 ----
    enc_w = '{ ins_rns(rns_scale, CURRENT_K0, MODSEL0, QM0) };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0); exe_ins(64'd0);
    enc_w = '{ ins_ntt(1'b0, CURRENT_K0, MODSEL0, QM0) };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0); exe_ins(a_seed);
    receive64(a0, N, 7 /*FFT_IM*/);
    send64(ck_sk_mont, N, 1'b0, NTT_V_BRAM_ID);
    enc_w = '{ ins_pwm_sk(CURRENT_K0, QM0, 1'b1, 1'b1) };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0); exe_ins(64'd0);
    receive64(c0_q, N, NTT_MSG_BRAM_ID);
    receive64(c1_q, N, NTT_KEY_BRAM_ID);
    // ---- limb 1 @q1 (reuse the FFT + e0 banks; same a_seed) ----
    enc_w = '{ ins_rns(rns_scale, CURRENT_K1, MODSEL1, QM1) };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0); exe_ins(64'd0);
    enc_w = '{ ins_ntt(1'b0, CURRENT_K1, MODSEL1, QM1) };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0); exe_ins(a_seed);
    receive64(a1, N, 7 /*FFT_IM*/);
    send64(ck_sk_mont1, N, 1'b0, NTT_V_BRAM_ID);
    enc_w = '{ ins_pwm_sk(CURRENT_K1, QM1, 1'b1, 1'b1) };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0); exe_ins(64'd0);
    receive64(c0_l1, N, NTT_MSG_BRAM_ID);
    receive64(c1_l1, N, NTT_KEY_BRAM_ID);
    // INFO: a@q1 vs a@q0 (same seed). They need NOT match -- a per-limb `a` is
    // fine because `a` CANCELS in decryption (c0@qi + s*c1@qi = m+e0 holds at each
    // limb independently, since m/e0/s ARE RNS-consistent), and rescale is linear
    // so rescale(c0)+s*rescale(c1) ~ rescale(c0+s*c1) = rescale(pt*m). Only the
    // *message* must be RNS-consistent across limbs, not the ciphertext randomness.
    begin int nd = 0; for (i = 0; i < N; i++) if (c1_l1[i] !== c1_q[i]) nd++;
      $display("  [enc2] a@q1 vs a@q0 (same seed): %0d/%0d differ (benign -- a cancels in decrypt)", nd, N);
    end
  endtask

  // 2-limb encode of pt(m2): same FFT once, RNS/NTT per limb -> pt_q0, pt_q1.
  task automatic cosim_encode_pt2(input longint msg[0:N], input longint seed);
    cosim_net = RESC_NET;
    rns_scale = cosim_net - 52 - 1023; if (rns_scale < 0) rns_scale += 4096;
    to_q(plain_q, msg, N);
    send64(plain_q, N, 1'b0, FFT_BRAM_EXPAND_ID);
    enc_w = '{ ins_fft(1'b1) };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0); exe_ins(seed);
    enc_w = '{ ins_rns(rns_scale, CURRENT_K0, MODSEL0, QM0) };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0); exe_ins(64'd0);
    enc_w = '{ ins_ntt(1'b0, CURRENT_K0, MODSEL0, QM0) };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0); exe_ins(64'd0);
    receive64(pt_q0, N, NTT_MSG_BRAM_ID);
    enc_w = '{ ins_rns(rns_scale, CURRENT_K1, MODSEL1, QM1) };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0); exe_ins(64'd0);
    enc_w = '{ ins_ntt(1'b0, CURRENT_K1, MODSEL1, QM1) };
    build_ins_buf(enc_w); send64(ins_buf, INS_BUFFER_SIZE, 1'b1, 0); exe_ins(64'd0);
    receive64(pt_q1, N, NTT_MSG_BRAM_ID);
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
    q1v = (64'd1 << 47) - (QM1 << 24) + 1;   // 0x7fffff000001
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

    // ---- Rung 7a cosim phase 1: keygen + encrypt m1, m2 (dump public cts) ----
    if ($test$plusargs("ENCRYPT")) begin
      $display("== Rung 7a phase 1: keygen + encrypt m1,m2, N=%0d (SCHEME=%0d) ==", N, SCHEME);
      if (SCHEME != 1) begin
        $display("FAIL: +ENCRYPT requires +define+FHE_SK_HW (SCHEME=1)"); errors++;
      end else begin
        cosim_net = RT_SCALE - LOGN;   // 7a add: scale Delta (round-trip value)
        $readmemh({tvdir, "/input.txt"},  g_input);
        $readmemh({tvdir, "/input2.txt"}, g_input2);
        cosim_keygen(KEYGEN_SEED);
        // dump the keygen cross-check material (s never leaves as the resident key;
        // these are only for the offline NTT-oracle check, identical to Rung 6).
        // hw_s_tern is DECIMAL (-1/0/+1) per check_keygen.py; hw_s_ntt is hex.
        begin int fd;
          fd = $fopen({tvdir, "/hw_s_tern.txt"}, "w");
          if (fd) begin for (int j = 0; j < N; j++) $fdisplay(fd, "%0d", ck_s_tern[j]); $fclose(fd); end
        end
        dump_hex("hw_s_ntt.txt", ck_s_ntt, N);
        cosim_encrypt(g_input,  A_SEED,  ERR_SEED,  c0_q, c1_q);
        dump_hex("ct1_c0.txt", c0_q, N); dump_hex("ct1_c1.txt", c1_q, N);
        cosim_encrypt(g_input2, A_SEED2, ERR_SEED2, c0_q, c1_q);
        dump_hex("ct2_c0.txt", c0_q, N); dump_hex("ct2_c1.txt", c1_q, N);
        $display("  [phase1] dumped ct1_{c0,c1}.txt, ct2_{c0,c1}.txt to %s", tvdir);
      end
      if (errors == 0) $display("RESULT: PASS");
      else             $display("RESULT: FAIL (%0d mismatches)", errors);
      $finish;
    end

    // ---- Rung 7a cosim phase 2: load server sum ct, decrypt, check ~ m1+m2 ----
    if ($test$plusargs("DECRYPT")) begin
      $display("== Rung 7a phase 2: decrypt server sum ct, N=%0d (SCHEME=%0d) ==", N, SCHEME);
      if (SCHEME != 1) begin
        $display("FAIL: +DECRYPT requires +define+FHE_SK_HW (SCHEME=1)"); errors++;
      end else begin
        int i;
        cosim_net = RT_SCALE - LOGN;   // 7a add: scale Delta (round-trip value)
        $readmemh({tvdir, "/input.txt"},  g_input);
        $readmemh({tvdir, "/input2.txt"}, g_input2);
        $readmemh({tvdir, "/sum_c0.txt"}, g_sum_c0);
        $readmemh({tvdir, "/sum_c1.txt"}, g_sum_c1);
        cosim_keygen(KEYGEN_SEED);                 // re-derive sk (same seed; never on disk)
        to_q(c0_q, g_sum_c0, N); to_q(c1_q, g_sum_c1, N);
        cosim_decrypt(c0_q, c1_q, -RT_SCALE, reco_q);  // ct+ct stays at scale Delta
        for (i = 0; i < N; i++)
          g_sum_exp[i] = $realtobits($bitstoreal(g_input[i]) + $bitstoreal(g_input2[i]));
        check_fft(reco_q, g_sum_exp, N, "cosim ct+ct (recovered vs m1+m2)", 1.0e-3);
      end
      if (errors == 0) $display("RESULT: PASS");
      else             $display("RESULT: FAIL (%0d mismatches)", errors);
      $finish;
    end

    // ---- Rung 7b cosim phase 1: keygen + encrypt m1 + encode m2->pt ----------
    if ($test$plusargs("PMULENC")) begin
      $display("== Rung 7b phase 1: keygen + encrypt m1 + encode pt(m2), N=%0d (SCHEME=%0d) ==", N, SCHEME);
      if (SCHEME != 1) begin
        $display("FAIL: +PMULENC requires +define+FHE_SK_HW (SCHEME=1)"); errors++;
      end else begin
        cosim_net = MUL_NET;           // 7b pt*ct: lower scale so the product fits q0
        $readmemh({tvdir, "/input.txt"},  g_input);
        $readmemh({tvdir, "/input2.txt"}, g_input2);
        cosim_keygen(KEYGEN_SEED);
        begin int fd;
          fd = $fopen({tvdir, "/hw_s_tern.txt"}, "w");
          if (fd) begin for (int j = 0; j < N; j++) $fdisplay(fd, "%0d", ck_s_tern[j]); $fclose(fd); end
        end
        dump_hex("hw_s_ntt.txt", ck_s_ntt, N);
        cosim_encrypt(g_input, A_SEED, ERR_SEED, c0_q, c1_q);  // ct = Enc(m1)
        dump_hex("ct_c0.txt", c0_q, N); dump_hex("ct_c1.txt", c1_q, N);
        cosim_encode_pt(g_input2, ERR_SEED2, reco_q);          // pt = Encode(m2)
        dump_hex("pt.txt", reco_q, N);
        $display("  [phase1] dumped ct_{c0,c1}.txt + pt.txt to %s", tvdir);
      end
      if (errors == 0) $display("RESULT: PASS");
      else             $display("RESULT: FAIL (%0d mismatches)", errors);
      $finish;
    end

    // ---- Rung 7b cosim phase 2: load pt*ct product, decrypt, check ~ m1(.)m2 -
    if ($test$plusargs("PMULDEC")) begin
      $display("== Rung 7b phase 2: decrypt pt*ct product, N=%0d (SCHEME=%0d) ==", N, SCHEME);
      if (SCHEME != 1) begin
        $display("FAIL: +PMULDEC requires +define+FHE_SK_HW (SCHEME=1)"); errors++;
      end else begin
        int i, i2f; real ar, ai, br, bi;
        cosim_net = MUL_NET;
        $readmemh({tvdir, "/input.txt"},  g_input);
        $readmemh({tvdir, "/input2.txt"}, g_input2);
        $readmemh({tvdir, "/prod_c0.txt"}, g_sum_c0);
        $readmemh({tvdir, "/prod_c1.txt"}, g_sum_c1);
        // pt*ct doubles the scale (Delta -> Delta^2): the decode divides by twice
        // the single-message exponent. Single recovers at -(net+LOGN) (=-RT_SCALE);
        // the product recovers at exactly 2x that (empirically confirmed: a -(2net+LOGN)
        // guess left a clean residual factor of 2^LOGN). Overridable with +I2FSCALE.
        i2f = -2*(MUL_NET + LOGN);
        void'($value$plusargs("I2FSCALE=%d", i2f));
        cosim_keygen(KEYGEN_SEED);
        to_q(c0_q, g_sum_c0, N); to_q(c1_q, g_sum_c1, N);
        cosim_decrypt(c0_q, c1_q, i2f, reco_q);
        // expected = complex slotwise product (slots are re/im interleaved)
        for (i = 0; i < N/2; i++) begin
          ar = $bitstoreal(g_input [2*i]); ai = $bitstoreal(g_input [2*i+1]);
          br = $bitstoreal(g_input2[2*i]); bi = $bitstoreal(g_input2[2*i+1]);
          g_sum_exp[2*i]   = $realtobits(ar*br - ai*bi);
          g_sum_exp[2*i+1] = $realtobits(ar*bi + ai*br);
        end
        $display("  [phase2] I2F decode scale = %0d", i2f);
        fft_abs_floor = 2.0e-3;   // product of two O(1) operands: looser abs floor on cancellation slots
        check_fft(reco_q, g_sum_exp, N, "cosim pt*ct (recovered vs m1(.)m2)", 1.0e-2);
      end
      if (errors == 0) $display("RESULT: PASS");
      else             $display("RESULT: FAIL (%0d mismatches)", errors);
      $finish;
    end

    // ---- Rung 7b-rescale phase 1: 2-limb keygen + encrypt m1 + encode pt(m2) --
    if ($test$plusargs("RESCENC")) begin
      $display("== Rung 7b-rescale phase 1: 2-limb keygen+encrypt+encode, N=%0d (SCHEME=%0d) ==", N, SCHEME);
      if (SCHEME != 1) begin
        $display("FAIL: +RESCENC requires +define+FHE_SK_HW (SCHEME=1)"); errors++;
      end else begin
        $readmemh({tvdir, "/input.txt"},  g_input);
        $readmemh({tvdir, "/input2.txt"}, g_input2);
        cosim_keygen2(KEYGEN_SEED);
        begin int fd;
          fd = $fopen({tvdir, "/hw_s_tern.txt"}, "w");
          if (fd) begin for (int j = 0; j < N; j++) $fdisplay(fd, "%0d", ck_s_tern[j]); $fclose(fd); end
        end
        dump_hex("hw_s_ntt.txt",    ck_s_ntt,  N);   // q0 keygen cross-check
        dump_hex("hw_s_ntt_q1.txt", ck_s_ntt1, N);   // q1 keygen cross-check
        cosim_encrypt2(g_input, A_SEED, ERR_SEED);
        dump_hex("ct_c0_q0.txt", c0_q,  N); dump_hex("ct_c1_q0.txt", c1_q,  N);
        dump_hex("ct_c0_q1.txt", c0_l1, N); dump_hex("ct_c1_q1.txt", c1_l1, N);
        cosim_encode_pt2(g_input2, ERR_SEED2);
        dump_hex("pt_q0.txt", pt_q0, N); dump_hex("pt_q1.txt", pt_q1, N);
        $display("  [phase1] dumped 2-limb ct + pt to %s", tvdir);
      end
      if (errors == 0) $display("RESULT: PASS");
      else             $display("RESULT: FAIL (%0d mismatches)", errors);
      $finish;
    end

    // ---- Rung 7b-rescale phase 2: decrypt the rescaled product @q0 -----------
    if ($test$plusargs("RESCDEC")) begin
      $display("== Rung 7b-rescale phase 2: decrypt rescaled pt*ct @q0, N=%0d (SCHEME=%0d) ==", N, SCHEME);
      if (SCHEME != 1) begin
        $display("FAIL: +RESCDEC requires +define+FHE_SK_HW (SCHEME=1)"); errors++;
      end else begin
        int i, i2f; real ar, ai, br, bi;
        $readmemh({tvdir, "/input.txt"},  g_input);
        $readmemh({tvdir, "/input2.txt"}, g_input2);
        $readmemh({tvdir, "/prod_c0.txt"}, g_sum_c0);   // rescaled product @q0
        $readmemh({tvdir, "/prod_c1.txt"}, g_sum_c1);
        // After rescale the q0 scale is Delta^2/q1; the decode divides by twice the
        // single-message exponent minus log2(q1). Residual 2^47/q1 ~ 1+1e-7.
        i2f = -(2*(RESC_NET + LOGN) - LOG2_Q1);
        void'($value$plusargs("I2FSCALE=%d", i2f));
        cosim_keygen2(KEYGEN_SEED);                  // re-derive sk_mont@q0 (s never on disk)
        to_q(c0_q, g_sum_c0, N); to_q(c1_q, g_sum_c1, N);
        cosim_decrypt(c0_q, c1_q, i2f, reco_q);      // decrypt at q0 with ck_sk_mont (=q0)
        for (i = 0; i < N/2; i++) begin
          ar = $bitstoreal(g_input [2*i]); ai = $bitstoreal(g_input [2*i+1]);
          br = $bitstoreal(g_input2[2*i]); bi = $bitstoreal(g_input2[2*i+1]);
          g_sum_exp[2*i]   = $realtobits(ar*br - ai*bi);
          g_sum_exp[2*i+1] = $realtobits(ar*bi + ai*br);
        end
        $display("  [phase2] I2F decode scale = %0d", i2f);
        fft_abs_floor = 2.0e-3;
        check_fft(reco_q, g_sum_exp, N, "cosim pt*ct+rescale (recovered vs m1(.)m2)", 1.0e-2);
      end
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
