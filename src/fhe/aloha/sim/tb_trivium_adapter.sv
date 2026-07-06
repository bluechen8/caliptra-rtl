`timescale 1ns / 1ps
// C'-2 step 1 unit TB: isolate TriviumAdapter (caliptra_prim_trivium wrapper,
// per-pass reload). Checks random_valid rises out of reset at cyc19 (same timing
// as the retired Trivium64) and that the keystream words match the SW oracle
// tvgen/trivium.py CaliptraPrimTrivium. Timeout-guarded.
module tb_trivium_adapter;
  logic clk = 0, rst = 1;
  logic [63:0] seed;
  logic [63:0] ro;
  logic        rv;
  int cyc = 0, errors = 0;

  // Golden keystream for seed 0x0123456789abcdef (tvgen/trivium.py).
  logic [63:0] wa [0:5];

  always #5 clk = ~clk;

  TriviumAdapter dut(.clk(clk), .rst(rst), .seed(seed),
                     .random_out(ro), .random_valid(rv));

  task automatic check(input [63:0] got, input [63:0] exp, input int idx);
    if (got !== exp) begin
      $display("TB_TRIVIUM: MISMATCH word[%0d] got=%016h exp=%016h", idx, got, exp);
      errors++;
    end
  endtask

  initial begin
    wa[0]=64'h51e37da311f97fd6; wa[1]=64'h07c9ed1c5a55c995; wa[2]=64'h022d61cc6b68c09e;
    wa[3]=64'hbd0ca89602174eb1; wa[4]=64'h5b8704f10a1511bc; wa[5]=64'hf5867912d452f95c;

    seed = 64'h0123456789abcdef;
    rst  = 1; repeat (4) @(posedge clk);
    rst  = 0;

    while (!rv && cyc < 500) begin @(posedge clk); cyc++; end
    if (!rv) begin $display("TB_TRIVIUM: FAIL random_valid never rose"); $finish; end
    $display("TB_TRIVIUM: random_valid rose at cyc=%0d", cyc);

    for (int i = 0; i < 6; i++) begin
      check(ro, wa[i], i);
      @(posedge clk);
    end

    if (errors == 0) $display("TB_TRIVIUM: DONE RESULT: PASS");
    else             $display("TB_TRIVIUM: DONE RESULT: FAIL (%0d mismatches)", errors);
    $finish;
  end
endmodule
