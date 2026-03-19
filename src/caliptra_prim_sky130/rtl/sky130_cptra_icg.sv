// SPDX-License-Identifier: Apache-2.0
//
// Sky130-specific Integrated Clock Gate for Caliptra.
// Replaces behavioral cptra_clk_gate with sky130_fd_sc_hd__dlclkp_1.
// Used when TECH_SPECIFIC_ICG and USER_ICG=sky130_cptra_icg are defined.

module sky130_cptra_icg (
    input  logic clk,
    input  logic en,
    output       clk_cg
);

    ICGX1 u_gater_CALIPTRA_ICG (
        .E  (en),
        .CK (clk),
        .ECK(clk_cg)
    );

endmodule
