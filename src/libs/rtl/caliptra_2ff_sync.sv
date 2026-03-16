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

// logic din_ff;

// always_ff@(posedge clk or negedge rst_b) begin
//     if(!rst_b) begin
//         dout <= RST_VAL;
//         din_ff <= RST_VAL;
//     end
//     else begin 
//         din_ff <= din;
//         dout <= din_ff;
//     end
// end

genvar i;
   logic [WIDTH-1:0] stage1;

   generate
      // Loop through each bit of the bus
      for (i = 0; i < WIDTH; i++) begin : gen_sync_cell
         
         // Instantiate the specific Foundry Synchronizer Cell
         // REPLACE 'FOUNDRY_SYNC_CELL_NAME' with the actual cell name (e.g., SYNC2_D1_SS)

         // need to chain 2 flip flops together to create a sync cell
      DFFX1 u_sync_ff0 (
        .CK (clk),
        .D  (din[i]),
        .Q  (stage1[i]),
        .QN ()          // optional, leave unconnected
      );

      DFFX1 u_sync_ff1 (
        .CK (clk),
        .D  (stage1[i]),
        .Q  (dout[i]),
        .QN ()
      );
      end
endgenerate



endmodule