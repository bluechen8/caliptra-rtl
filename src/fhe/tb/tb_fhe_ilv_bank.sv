`timescale 1ns/1ps
// fhe_ilv_bank against the ideal one-read/one-write contract, step by step:
// the read at step k returns the array before step k's write (FORWARD_MASK bits
// take that write on a same-address hit) and is on q after step k+1. Random,
// strided-with-lag, repeated-read and same-address streams, idle clocks, and
// requests held while the bank stalls.
module ilv_check #(
  parameter int W = 64, AW = 7, GRAN = 8,
  parameter logic [W-1:0] FORWARD_MASK = '0,
  parameter int SEED = 1, STEPS = 20000
)(input logic clk, output bit finished, output int errors);
  localparam int MW = W / GRAN;
  logic          step_live, we;
  logic [AW-1:0] wa, ra;
  logic [W-1:0]  wd;
  logic [MW-1:0] mask;
  wire  [W-1:0]  q;
  wire           stall;
  wire           step = step_live && !stall;

  fhe_working_array #(.ILV(1), .W(W), .AW(AW), .GRAN(GRAN), .FORWARD_MASK(FORWARD_MASK)) dut (
    .clk, .step, .stall, .we, .wa, .wd, .mask, .ra, .q);

  // reference
  logic [W-1:0] mem [0:(1 << AW)-1];
  logic [W-1:0] ref_stage0, ref_q;
  int steps = 0, stalls = 0, hits = 0;

  function automatic logic [W-1:0] bits_of(input logic [MW-1:0] m);
    for (int b = 0; b < MW; b++) bits_of[b*GRAN +: GRAN] = {GRAN{m[b]}};
  endfunction

  // a new request after each accepted step; held while stalled or idle
  int unsigned rng = SEED;
  function automatic int unsigned rnd();
    rng = rng * 1103515245 + 12345; return rng >> 8;
  endfunction
  int mode = 0, lag = 3, rd_ptr = 0;
  task automatic new_request();
    if (steps % 500 == 0) begin mode = rnd() % 4; lag = 1 + rnd() % 24; end
    case (mode)
      0: begin ra = AW'(rnd()); wa = AW'(rnd()); end                    // random
      1: begin rd_ptr += 1 << (rnd() % 3); ra = AW'(rd_ptr); wa = AW'(rd_ptr - lag); end  // strided, lagged write
      2: begin if (rnd() % 4 == 0) ra = AW'(rnd()); wa = AW'(rnd()); end // mostly repeated reads
      default: begin ra = AW'(rnd() % 8); wa = (rnd() % 2 != 0) ? ra : AW'(rnd() % 8); end  // hot rows, hits
    endcase
    we   = (rnd() % 4) != 0;
    wd   = {W{1'b0}};
    for (int i = 0; i < W; i += 16) wd = W'({wd, 16'(rnd())});
    mask = MW'(rnd()) | MW'(rnd() % 2);
  endtask

  initial begin
    finished = 0; errors = 0;
    for (int i = 0; i < (1 << AW); i++) mem[i] = '0;
    // the DUT's sub-banks start at zero too
    step_live = 0; we = 0; wa = 0; ra = 0; wd = 0; mask = '1;
    repeat (3) @(negedge clk);
    new_request();
    while (steps < STEPS) begin
      automatic bit took;
      step_live = (rnd() % 16) != 0;               // idle clocks: parent clock stopped
      @(posedge clk);
      took = step;                                 // sampled before the edge's updates land
      if (took) begin
        automatic logic [W-1:0] fwd = (we && wa == ra) ? (bits_of(mask) & FORWARD_MASK) : '0;
        if (we && wa == ra) hits++;
        ref_q = ref_stage0;
        ref_stage0 = (mem[ra] & ~fwd) | (wd & fwd);
        if (we) mem[wa] = (mem[wa] & ~bits_of(mask)) | (wd & bits_of(mask));
        steps++;
      end else if (step_live) stalls++;
      @(negedge clk);
      if (q !== ref_q && steps > 2) begin
        if (errors < 10) $display("  MISMATCH W=%0d step %0d: q=%h ref=%h", W, steps, q, ref_q);
        errors++;
      end
      if (took) new_request();
    end
    $display("  W=%0d AW=%0d fwd=%0d: %0d steps, %0d stall clocks (%.2f%%), %0d same-address hits, %0d errors",
             W, AW, FORWARD_MASK != 0, steps, stalls, 100.0 * stalls / steps, hits, errors);
    finished = 1;
  end
endmodule

module tb_fhe_ilv_bank;
  logic clk = 0;
  always #5 clk = ~clk;
  bit  done [3];
  int  err [3];
  ilv_check #(.W(64), .AW(7), .GRAN(8),  .FORWARD_MASK(64'hff00000000000000), .SEED(11)) m_like (clk, done[0], err[0]);
  ilv_check #(.W(54), .AW(8), .GRAN(54), .FORWARD_MASK('0),                   .SEED(22)) k_like (clk, done[1], err[1]);
  ilv_check #(.W(64), .AW(6), .GRAN(64), .FORWARD_MASK('1),                   .SEED(33)) r_like (clk, done[2], err[2]);
  initial begin
    wait (done[0] && done[1] && done[2]);
    if (err[0] + err[1] + err[2] == 0) $display("tb_fhe_ilv_bank: PASS");
    else $fatal(1, "tb_fhe_ilv_bank: FAIL (%0d mismatches)", err[0] + err[1] + err[2]);
    $finish;
  end
endmodule
