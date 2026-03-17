// SPDX-License-Identifier: Apache-2.0
//
// Sky130-specific Integrated Clock Gate for VeeR RISC-V core.
// Replaces behavioral TEC_RV_ICG with sky130_fd_sc_hd__dlclkp_1.
// Used when TECH_SPECIFIC_EC_RV_ICG and USER_EC_RV_ICG=sky130_rv_icg are defined.

module sky130_rv_icg (
    input  logic SE,
    input  logic EN,
    input  logic CK,
    output       Q
);

    logic gate;
    assign gate = EN | SE;

    ICGX1 u_icg (
        .D (CK),
        .G (gate),
        .Y (Q)
    );

endmodule
