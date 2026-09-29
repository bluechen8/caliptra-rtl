// SPDX-License-Identifier: Apache-2.0
// Copyright 2018 Western Digital Corporation or it's affiliates.
// 
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// 
// http://www.apache.org/licenses/LICENSE-2.0
// 
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//------------------------------------------------------------------------------------
//
//  Copyright Western Digital, 2019
//  Owner : Alex Grobman
//  Description:  
//                This module Synchronizes the signals between JTAG (TCK) and
//                processor (Core_clk)
//
//-------------------------------------------------------------------------------------

module dmi_jtag_to_core_sync (
// JTAG signals
input       rd_en,      // 1 bit  Read Enable from JTAG
input       wr_en,      // 1 bit  Write enable from JTAG

// Processor Signals
input       rst_n,      // Core reset
input       clk,        // Core clock

output      reg_en,     // 1 bit  Write interface bit to Processor
output      reg_wr_en   // 1 bit  Write enable to Processor
);
  
wire        c_rd_en;
wire        c_wr_en;

// Outputs
assign reg_en    = c_wr_en | c_rd_en;
assign reg_wr_en = c_wr_en;

`ifdef CALIPTRA_SYNTH_SKY130

wire [2:0] rden, wren;

// rd_en synchronizer chain (3 stages)
DFFRX1 u_rden_ff0 (.CK(clk), .D(rd_en),   .RN(rst_n), .Q(rden[0]), .QN());
DFFRX1 u_rden_ff1 (.CK(clk), .D(rden[0]), .RN(rst_n), .Q(rden[1]), .QN());
DFFRX1 u_rden_ff2 (.CK(clk), .D(rden[1]), .RN(rst_n), .Q(rden[2]), .QN());

// wr_en synchronizer chain (3 stages)
DFFRX1 u_wren_ff0 (.CK(clk), .D(wr_en),   .RN(rst_n), .Q(wren[0]), .QN());
DFFRX1 u_wren_ff1 (.CK(clk), .D(wren[0]), .RN(rst_n), .Q(wren[1]), .QN());
DFFRX1 u_wren_ff2 (.CK(clk), .D(wren[1]), .RN(rst_n), .Q(wren[2]), .QN());

`else

reg [2:0]   rden, wren;

// synchronizers
always @ ( posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        rden <= '0;
        wren <= '0;
    end
    else begin
        rden <= {rden[1:0], rd_en};
        wren <= {wren[1:0], wr_en};
    end
end

`endif

// Edge detection
assign c_rd_en = rden[1] & ~rden[2];
assign c_wr_en = wren[1] & ~wren[2];

endmodule
