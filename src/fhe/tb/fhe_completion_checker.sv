// SPDX-License-Identifier: Apache-2.0
// Verification only. Shared by unit and full-SoC monitors; not synthesized.
module fhe_completion_checker (
  input logic clk, rst_b, zeroize, cmd_accept, ready, status_valid,
  output integer completions
);
  bit command_outstanding = 0;
  initial completions = 0;
  always @(posedge clk) begin
    if (!rst_b || zeroize) command_outstanding <= 0;
    else if (cmd_accept) command_outstanding <= 1;
    else if (ready && status_valid) command_outstanding <= 0;
  end
  // Sample after the rising-edge NBA updates, including sticky completion.
  always @(negedge clk) begin
    if (rst_b && !zeroize) begin
      if (command_outstanding && ready && !status_valid)
        $fatal(1, "FHE_COMPLETION READY exposed before completion was latched");
      // Also check idle/stale status: this invariant is not command-qualified.
      if (status_valid && !ready)
        $fatal(1, "FHE_COMPLETION VALID exposed without READY");
      if (command_outstanding && ready && status_valid) completions++;
    end
  end
endmodule
