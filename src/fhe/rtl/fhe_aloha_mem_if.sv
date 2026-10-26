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
// Shared-SRAM boundary. SRAM_REUSE=1 uses packed 64-bit message banks,
// two 64-bit FFT bank pairs, the one-limb resident key K and the CROM.
// The ntt_v request names address K: like M, 64-bit rows with a sample byte
// (the ternary secret) and byte masks, N/2 rows per parity at any L. Retired
// ntt_key/e0/vt/sk-copy ports remain for the standalone reference mode only;
// the integrated Chisel implementation does not instantiate their storage.
// Module-facing read/write requests are time-multiplexed onto physical 1RW
// SRAM by the READ/EXECUTE/WRITE adapter; these are not physical 1R1W ports.

// Ring dimension N drives the poly-bank address widths (LOGN = $clog2(N)).
// Mirror aloha_bram_behav.sv's guard so the interface widths track FHE_N even
// when this file is compiled before the datapath (default = the 8192 max).
`ifndef FHE_N
  `define FHE_N 8192
`endif
`ifndef FHE_L
  `define FHE_L 2
`endif
// SDP poly banks (ntt_*/FFT working banks): N/2 entries => LOGN-1 addr bits.
`define ALOHA_SDP_AW ($clog2(`FHE_N) - 1)
// SP poly banks (e0/e1/vt): N entries => LOGN addr bits.
`define ALOHA_SP_AW  ($clog2(`FHE_N))
// CROM holds exactly FHE_L installed prime profiles after the fixed prefix.
`ifndef FHE_CROM_AW
  `define FHE_CROM_AW ($clog2(128 + `FHE_L*($clog2(`FHE_N)+26)))
`endif

// ---- per-bank signal groups ------------------------------------------------
`define ALOHA_MEM_SDP_SIG(_W, _AW, _sig)                                        \
  logic               ``_sig``_wea;                                            \
  logic [_AW-1:0]     ``_sig``_addra;                                          \
  logic [_W-1:0]      ``_sig``_dina;                                           \
  logic [_AW-1:0]     ``_sig``_addrb;                                          \
  logic [_W-1:0]      ``_sig``_doutb;

`define ALOHA_MEM_SP_SIG(_W, _AW, _sig)                                         \
  logic               ``_sig``_wea;                                            \
  logic [_AW-1:0]     ``_sig``_addra;                                          \
  logic [_W-1:0]      ``_sig``_dina;                                           \
  logic [_W-1:0]      ``_sig``_douta;

`define ALOHA_MEM_ROM_SIG(_W, _AW, _sig)                                        \
  logic [_AW-1:0]     ``_sig``_addra;                                          \
  logic [_W-1:0]      ``_sig``_douta;                                          \
  logic               ``_sig``_wea;                                            \
  logic [_AW-1:0]     ``_sig``_wa;                                             \
  logic [_W-1:0]      ``_sig``_wd;

// ---- modport direction groups (req = ComputeCore, resp = storage) ----------
`define ALOHA_MEM_SDP_REQ(_sig)                                                 \
  output ``_sig``_wea, ``_sig``_addra, ``_sig``_dina, ``_sig``_addrb,           \
  input  ``_sig``_doutb
`define ALOHA_MEM_SDP_RESP(_sig)                                                \
  input  ``_sig``_wea, ``_sig``_addra, ``_sig``_dina, ``_sig``_addrb,           \
  output ``_sig``_doutb

`define ALOHA_MEM_SP_REQ(_sig)                                                  \
  output ``_sig``_wea, ``_sig``_addra, ``_sig``_dina,                           \
  input  ``_sig``_douta
`define ALOHA_MEM_SP_RESP(_sig)                                                 \
  input  ``_sig``_wea, ``_sig``_addra, ``_sig``_dina,                           \
  output ``_sig``_douta

`define ALOHA_MEM_ROM_REQ(_sig)                                                 \
  output ``_sig``_addra, ``_sig``_wea, ``_sig``_wa, ``_sig``_wd, input ``_sig``_douta
`define ALOHA_MEM_ROM_RESP(_sig)                                                \
  input  ``_sig``_addra, ``_sig``_wea, ``_sig``_wa, ``_sig``_wd, output ``_sig``_douta

