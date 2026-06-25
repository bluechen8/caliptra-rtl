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
//   SRAM interface bundle for the FHE accelerator banks. Modeled on
//   abr_mem_if.sv. All banks share FHE_MEM_DATA_WIDTH (= COEFF_PER_CLK*32);
//   each bank carries its own address width from fhe_params_pkg.
//
//   Banks: poly_c0 / poly_c1 (ciphertext), scratch (NTT in-place / a / accum),
//          key (pk/evk/galois staging), encode (fixed-point FFT scratch),
//          sk (NTT-domain secret key during decrypt).
//

import fhe_params_pkg::*;

`define FHE_MEM_IF_SIGNALS(_ADDR_W, _sig)\
logic ``_sig``_we_i;\
logic [_ADDR_W-1:0] ``_sig``_waddr_i;\
logic [FHE_MEM_DATA_WIDTH-1:0] ``_sig``_wdata_i;\
logic ``_sig``_re_i;\
logic [_ADDR_W-1:0] ``_sig``_raddr_i;\
logic [FHE_MEM_DATA_WIDTH-1:0] ``_sig``_rdata_o;

`define FHE_MEM_IF_REQ_PORTS(_sig)\
  output ``_sig``_we_i, ``_sig``_waddr_i, ``_sig``_wdata_i, ``_sig``_re_i, ``_sig``_raddr_i,\
  input ``_sig``_rdata_o

`define FHE_MEM_IF_RESP_PORTS(_sig)\
  input ``_sig``_we_i, ``_sig``_waddr_i, ``_sig``_wdata_i, ``_sig``_re_i, ``_sig``_raddr_i,\
  output ``_sig``_rdata_o

interface fhe_mem_if;

  `FHE_MEM_IF_SIGNALS(FHE_MEM_C0_ADDR_W,      poly_c0)
  `FHE_MEM_IF_SIGNALS(FHE_MEM_C1_ADDR_W,      poly_c1)
  `FHE_MEM_IF_SIGNALS(FHE_MEM_SCRATCH_ADDR_W, scratch)
  `FHE_MEM_IF_SIGNALS(FHE_MEM_KEY_ADDR_W,     key)
  `FHE_MEM_IF_SIGNALS(FHE_MEM_ENCODE_ADDR_W,  encode)
  `FHE_MEM_IF_SIGNALS(FHE_MEM_SK_ADDR_W,      sk)

  modport req (
    `FHE_MEM_IF_REQ_PORTS(poly_c0),
    `FHE_MEM_IF_REQ_PORTS(poly_c1),
    `FHE_MEM_IF_REQ_PORTS(scratch),
    `FHE_MEM_IF_REQ_PORTS(key),
    `FHE_MEM_IF_REQ_PORTS(encode),
    `FHE_MEM_IF_REQ_PORTS(sk)
  );

  modport resp (
    `FHE_MEM_IF_RESP_PORTS(poly_c0),
    `FHE_MEM_IF_RESP_PORTS(poly_c1),
    `FHE_MEM_IF_RESP_PORTS(scratch),
    `FHE_MEM_IF_RESP_PORTS(key),
    `FHE_MEM_IF_RESP_PORTS(encode),
    `FHE_MEM_IF_RESP_PORTS(sk)
  );

endinterface
