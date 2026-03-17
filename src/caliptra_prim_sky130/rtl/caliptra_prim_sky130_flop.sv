// SPDX-License-Identifier: Apache-2.0
//
// Sky130-specific D flip-flop primitive for Caliptra.
// Replaces caliptra_prim_generic_flop with sky130_fd_sc_hd cells.
// Supports parameterized ResetValue per bit:
//   ResetValue[k]==0 → dfrtp (async reset to 0)
//   ResetValue[k]==1 → dfstp (async set to 1)

module caliptra_prim_sky130_flop #(
  parameter int               Width      = 1,
  parameter logic [Width-1:0] ResetValue = 0
) (
  input                    clk_i,
  input                    rst_ni,
  input        [Width-1:0] d_i,
  output logic [Width-1:0] q_o
);

  for (genvar k = 0; k < Width; k++) begin : gen_flops
    if (ResetValue[k] == 1'b0) begin : gen_rst0
      DFFRX1 u__size_only__flop (
        .CK(clk_i),
        .D(d_i[k]),
        .RN(rst_ni),
        .Q(q_o[k]),
        .QN() // unused
      );
    end else begin : gen_rst1
      DFFRX1 u__size_only__flop (
        .CK(clk_i),
        .D(d_i[k]),
        .RN(rst_ni),
        .Q(q_o[k]),
        .QN() // unused
      );
    end
  end

endmodule : caliptra_prim_sky130_flop
