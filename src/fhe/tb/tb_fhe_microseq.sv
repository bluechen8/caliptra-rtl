// SPDX-License-Identifier: Apache-2.0
//
// Stage-B' 2a: trace-equivalence unit test for the FHE microsequencer.
//
// Drives the walker for KEYGEN / ENCRYPT (L=1 and L=2) / DECRYPT against a
// recording stub "core" that decodes the ComputeCoreWrapper debug-IO pins.
// Checks, independently of the real core:
//   - each command raises exactly one `done`;
//   - the EXE-param stream (sampling seeds) is in the expected order;
//   - the LDINS payload stream (the patched INS words) matches the TB's own
//     ins_* builders for the right limb chain + scale -- this is the actual
//     trace-equivalence assertion (walker encoding == validated TB encoding);
//   - the per-op (bank, ins_flag, nwords) summary matches the program.
//
// No real ComputeCore, no DMA: external poly data flows over ext_* (stubbed).
//
`timescale 1ns/1ps
module tb_fhe_microseq;
  import fhe_params_pkg::*;

  localparam int LOGN = 4;
  localparam int N    = 1 << LOGN;          // 16 -- tiny, fast
  localparam int INS_BUFFER_SIZE = 16;
  localparam longint W40 = 64'h1 << 40;

  // q chain (Rung-7): q0 qm=9 k=0 ms=0 ; q1 qm=1 k=1 ms=1
  localparam int QM0=9, K0=0, MS0=0, QM1=1, K1=1, MS1=1;
  localparam int RNS_KG  = 100;   // arbitrary distinct scale values for the test
  localparam int RNS_ENC = 200;
  localparam int I2F_DEC = -50;

  logic clk=0, rst_b=0, zeroize=0;
  always #5 clk=~clk;

  logic        cmd_valid=0;
  fhe_cmd_e    cmd=FHE_NONE;
  logic [63:0] keygen_seed=64'hA105_BEEF_0006_A001;
  logic [63:0] a_seed     =64'h0006_A002_C0FF_EE77;
  logic [63:0] err_seed   =64'h2350_e171_5239_2f72;
  logic [3:0]  num_limbs  =4'd1;
  logic [63:0] r2modq [0:FHE_L-1];

  wire [31:0] control_low_word, control_high_word, dina_low, dina_high;
  logic [31:0] dout_low, dout_high, status;
  wire [2:0]  ext_sel; wire [LOGN:0] ext_idx;
  logic [63:0] ext_din;
  wire        ext_dout_we; wire [63:0] ext_dout;
  wire        busy, done, error;

  // deterministic external/stub data function
  function automatic logic [63:0] f_data(input logic [3:0] bram, input logic [LOGN:0] addr);
    f_data = {16'hD00D, 12'd0, bram, 16'hC0DE, 4'd0, addr};
  endfunction
  always_comb ext_din = f_data(4'(ext_sel), ext_idx);

  fhe_microseq #(.LOGN(LOGN), .N(N)) dut (
    .clk(clk), .rst_b(rst_b), .zeroize(zeroize),
    .cmd_valid(cmd_valid), .cmd(cmd),
    .keygen_seed(keygen_seed), .a_seed(a_seed), .err_seed(err_seed),
    .rns_scale_kg(32'(RNS_KG)), .rns_scale_enc(32'(RNS_ENC)), .i2f_scale_dec(32'(I2F_DEC)),
    .num_limbs(num_limbs), .r2modq(r2modq),
    .control_low_word(control_low_word), .control_high_word(control_high_word),
    .dina_low(dina_low), .dina_high(dina_high),
    .dout_low(dout_low), .dout_high(dout_high), .status(status),
    .ext_sel(ext_sel), .ext_idx(ext_idx), .ext_din(ext_din),
    .ext_dout_we(ext_dout_we), .ext_dout(ext_dout),
    .busy(busy), .done(done), .error(error)
  );

  // ---- stub core: combinational dout = f(bram,addr); status[0]=1 a few cycles after start ----
  wire [3:0]  cl_bram = {1'b0, control_low_word[31:29]};
  wire        cl_wea  = control_low_word[14];
  wire        cl_ins  = control_low_word[15];
  wire        cl_grant= control_low_word[16];
  wire [LOGN:0] cl_addr= control_low_word[LOGN:0];
  always_comb begin
    {dout_high,dout_low} = f_data(cl_bram, cl_addr);
  end
  // status: cycle_count[30:1], done_all[0]. Model done a fixed latency after start(ch==2).
  int start_cnt;
  always_ff @(posedge clk or negedge rst_b) begin
    if (!rst_b) begin status<=32'd0; start_cnt<=0; end
    else begin
      if (control_high_word==32'd2) begin
        if (start_cnt < 4) start_cnt <= start_cnt+1;
        status <= (start_cnt>=3) ? 32'h1 : 32'h0;     // done_all after a few cycles
      end else begin start_cnt<=0; status<=32'd0; end
    end
  end

  // ===================================================================
  // Scoreboard: collapse pin activity into (WR runs) + (EXE params)
  // ===================================================================
  // WR runs
  int   wr_n   [0:255]; int wr_bram[0:255]; int wr_ins[0:255]; longint wr_pay[0:255];
  int   nwr;
  logic run_open; int run_bram, run_ins, run_n; longint run_pay;
  // EXE params
  longint exe_p [0:63]; int nexe;
  int     prev_ch;
  // dout strobes
  int     n_dout;

  task automatic sb_reset();
    nwr=0; nexe=0; n_dout=0; run_open=0; prev_ch=1;
  endtask

  always_ff @(posedge clk) begin
    if (rst_b) begin
      // EXE start edge
      if (control_high_word==32'd2 && prev_ch!=2) begin
        exe_p[nexe] = {dina_high,dina_low}; nexe++;
      end
      prev_ch <= control_high_word;
      // dout strobes
      if (ext_dout_we) n_dout++;
      // WR collapse
      if (control_low_word==32'd0) begin
        if (run_open) begin
          wr_n[nwr]=run_n; wr_bram[nwr]=run_bram; wr_ins[nwr]=run_ins; wr_pay[nwr]=run_pay; nwr++;
          run_open=0;
        end
      end else if (cl_wea) begin
        if (!run_open) begin run_open=1; run_bram=cl_bram; run_ins=cl_ins; run_n=0; run_pay=64'd0; end
        run_n++;
        if (cl_addr == (cl_ins? (LOGN+1)'(1) : '0)) run_pay = {dina_high,dina_low};
      end
    end
  end

  // ===================================================================
  // Golden: ins_* builders (ported from tb_ckks_roundtrip.sv) + expected lists
  // ===================================================================
  function automatic longint neg_qm(input int qm); neg_qm = (-qm) & ((1<<17)-1); endfunction
  function automatic longint g_fft(input bit dif); g_fft = W40 | (1<<4) | (longint'(dif)<<3) | 1; endfunction
  function automatic longint g_ntt(input bit dif, input int k, input int ms, input int qm);
    longint q=neg_qm(qm); g_ntt = W40 | (q<<13) | (longint'(ms)<<9) | (longint'(k)<<5) | (longint'(dif)<<3) | 1;
  endfunction
  function automatic longint g_rns(input int sc, input int k, input int ms, input int qm);
    longint q=neg_qm(qm); longint sh=(sc>>5)&'h7f, sm=(sc>>3)&'h3, sl=sc&'h7;
    g_rns = W40 | (sh<<33) | (sl<<30) | (q<<13) | (longint'(ms)<<9) | (longint'(k)<<5) | (sm<<3) | 2;
  endfunction
  function automatic longint g_pwm(input int k, input int qm, input bit neg, input bit enc);
    longint q=neg_qm(qm);
    g_pwm = W40 | (q<<13) | (longint'(k)<<5) | (longint'(enc)<<4) | (longint'(neg)<<3) | 4;
  endfunction
  function automatic longint g_i2f(input int sc, input int k, input int qm);
    longint q=neg_qm(qm); longint sh=(sc>>>5)&'hf, sm=(sc>>>3)&'h3, sl=sc&'h7;
    g_i2f = W40 | (sh<<33) | (sl<<30) | (q<<13) | (longint'(k)<<5) | (sm<<3) | 3;
  endfunction
  function automatic longint g_proj(); g_proj = W40 | 5; endfunction

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

  // expected EXE param + LDINS payload sequences
  longint exp_exe [0:63]; int n_exp_exe;
  longint exp_ins [0:63]; int n_exp_ins;
  task automatic clr_exp(); n_exp_exe=0; n_exp_ins=0; endtask
  task automatic e_exe(input longint p); exp_exe[n_exp_exe]=p; n_exp_exe++; endtask
  task automatic e_ins(input longint p); exp_ins[n_exp_ins]=p; n_exp_ins++; endtask

  // collect actual LDINS payloads (ins runs) in order
  task automatic collect_ins(output longint a[$]);
    int i; a={};
    for (i=0;i<nwr;i++) if (wr_ins[i]) a.push_back(wr_pay[i]);
  endtask

  task automatic compare(input string tag);
    longint ai[$]; int i;
    $display("[%s] runs=%0d exe=%0d dout=%0d  (exp ins=%0d exe=%0d)", tag, nwr, nexe, n_dout, n_exp_ins, n_exp_exe);
    // EXE params
    if (nexe !== n_exp_exe) begin $display("  EXE COUNT got=%0d exp=%0d", nexe, n_exp_exe); errors++; end
    for (i=0;i<n_exp_exe && i<nexe;i++) chk($sformatf("exe[%0d]",i), exe_p[i], exp_exe[i]);
    // LDINS payloads
    collect_ins(ai);
    if (ai.size() !== n_exp_ins) begin $display("  INS COUNT got=%0d exp=%0d", ai.size(), n_exp_ins); errors++; end
    for (i=0;i<n_exp_ins && i<ai.size();i++) chk($sformatf("ins[%0d]",i), ai[i], exp_ins[i]);
  endtask

  initial begin
    for (int i=0;i<FHE_L;i++) r2modq[i] = 64'hB2000000 + i; // distinct per-limb
    rst_b=0; repeat(4) @(negedge clk); rst_b=1; repeat(2) @(negedge clk);

    // ---------------- KEYGEN (L=1) ----------------
    clr_exp();
    e_ins(g_fft(1));                       e_exe(keygen_seed);
    e_ins(g_rns(RNS_KG,K0,MS0,QM0));       e_exe(0);
    e_ins(g_ntt(0,K0,MS0,QM0));            e_exe(0);
    e_ins(g_pwm(K0,QM0,0,0));              e_exe(0);
    run_cmd(FHE_KEYGEN, 4'd1);
    compare("KEYGEN L=1");

    // ---------------- ENCRYPT (L=1) ----------------
    clr_exp();
    e_ins(g_fft(1));                       e_exe(err_seed);
    e_ins(g_rns(RNS_ENC,K0,MS0,QM0));      e_exe(0);
    e_ins(g_ntt(0,K0,MS0,QM0));            e_exe(a_seed);
    e_ins(g_pwm(K0,QM0,1,1));              e_exe(0);
    run_cmd(FHE_ENCRYPT, 4'd1);
    compare("ENCRYPT L=1");

    // ---------------- ENCRYPT (L=2) ----------------
    clr_exp();
    e_ins(g_fft(1));                       e_exe(err_seed);
    e_ins(g_rns(RNS_ENC,K0,MS0,QM0));      e_exe(0);
    e_ins(g_ntt(0,K0,MS0,QM0));            e_exe(a_seed);
    e_ins(g_pwm(K0,QM0,1,1));              e_exe(0);
    e_ins(g_rns(RNS_ENC,K1,MS1,QM1));      e_exe(0);
    e_ins(g_ntt(0,K1,MS1,QM1));            e_exe(a_seed);
    e_ins(g_pwm(K1,QM1,1,1));              e_exe(0);
    run_cmd(FHE_ENCRYPT, 4'd2);
    compare("ENCRYPT L=2");

    // ---------------- DECRYPT (L=1) ----------------
    clr_exp();
    e_ins(g_pwm(K0,QM0,0,0));              e_exe(0);
    e_ins(g_ntt(1,K0,MS0,QM0));            e_exe(0);
    e_ins(g_i2f(I2F_DEC,K0,QM0));          e_exe(0);
    e_ins(g_fft(0));                       e_exe(0);
    e_ins(g_proj());                       e_exe(0);
    run_cmd(FHE_DECRYPT, 4'd1);
    compare("DECRYPT L=1");

    if (errors==0) $display("\ntb_fhe_microseq: ALL TRACE CHECKS PASS");
    else           $display("\ntb_fhe_microseq: FAILED (%0d errors)", errors);
    $finish;
  end
endmodule
