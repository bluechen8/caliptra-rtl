// SPDX-License-Identifier: Apache-2.0
//
// Sky130-specific 2-input AND primitive for Caliptra.
// Replaces caliptra_prim_generic_and2 with sky130_fd_sc_hd cells.

module caliptra_prim_sky130_and2 #(
  parameter int Width = 1
) (
  input        [Width-1:0] in0_i,
  input        [Width-1:0] in1_i,
  output logic [Width-1:0] out_o
);

  for (genvar k = 0; k < Width; k++) begin : gen_add2
    // The instance name "u__size_only__buf" contains the required tag.
    // Synthesis tools must be configured to apply "size_only"
    // constraints to any instance whose name includes "u__size_only__".
    // This naming convention should be used for all replaced primitives.

    AND2X1 u__size_only__and2 (
      .A (in0_i[k]),
      .B (in1_i[k]),
      .Y (out_o[k])
    );
  end

endmodule : caliptra_prim_sky130_and2
