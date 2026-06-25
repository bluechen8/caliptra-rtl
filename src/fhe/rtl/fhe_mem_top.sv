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
//   Instantiates the FHE accelerator SRAM banks against the fhe_memory_export
//   interface. Mirrors abr_mem_top.sv. In the Chipyard flow this module is
//   instantiated inside CaliptraCoreBlackbox.sv (hoisted, same as abr_mem_top)
//   so the synthesis flow can map the banks to Sky130 macros.
//
`include "fhe_config_defines.svh"
module fhe_mem_top
  import fhe_params_pkg::*;
(
  input logic clk_i,
  fhe_mem_if.resp fhe_memory_export
);

`FHE_MEM(FHE_MEM_C0_DEPTH,      FHE_MEM_DATA_WIDTH, poly_c0)
`FHE_MEM(FHE_MEM_C1_DEPTH,      FHE_MEM_DATA_WIDTH, poly_c1)
`FHE_MEM(FHE_MEM_SCRATCH_DEPTH, FHE_MEM_DATA_WIDTH, scratch)
`FHE_MEM(FHE_MEM_KEY_DEPTH,     FHE_MEM_DATA_WIDTH, key)
`FHE_MEM(FHE_MEM_ENCODE_DEPTH,  FHE_MEM_DATA_WIDTH, encode)
`FHE_MEM(FHE_MEM_SK_DEPTH,      FHE_MEM_DATA_WIDTH, sk)

endmodule
