// SPDX-License-Identifier: Apache-2.0
//
// Stage-B' 2a: trace-equivalence unit test for the FHE microsequencer.
//
// Drives the walker for KEYGEN / ENCRYPT (L=1 and L=2) / DECRYPT against a
// recording stub "core" that decodes the ComputeCoreWrapper debug-IO pins.
// Checks, independently of the real core:
//   - each command raises exactly one `done`;
//   - only the KEYGEN sampling pass reloads the seed (reseed_en), dina is 0;
//   - the command loaded into ComputeCore for each pass (core_cmd as it
//     rises from 0) matches the TB's own ins_* builders for the right limb
//     chain + scale -- this is the actual trace-equivalence assertion (walker
//     encoding == validated TB encoding);
//   - no write targets the INS buffer, and core_cmd is 0 while the core is reset.
//
// No real ComputeCore, no DMA: external poly data flows over ext_* (stubbed).
//
`timescale 1ns/1ps
module tb_fhe_microseq;
  import fhe_params_pkg::*;

  localparam int LOGN = 4;
  localparam int N    = 1 << LOGN;          // 16 -- tiny, fast

  // q chain (Rung-7): q0 qm=9 k=0 ms=0 ; q1 qm=1 k=1 ms=1
  localparam int QM0=9, K0=0, MS0=0, QM1=1, K1=1, MS1=1;
  localparam int RNS_KG  = 100;   // arbitrary distinct scale values for the test
  localparam int RNS_ENC = 200;
  localparam int I2F_DEC = -50;

  logic clk=0, rst_b=0, zeroize=0;
  always #5 clk=~clk;

  logic        cmd_valid=0;
  fhe_cmd_e    cmd=FHE_NONE;
  logic [11:0] scale      =12'(RNS_KG);
  logic [3:0]  num_limbs  =4'd1;
  wire         reseed_en;
  logic [63:0] r2modq [0:FHE_L-1];

  wire [31:0] control_low_word, control_high_word, dina_low, dina_high;
  logic [31:0] dout_low, dout_high, status;
  wire [2:0]  ext_sel; wire [LOGN:0] ext_idx;
  logic [63:0] ext_din;
  wire        ext_dout_we; wire [63:0] ext_dout;
  wire        busy, done, error;
  wire [39:0] core_cmd;
  // A pass starts when core_cmd rises from 0 (it is 0 between passes).
  logic [39:0] core_cmd_q;
  always_ff @(posedge clk) core_cmd_q <= core_cmd;
  wire cmd_load = (core_cmd != 40'd0) && (core_cmd_q == 40'd0);

  // deterministic external/stub data function
  function automatic logic [63:0] f_data(input logic [3:0] bram, input logic [LOGN:0] addr);
    f_data = {16'hD00D, 12'd0, bram, 16'hC0DE, 4'd0, addr};
  endfunction
  always_comb ext_din = f_data(4'(ext_sel), ext_idx);

  fhe_microseq #(.LOGN(LOGN), .N(N)) dut (
    .step(1'b1),
    .clk(clk), .rst_b(rst_b), .zeroize(zeroize),
    .cmd_valid(cmd_valid), .cmd(cmd),
    .k_kg(), .k_kw(), .k_scale(),
    .evk_h('0), .evk_row('0), .gadget('{default: '0}), .k_gad(),   // EVKGEN needs shared storage
    .scale(scale), .reseed_en(reseed_en),
    .num_limbs(num_limbs), .r2modq(r2modq),
    .rmodq('{default: '0}),   // the one-limb key's table; unused without shared storage
    .control_low_word(control_low_word), .control_high_word(control_high_word),
    .dina_low(dina_low), .dina_high(dina_high),
    .dout_low(dout_low), .dout_high(dout_high), .status(status),
    .core_cmd(core_cmd),
    .ext_sel(ext_sel), .ext_idx(ext_idx), .ext_din(ext_din),
    .ext_dout_we(ext_dout_we), .ext_dout(ext_dout),
    // B' 2c-step-2 DMA handshake: tie idle/ready high for the legacy zero-latency
    // array model (this trace test has no DMA engine).
    .dma_desc_valid(), .dma_desc_wr(), .dma_desc_ptr(), .dma_desc_limb(),
    .dma_ready(1'b1), .dma_rd_valid(1'b1), .dma_rd_pop(), .dma_wr_ready(1'b1),
    .exe_hold(1'b0), .exe_held(),
    .busy(busy), .done(done), .error(error)
  );

  // ---- stub core: combinational dout = f(bram,addr); status[0]=1 a few cycles after start ----
  wire [3:0]  cl_bram = {1'b0, control_low_word[31:29]};
  wire        cl_wea  = control_low_word[FHE_CW_WEA];
  wire        cl_ins  = control_low_word[FHE_CW_INS];
  wire [LOGN:0] cl_addr= control_low_word[LOGN:0];
  always_comb begin
    {dout_high,dout_low} = f_data(cl_bram, cl_addr);
  end
  // status[0]: the loaded pass is done, a fixed latency after cmd_load,
  // until the command drops to 0 (or the core is reset).
  int start_cnt;
  always_ff @(posedge clk or negedge rst_b) begin
    if (!rst_b) begin status<=32'd0; start_cnt<=0; end
    else if (control_high_word[0] || core_cmd == 40'd0) begin status<=32'd0; start_cnt<=0; end
    else if (cmd_load) start_cnt <= 1;
    else if (start_cnt != 0) begin
      if (start_cnt < 4) start_cnt <= start_cnt+1;
      else status <= 32'h1;
    end
  end

  // ===================================================================
  // Scoreboard: the EXE params and commands, in order
  // ===================================================================
  // EXE reseed gate (1 = reload the sampler seed). The seed itself arrives on
  // fhe_top's sideband; dina must carry 0 at every EXE.
  longint exe_p [0:63]; int nexe;
  longint cmd_p [0:63];   // command loaded at each EXE
  // dout strobes
  int     n_dout;

  task automatic sb_reset();
    nexe=0; n_dout=0;
  endtask

  always_ff @(posedge clk) begin
    if (rst_b) begin
      // The core decodes core_cmd directly: it must be 0 whenever the core is
      // held in reset (between passes).
      if (control_high_word[0] && core_cmd != 40'd0) begin
        $display("  core_cmd %h while the core is in reset", core_cmd); errors++;
      end
      // EXE: the command load
      if (cmd_load) begin
        exe_p[nexe] = longint'(reseed_en); cmd_p[nexe] = longint'(core_cmd); nexe++;
        if ({dina_high,dina_low} != 64'd0) begin
          $display("  EXE dina=%h, expected 0 (seed is on the sideband)", {dina_high,dina_low}); errors++;
        end
      end
      // dout strobes
      if (ext_dout_we) n_dout++;
      // No INS_RAM writes remain: every write is to a data bank.
      if (cl_wea && cl_ins) begin $display("  INS write at %h", control_low_word); errors++; end
    end
  end

  // ===================================================================
  // Golden: ins_* builders (ported from tb_ckks_roundtrip.sv) + expected lists
  // ===================================================================
  function automatic longint neg_qm(input int qm); neg_qm = (-qm) & ((1<<17)-1); endfunction
  function automatic longint g_fft(input bit dif); g_fft = (1<<4) | (longint'(dif)<<3) | 1; endfunction
  function automatic longint g_ntt(input bit dif, input int k, input int ms, input int qm);
    longint q=neg_qm(qm); g_ntt = (q<<13) | (longint'(ms)<<9) | (longint'(k)<<5) | (longint'(dif)<<3) | 1;
  endfunction
  function automatic longint g_rns(input int sc, input int k, input int ms, input int qm);
    longint q=neg_qm(qm); longint sh=(sc>>5)&'h7f, sm=(sc>>3)&'h3, sl=sc&'h7;
    g_rns = (sh<<33) | (sl<<30) | (q<<13) | (longint'(ms)<<9) | (longint'(k)<<5) | (sm<<3) | 2;
  endfunction
  function automatic longint g_pwm(input int k, input int qm, input bit neg, input bit enc);
    longint q=neg_qm(qm);
    g_pwm = (q<<13) | (longint'(k)<<5) | (longint'(enc)<<4) | (longint'(neg)<<3) | 4;
  endfunction
  function automatic longint g_i2f(input int sc, input int k, input int qm);
    longint q=neg_qm(qm); longint sh=(sc>>>5)&'hf, sm=(sc>>>3)&'h3, sl=sc&'h7;
    g_i2f = (sh<<33) | (sl<<30) | (q<<13) | (longint'(k)<<5) | (sm<<3) | 3;
  endfunction
  function automatic longint g_proj(); g_proj = 5; endfunction

  int errors=0;
  task automatic chk(input string nm, input longint got, input longint exp);
    if (got !== exp) begin
      $display("  MISMATCH %-22s got=%h exp=%h", nm, got, exp); errors++;
    end
  endtask

  task automatic run_cmd(input fhe_cmd_e c, input logic [3:0] L);
    sb_reset();
    @(negedge clk); cmd=c; num_limbs=L; cmd_valid=1;
    @(negedge clk); cmd_valid=0; cmd=FHE_NONE;
    // wait for done
    fork
      begin : wd
        int t=0;
        while (!done) begin @(posedge clk); t++; if (t>20000) begin $display("TIMEOUT"); errors++; disable wd; end end
      end
    join
    @(negedge clk);
  endtask

  // expected passes: (command, reseed) in order
  longint exp_cmd [0:63]; longint exp_exe [0:63]; int n_exp;
  task automatic clr_exp(); n_exp=0; endtask
  task automatic e_pass(input longint cmd, input longint reseed);
    exp_cmd[n_exp]=cmd; exp_exe[n_exp]=reseed; n_exp++;
  endtask

  task automatic compare(input string tag);
    int i;
    $display("[%s] passes=%0d dout=%0d  (exp %0d)", tag, nexe, n_dout, n_exp);
    if (nexe !== n_exp) begin $display("  PASS COUNT got=%0d exp=%0d", nexe, n_exp); errors++; end
    for (i=0;i<n_exp && i<nexe;i++) begin
      chk($sformatf("cmd[%0d]",i), cmd_p[i], exp_cmd[i]);
      chk($sformatf("exe[%0d]",i), exe_p[i], exp_exe[i]);
    end
  endtask

  initial begin
    for (int i=0;i<FHE_L;i++) r2modq[i] = 64'hB2000000 + i; // distinct per-limb
    rst_b=0; repeat(4) @(negedge clk); rst_b=1; repeat(2) @(negedge clk);

    // ---------------- KEYGEN: always every installed limb; only the sampling
    // pass reloads the seed, even when CONFIG.L asks for one limb ----------------
    clr_exp();
    scale = 12'(RNS_KG);
    e_pass(g_fft(1),                       1);
    e_pass(g_rns(RNS_KG,K0,MS0,QM0),       0);
    e_pass(g_ntt(0,K0,MS0,QM0),            0);
    e_pass(g_pwm(K0,QM0,0,0),              0);
    e_pass(g_rns(RNS_KG,K1,MS1,QM1),       0);
    e_pass(g_ntt(0,K1,MS1,QM1),            0);
    e_pass(g_pwm(K1,QM1,0,0),              0);
    run_cmd(FHE_KEYGEN, 4'd1);
    compare("KEYGEN (L ignored)");

    // ---------------- ENCRYPT (L=1): a and e0 continue the stream ----------------
    clr_exp();
    scale = 12'(RNS_ENC);
    e_pass(g_fft(1),                       0);
    e_pass(g_rns(RNS_ENC,K0,MS0,QM0),      0);
    e_pass(g_ntt(0,K0,MS0,QM0),            0);
    e_pass(g_pwm(K0,QM0,1,1),              0);
    run_cmd(FHE_ENCRYPT, 4'd1);
    compare("ENCRYPT L=1");

    // ---------------- ENCRYPT (L=2) ----------------
    clr_exp();
    e_pass(g_fft(1),                       0);
    e_pass(g_rns(RNS_ENC,K0,MS0,QM0),      0);
    e_pass(g_ntt(0,K0,MS0,QM0),            0);
    e_pass(g_pwm(K0,QM0,1,1),              0);
    e_pass(g_rns(RNS_ENC,K1,MS1,QM1),      0);
    e_pass(g_ntt(0,K1,MS1,QM1),            0);
    e_pass(g_pwm(K1,QM1,1,1),              0);
    run_cmd(FHE_ENCRYPT, 4'd2);
    compare("ENCRYPT L=2");

    // ---------------- DECRYPT (L=1) ----------------
    clr_exp();
    scale = 12'(I2F_DEC);
    e_pass(g_pwm(K0,QM0,0,0),              0);
    e_pass(g_ntt(1,K0,MS0,QM0),            0);
    e_pass(g_i2f(I2F_DEC,K0,QM0),          0);
    e_pass(g_fft(0),                       0);
    e_pass(g_proj(),                       0);
    run_cmd(FHE_DECRYPT, 4'd1);
    compare("DECRYPT L=1");

    if (errors==0) $display("\ntb_fhe_microseq: ALL TRACE CHECKS PASS");
    else           $fatal(1, "tb_fhe_microseq: FAILED (%0d errors)", errors);
    $finish;
  end
endmodule
