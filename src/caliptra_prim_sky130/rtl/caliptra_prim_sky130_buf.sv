// SPDX-License-Identifier: Apache-2.0
//
// Sky130-specific buffer primitive for Caliptra.
// Replaces caliptra_prim_generic_buf with sky130_fd_sc_hd cells.
// Instance names include u__size_only__ tag for synthesis constraints.

module caliptra_prim_sky130_buf #(
  parameter int Width = 1
) (
  input        [Width-1:0] in_i,
  output logic [Width-1:0] out_o
);

  for (genvar k = 0; k < Width; k++) begin : gen_bufs
    sky130_fd_sc_hd__buf_1 u__size_only__buf (
      .A(in_i[k]),
      .X(out_o[k])
    );
  end

endmodule : caliptra_prim_sky130_buf
