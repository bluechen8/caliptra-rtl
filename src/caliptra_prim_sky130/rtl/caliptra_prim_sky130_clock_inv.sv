// SPDX-License-Identifier: Apache-2.0
//
// Sky130-specific clock inverter primitive for Caliptra.
// Replaces caliptra_prim_generic_clock_inv with sky130_fd_sc_hd cells.

`include "caliptra_prim_module_name_macros.svh"

module caliptra_prim_sky130_clock_inv #(
  parameter bit HasScanMode = 1'b1,
  parameter bit NoFpgaBufG  = 1'b0 // unused in ASIC implementation
) (
  input        clk_i,
  input        scanmode_i,
  output logic clk_no
);

  if (HasScanMode) begin : gen_scan
    // In scan mode, bypass the inverter (pass clk_i through).
    // Use the sky130 clock mux2 wrapper for glitch-free switching.
    `CALIPTRA_PRIM_MODULE_NAME(clock_mux2) #(
      .NoFpgaBufG(NoFpgaBufG)
    ) i_dft_tck_mux (
      .clk0_i ( ~clk_i     ),
      .clk1_i ( clk_i      ), // bypass the inverted clock for testing
      .sel_i  ( scanmode_i ),
      .clk_o  ( clk_no     )
    );
  end else begin : gen_noscan
    logic unused_scanmode;
    assign unused_scanmode = scanmode_i;
    sky130_fd_sc_hd__clkinv_1 u__size_only__clk_inv (
      .A(clk_i),
      .Y(clk_no)
    );
  end

endmodule : caliptra_prim_sky130_clock_inv
