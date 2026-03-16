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

  // sky130 mux2: A0 selected when S=0, A1 selected when S=1
  sky130_fd_sc_hd__mux2_1 u__size_only__clock_mux (
    .A0(clk0_i),
    .A1(clk1_i),
    .S(sel_i),
    .X(clk_o)
  );

endmodule : caliptra_prim_sky130_clock_mux2
