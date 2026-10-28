// SPDX-License-Identifier: Apache-2.0
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
//
// Description:
//   Self-contained AHB-Lite slave interface for the FHE accelerator.
//   Functionally equivalent to abr_ahb_slv_sif (64-bit AHB / 32-bit client
//   case) but with no dependency on the Adams Bridge packages, so the FHE
//   block builds when CALIPTRA_NO_ADAMS_BRIDGE is set. Writes must be 32-bit
//   (HSIZE = 2); others get an ERROR response.
//
module fhe_ahb_slv_sif #(
    parameter AHB_DATA_WIDTH    = 64,
    parameter AHB_ADDR_WIDTH    = 32,
    parameter CLIENT_DATA_WIDTH = 32,
    parameter CLIENT_ADDR_WIDTH = AHB_ADDR_WIDTH
)(
    input  logic                          hclk,
    input  logic                          hreset_n,
    input  logic [AHB_ADDR_WIDTH-1:0]     haddr_i,
    input  logic [AHB_DATA_WIDTH-1:0]     hwdata_i,
    input  logic                          hsel_i,
    input  logic                          hwrite_i,
    input  logic                          hready_i,
    input  logic [1:0]                    htrans_i,
    input  logic [2:0]                    hsize_i,

    output logic                          hresp_o,
    output logic                          hreadyout_o,
    output logic [AHB_DATA_WIDTH-1:0]     hrdata_o,

    // Component (client) interface
    output logic                          dv,
    input  logic                          hld,
    input  logic                          err,
    output logic                          write,
    output logic [CLIENT_DATA_WIDTH-1:0]  wdata,
    output logic [CLIENT_ADDR_WIDTH-1:0]  addr,
    input  logic [CLIENT_DATA_WIDTH-1:0]  rdata
);

    localparam logic H_OKAY  = 1'b0;
    localparam logic H_ERROR = 1'b1;

    // An ERROR response is two cycles. The first comes from the client's err;
    // the second is the slave's own (err_2nd), with dv hidden from the client
    // so the rejected access is neither repeated nor completed.
    // Every FHE register and CROM lane is a 32-bit word with no byte enables,
    // so a write of any other size is refused with an ERROR response
    // (bad_size, latched in the address phase) and never reaches the client.
    logic dv_q, err_2nd, bad_size;
    wire  err_any  = err | bad_size;
    wire  ahb_xfer = hsel_i & (htrans_i inside {2'b10, 2'b11});
    assign dv = dv_q & ~err_2nd & ~bad_size;

    // 64-bit AHB, 32-bit client: select the addressed word.
    assign wdata = addr[2] ? hwdata_i[63:32] : hwdata_i[31:0];
    always_comb hrdata_o = addr[2] ? {rdata, 32'b0} : {32'b0, rdata};

    always_ff @(posedge hclk or negedge hreset_n) begin
        if (!hreset_n) begin
            dv_q     <= 1'b0;
            write    <= 1'b0;
            addr     <= '0;
            err_2nd  <= 1'b0;
            bad_size <= 1'b0;
        end else begin
            err_2nd <= err_any & ~err_2nd;
            if (hready_i) begin
                dv_q     <= ahb_xfer;
                bad_size <= ahb_xfer & hwrite_i & (hsize_i != 3'b010);
            end
            if (hready_i & hsel_i) begin
                addr  <= haddr_i[CLIENT_ADDR_WIDTH-1:0];
                write <= hwrite_i & |htrans_i;
            end
        end
    end

    always_comb begin : response_block
        hreadyout_o = 1'b1;
        hresp_o     = H_OKAY;
        if (err_2nd) begin
            // second error cycle: ready high, error still asserted
            hreadyout_o = 1'b1;
            hresp_o     = H_ERROR;
        end else if (err_any) begin
            // first error cycle: de-assert ready, drive error
            hreadyout_o = 1'b0;
            hresp_o     = H_ERROR;
        end else if (hld) begin
            hreadyout_o = 1'b0;
        end
    end

endmodule