interface fhe_aloha_mem_if;
  // eng_step: the core takes its step this clock; the working arrays sample
  // the step's requests on it. eng_stall: an array cannot take this step
  // (fhe_ilv_bank), so the core holds for a clock.
  logic eng_step, eng_stall;

  logic [7:0] ntt_msg0_mask, ntt_msg1_mask;
  logic [7:0] ntt_v0_mask, ntt_v1_mask;
  logic sk_en, sk_we;
  logic [$clog2(`FHE_N*`FHE_L)-1:0] sk_addr;
  logic [53:0] sk_wdata, sk_rdata;

  // M and K are 64-bit with byte masks; ntt_v ports are resident K.
  // e1/key requests below are retained for reference-mode compatibility.
  `ALOHA_MEM_SDP_SIG(64, `ALOHA_SDP_AW, ntt_msg0)
  `ALOHA_MEM_SDP_SIG(64, `ALOHA_SDP_AW, ntt_msg1)
  `ALOHA_MEM_SDP_SIG(64, `ALOHA_SDP_AW, ntt_v0)
  `ALOHA_MEM_SDP_SIG(64, `ALOHA_SDP_AW, ntt_v1)
  `ALOHA_MEM_SDP_SIG(54, `ALOHA_SDP_AW, ntt_e1_0)
  `ALOHA_MEM_SDP_SIG(54, `ALOHA_SDP_AW, ntt_e1_1)
  `ALOHA_MEM_SDP_SIG(54, `ALOHA_SDP_AW, ntt_key0)
  `ALOHA_MEM_SDP_SIG(54, `ALOHA_SDP_AW, ntt_key1)
  // 2x CBDPolyBRAM (6b) + 1x TernaryPolyBRAM (2b) : x N (LOGN addr), single-port
  `ALOHA_MEM_SP_SIG(6, `ALOHA_SP_AW, e0)
  `ALOHA_MEM_SP_SIG(6, `ALOHA_SP_AW, e1)
  `ALOHA_MEM_SP_SIG(2, `ALOHA_SP_AW, vt)
  // FFT real/imaginary: both 64 bits. Lower doubles as a/c1; higher holds
  // the encoded real vector across limbs. Lower READ_FIRST, higher WRITE_FIRST.
  `ALOHA_MEM_SDP_SIG(64, `ALOHA_SDP_AW, fft_lower0)
  `ALOHA_MEM_SDP_SIG(64, `ALOHA_SDP_AW, fft_lower1)
  `ALOHA_MEM_SDP_SIG(64, `ALOHA_SDP_AW, fft_higher0)
  `ALOHA_MEM_SDP_SIG(64, `ALOHA_SDP_AW, fft_higher1)
  // CROM depth is nextPow2(128 + FHE_L*(LOGN+26)). The core reads addra; VeeR
  // firmware writes wea/wa/wd through fhe_top's CROM window while the engine is
  // idle. FFT twiddles are always generated, so there is no stored twiddle table.
  `ALOHA_MEM_ROM_SIG(128, `FHE_CROM_AW, crom)

  modport req (
    output eng_step, input eng_stall,
    output ntt_msg0_mask, ntt_msg1_mask, ntt_v0_mask, ntt_v1_mask,
    output sk_en, sk_we, sk_addr, sk_wdata, input sk_rdata,
    `ALOHA_MEM_SDP_REQ(ntt_msg0),
    `ALOHA_MEM_SDP_REQ(ntt_msg1),
    `ALOHA_MEM_SDP_REQ(ntt_v0),
    `ALOHA_MEM_SDP_REQ(ntt_v1),
    `ALOHA_MEM_SDP_REQ(ntt_e1_0),
    `ALOHA_MEM_SDP_REQ(ntt_e1_1),
    `ALOHA_MEM_SDP_REQ(ntt_key0),
    `ALOHA_MEM_SDP_REQ(ntt_key1),
    `ALOHA_MEM_SP_REQ(e0),
    `ALOHA_MEM_SP_REQ(e1),
    `ALOHA_MEM_SP_REQ(vt),
    `ALOHA_MEM_SDP_REQ(fft_lower0),
    `ALOHA_MEM_SDP_REQ(fft_lower1),
    `ALOHA_MEM_SDP_REQ(fft_higher0),
    `ALOHA_MEM_SDP_REQ(fft_higher1),
    `ALOHA_MEM_ROM_REQ(crom)
  );

  modport resp (
    input eng_step, output eng_stall,
    input ntt_msg0_mask, ntt_msg1_mask, ntt_v0_mask, ntt_v1_mask,
    input sk_en, sk_we, sk_addr, sk_wdata, output sk_rdata,
    `ALOHA_MEM_SDP_RESP(ntt_msg0),
    `ALOHA_MEM_SDP_RESP(ntt_msg1),
    `ALOHA_MEM_SDP_RESP(ntt_v0),
    `ALOHA_MEM_SDP_RESP(ntt_v1),
    `ALOHA_MEM_SDP_RESP(ntt_e1_0),
    `ALOHA_MEM_SDP_RESP(ntt_e1_1),
    `ALOHA_MEM_SDP_RESP(ntt_key0),
    `ALOHA_MEM_SDP_RESP(ntt_key1),
    `ALOHA_MEM_SP_RESP(e0),
    `ALOHA_MEM_SP_RESP(e1),
    `ALOHA_MEM_SP_RESP(vt),
    `ALOHA_MEM_SDP_RESP(fft_lower0),
    `ALOHA_MEM_SDP_RESP(fft_lower1),
    `ALOHA_MEM_SDP_RESP(fft_higher0),
    `ALOHA_MEM_SDP_RESP(fft_higher1),
    `ALOHA_MEM_ROM_RESP(crom)
  );

endinterface
