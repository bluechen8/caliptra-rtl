// SPDX-License-Identifier: Apache-2.0
module tb_fhe_completion_checker;
  logic clk = 0, rst_b = 0, zeroize = 0, cmd_accept = 0;
  logic ready = 1, status_valid = 0;
  integer completions;
  integer scenario = 0;
  always #5 clk = ~clk;
  fhe_completion_checker dut(.*);
  task automatic cycle;
    @(posedge clk); #1;
  endtask
  task automatic accept;
    cycle(); cmd_accept = 1; ready = 0; status_valid = 0;
    cycle(); cmd_accept = 0;
  endtask
  initial begin
    void'($value$plusargs("CASE=%d", scenario));
    cycle(); rst_b = 1;
    if (scenario == 1) begin
      // Must fail even without any accepted command (the old SoC gap).
      status_valid = 1; ready = 0;
    end else begin
      accept();
      cycle();
      if (scenario == 2) ready = 1; // READY before VALID must fail.
      else begin
        ready = 1; status_valid = 1;
        repeat (3) cycle();
        if (completions != 1) $fatal(1, "sticky VALID counted twice");
        accept(); cycle(); zeroize = 1; ready = 1;
        cycle(); zeroize = 0;
        repeat (2) cycle();
        accept(); cycle(); rst_b = 0; ready = 1;
        cycle(); rst_b = 1;
        repeat (2) cycle();
        accept(); cycle(); ready = 1; status_valid = 1;
        repeat (3) cycle();
        if (completions != 2) $fatal(1, "cancel/reset completion counted");
        $display("FHE_COMPLETION checker positive PASS");
        $finish;
      end
    end
    repeat (3) cycle();
    $fatal(1, "negative scenario escaped checker");
  end
endmodule
