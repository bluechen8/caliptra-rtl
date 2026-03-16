// SPDX-License-Identifier: Apache-2.0
//
// Sky130-specific 2-input XOR primitive for Caliptra.
// Replaces caliptra_prim_generic_xor2 with sky130_fd_sc_hd cells.

module caliptra_prim_sky130_xor2 #(
  parameter int Width = 1
) (
  input        [Width-1:0] in0_i,
  input        [Width-1:0] in1_i,
  output logic [Width-1:0] out_o
);

  for (genvar k = 0; k < Width; k++) begin : gen_xor2
    sky130_fd_sc_hd__xor2_1 u__size_only__xor2 (
      .A(in0_i[k]),
      .B(in1_i[k]),
      .X(out_o[k])
    );
  end

endmodule : caliptra_prim_sky130_xor2
