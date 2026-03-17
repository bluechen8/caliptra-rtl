// SPDX-License-Identifier: Apache-2.0
//
// Sky130-specific D flip-flop with enable primitive for Caliptra.
// Replaces caliptra_prim_generic_flop_en with sky130_fd_sc_hd cells.
// Enable implemented via mux2 feeding dfrtp/dfstp.

module caliptra_prim_sky130_flop_en #(
  parameter int               Width      = 1,
  parameter bit               EnSecBuf   = 0,
  parameter logic [Width-1:0] ResetValue = 0
) (
  input                    clk_i,
  input                    rst_ni,
  input                    en_i,
  input        [Width-1:0] d_i,
  output logic [Width-1:0] q_o
);

  logic en;
  if (EnSecBuf) begin : gen_en_sec_buf
    caliptra_prim_sec_anchor_buf #(
      .Width(1)
    ) u_en_buf (
      .in_i(en_i),
      .out_o(en)
    );
  end else begin : gen_en_no_sec_buf
    assign en = en_i;
  end

  for (genvar k = 0; k < Width; k++) begin : gen_flops
    logic mux_out;

    // Enable mux: en=1 -> d_i (new data), en=0 -> q_o (hold)
    MX2X1 u__size_only__mux (
      .A(q_o[k]),   // selected when S=0
      .B(d_i[k]),   // selected when S=1
      .S0(en),
      .Y(mux_out)
    );

    if (ResetValue[k] == 1'b0) begin : gen_rst0
      // reset-to-0
      DFFRX1 u__size_only__flop (
        .CK(clk_i),
        .D(mux_out),
        .RN(rst_ni),
        .Q(q_o[k]),
        .QN()
      );
    end else begin : gen_rst1
      // set-to-1
      DFFSX1 u__size_only__flop (
        .CK(clk_i),
        .D(mux_out),
        .SN(rst_ni),
        .Q(q_o[k]),
        .QN()
      );
    end
  end

endmodule : caliptra_prim_sky130_flop_en
