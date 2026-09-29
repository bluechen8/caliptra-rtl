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

module caliptra_2ff_sync  #( parameter WIDTH=1,
                             parameter RST_VAL=0)
    (
    input logic clk,
    input logic rst_b,
    input logic [WIDTH-1:0] din,
    output logic [WIDTH-1:0] dout

);

`ifdef CALIPTRA_SYNTH_SKY130

genvar i;
logic [WIDTH-1:0] stage1;

generate
    for (i = 0; i < WIDTH; i++) begin : gen_sync_cell
        if (RST_VAL == 0) begin : gen_rst0
            DFFRX1 u_sync_ff0 (
                .CK (clk),
                .D  (din[i]),
                .RN (rst_b),
                .Q  (stage1[i]),
                .QN ()
            );
            DFFRX1 u_sync_ff1 (
                .CK (clk),
                .D  (stage1[i]),
                .RN (rst_b),
                .Q  (dout[i]),
                .QN ()
            );
        end else begin : gen_rst1
            DFFSX1 u_sync_ff0 (
                .CK (clk),
                .D  (din[i]),
                .SN (rst_b),
                .Q  (stage1[i]),
                .QN ()
            );
            DFFSX1 u_sync_ff1 (
                .CK (clk),
                .D  (stage1[i]),
                .SN (rst_b),
                .Q  (dout[i]),
                .QN ()
            );
        end
    end
endgenerate

`else

logic din_ff;

always_ff@(posedge clk or negedge rst_b) begin
    if(!rst_b) begin
        dout <= RST_VAL;
        din_ff <= RST_VAL;
    end
    else begin
        din_ff <= din;
        dout <= din_ff;
    end
end

`endif

endmodule
