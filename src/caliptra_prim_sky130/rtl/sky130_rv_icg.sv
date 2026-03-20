// SPDX-License-Identifier: Apache-2.0
//
// Sky130-specific Integrated Clock Gate for VeeR RISC-V core.
// Built from discrete cells: CLKINVX1 + TLATX1 + AND2X1
// LOW-transparent latch ICG (standard for posedge-clocked designs).

module sky130_rv_icg (
    input  logic SE,
    input  logic EN,
    input  logic CK,
    output       Q
);

    logic gate;
    assign gate = EN | SE;

    wire ck_inv, gate_latched;

    // Invert clock: latch will be transparent when CK=0
    CLKINVX1 u__size_only__clkinv (.A(CK), .Y(ck_inv));

    // LOW-transparent latch: captures gate when CK=0, holds when CK=1
    TLATX1 u__size_only__latch (.D(gate), .G(ck_inv), .Q(gate_latched), .QN());

    // Gate clock with latched enable
    AND2X1 u__size_only__and (.A(CK), .B(gate_latched), .Y(Q));

endmodule
