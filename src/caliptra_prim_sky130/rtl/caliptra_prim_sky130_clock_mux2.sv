// SPDX-License-Identifier: Apache-2.0
//
// Sky130-specific 2-to-1 clock mux primitive for Caliptra.
// Replaces caliptra_prim_generic_clock_mux2 with sky130_fd_sc_hd mux cell.

module caliptra_prim_sky130_clock_mux2 #(
  parameter bit NoFpgaBufG = 1'b0 // unused in ASIC implementation
) (
  input        clk0_i,
  input        clk1_i,
  input        sel_i,
  output logic clk_o
);

    // The instance name "u__size_only__buf" contains the required tag.
    // Synthesis tools must be configured to apply "size_only"
    // constraints to any instance whose name includes "u__size_only__".
    // This naming convention should be used for all replaced primitives.

    CLKMX2X2 u__size_only__clock_mux2 (
      .A (clk0_i),
      .B (clk1_i),
      .S0 (sel_i),
      .Y (clk_o)
    );

endmodule : caliptra_prim_generic_clock_mux2