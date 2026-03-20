// SPDX-License-Identifier: Apache-2.0
//
// Sky130-specific Integrated Clock Gate for Caliptra.
// Built from discrete cells: CLKINVX1 + TLATX1 + AND2X1
// LOW-transparent latch ICG (standard for posedge-clocked designs).

module sky130_cptra_icg (
    input  logic clk,
    input  logic en,
    output       clk_cg
);

    wire clk_inv, en_latched;

    // Invert clock: latch will be transparent when clk=0
    CLKINVX1 u__size_only__clkinv (.A(clk), .Y(clk_inv));

    // LOW-transparent latch: captures en when clk=0, holds when clk=1
    TLATX1 u__size_only__latch (.D(en), .G(clk_inv), .Q(en_latched), .QN());

    // Gate clock with latched enable
    AND2X1 u__size_only__and (.A(clk), .B(en_latched), .Y(clk_cg));

endmodule
