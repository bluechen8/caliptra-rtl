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
`ifndef FHE_CFG_SV
`define FHE_CFG_SV

  // Instantiate one FHE SRAM bank wired to the fhe_memory_export interface.
  // Mirrors the `ABR_MEM macro pattern.
  `define FHE_MEM(_depth, _width, _mem_name) \
  fhe_1r1w_ram \
  #( .DEPTH(``_depth``), \
     .DATA_WIDTH(``_width``)) \
   fhe_``_mem_name``_inst \
   (\
      .clk_i(clk_i),\
      .we_i(fhe_memory_export.``_mem_name``_we_i),\
      .waddr_i(fhe_memory_export.``_mem_name``_waddr_i),\
      .wdata_i(fhe_memory_export.``_mem_name``_wdata_i),\
      .re_i(fhe_memory_export.``_mem_name``_re_i),\
      .raddr_i(fhe_memory_export.``_mem_name``_raddr_i),\
      .rdata_o(fhe_memory_export.``_mem_name``_rdata_o)\
   );

`endif
