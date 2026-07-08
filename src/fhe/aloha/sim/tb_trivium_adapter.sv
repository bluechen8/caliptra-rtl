`timescale 1ns / 1ps
// C'-2 unit TB: isolate TriviumAdapter (free-run caliptra_prim_trivium wrapper).
// Drives active=1 (continuous consume) and verifies:
//   (1) reseed(seedA) -> random_valid rises @cyc19, keystream = CaliptraPrimTrivium(A) w0..
//   (2) FREE-RUN: consecutive cycles yield CONTINUOUS words (w0,w1,w2,...), i.e.
//       the stream never restarts without a reseed -> a/e0 never repeat.
//   (3) reseed(seedB) -> valid drops then rises, keystream restarts at C(B) w0..
// Expected words come from tvgen/trivium.py CaliptraPrimTrivium. Timeout-guarded.
module tb_trivium_adapter;
  logic clk = 0, rst = 1, reseed = 0;
  logic [63:0] seed;
  logic [63:0] ro;
  logic        rv;
  int cyc = 0, errors = 0;

  // Golden keystreams (tvgen/trivium.py CaliptraPrimTrivium).
  logic [63:0] wa [0:11];
  logic [63:0] wb [0:5];

  always #5 clk = ~clk;

  // active=1: an isolated continuous consumer (no inter-pass freeze here; the
  // freeze/`active` gating is exercised in RandomSampling + the round-trip TBs).
  TriviumAdapter dut(.clk(clk), .rst(rst), .reseed(reseed), .active(1'b1),
                     .seed(seed), .random_out(ro), .random_valid(rv));

  task automatic do_reseed(input [63:0] s);
    @(negedge clk); seed = s; reseed = 1'b1;
    @(negedge clk); reseed = 1'b0;
  endtask

  // Wait until random_valid, timeout-guarded. Returns with rv high, ro=first word.
  task automatic wait_valid;
    cyc = 0;
    while (!rv && cyc < 500) begin @(posedge clk); cyc++; end
    if (!rv) begin $display("TB_TRIVIUM: FAIL random_valid never rose"); $finish; end
  endtask

  task automatic check(input [63:0] got, input [63:0] exp, input int idx);
    if (got !== exp) begin
      $display("TB_TRIVIUM: MISMATCH word[%0d] got=%016h exp=%016h", idx, got, exp);
      errors++;
    end
  endtask

  initial begin
    wa[0]=64'h51e37da311f97fd6; wa[1]=64'h07c9ed1c5a55c995; wa[2]=64'h022d61cc6b68c09e;
    wa[3]=64'hbd0ca89602174eb1; wa[4]=64'h5b8704f10a1511bc; wa[5]=64'hf5867912d452f95c;
    wa[6]=64'h5be0e557229d4302; wa[7]=64'hc0ccba9ccec00508; wa[8]=64'hf14d78f1746df270;
    wa[9]=64'hd9e09eeb853498fe; wa[10]=64'h0b3f49fb1971d728; wa[11]=64'h07d1182218fe7753;
    wb[0]=64'hcb416aee0f7eaa0b; wb[1]=64'he56429bdc8c5b67a; wb[2]=64'heb5c6c7cddf863b0;
    wb[3]=64'hcdc8916082c84cb7; wb[4]=64'h0edd82b5f1348fa0; wb[5]=64'h5b203a6beaaa6a87;

    rst = 1; repeat (4) @(posedge clk);
    rst = 0; @(posedge clk);

    // (1)+(2) reseed A, then capture 12 CONTINUOUS free-run words.
    do_reseed(64'h0123456789abcdef);
    wait_valid();
    $display("TB_TRIVIUM: A random_valid rose at cyc=%0d", cyc);
    for (int i = 0; i < 12; i++) begin
      check(ro, wa[i], i);
      @(posedge clk);
    end

    // (3) reseed B: valid must drop (re-warm) then rise; keystream restarts.
    do_reseed(64'hdeadbeefcafebabe);
    if (rv) $display("TB_TRIVIUM: WARN random_valid did not drop on reseed");
    wait_valid();
    $display("TB_TRIVIUM: B random_valid rose at cyc=%0d", cyc);
    for (int i = 0; i < 6; i++) begin
      check(ro, wb[i], 100 + i);
      @(posedge clk);
    end

    if (errors == 0) $display("TB_TRIVIUM: DONE RESULT: PASS");
    else             $display("TB_TRIVIUM: DONE RESULT: FAIL (%0d mismatches)", errors);
    $finish;
  end
endmodule
