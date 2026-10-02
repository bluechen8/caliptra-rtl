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
// two 64-bit FFT bank pairs, banked 54-bit resident keys and the two tables.
// The ntt_v request names now address resident K with a limb offset. Retired
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
// crom (RNS consts + bounded twiddle cache): words = 344 + 8*LOGN (a function of
// LOGN, NOT proportional to N -- see GenerateConstantsROM.py). Address width =
// $clog2(words); resolves to 9b (512 words) for all N up to 2^21, then grows.
`ifndef FHE_CROM_AW
  `define FHE_CROM_AW ($clog2(344 + 8*$clog2(`FHE_N)))
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
  logic [_W-1:0]      ``_sig``_douta;

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

`define ALOHA_MEM_ROM_REQ(_sig)   output ``_sig``_addra, input  ``_sig``_douta
`define ALOHA_MEM_ROM_RESP(_sig)  input  ``_sig``_addra, output ``_sig``_douta

interface fhe_aloha_mem_if;
  // Three physical clock edges per logical ComputeCore edge. Requests are
  // sampled in READ, the core advances in EXECUTE, saved writes retire in WRITE.
  logic phase_read, phase_execute, phase_write, table_load_ready;

  logic [7:0] ntt_msg0_mask, ntt_msg1_mask;
  logic sk_en, sk_we;
  logic [$clog2(`FHE_N*`FHE_L)-1:0] sk_addr;
  logic [53:0] sk_wdata, sk_rdata;

  // M is 64-bit with byte masks; ntt_v ports are resident K (NL/2 per bank).
  // e1/key requests below are retained for reference-mode compatibility.
  `ALOHA_MEM_SDP_SIG(64, `ALOHA_SDP_AW, ntt_msg0)
  `ALOHA_MEM_SDP_SIG(64, `ALOHA_SDP_AW, ntt_msg1)
  `ALOHA_MEM_SDP_SIG(54, $clog2(`FHE_N*`FHE_L/2), ntt_v0)
  `ALOHA_MEM_SDP_SIG(54, $clog2(`FHE_N*`FHE_L/2), ntt_v1)
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
  // 1x FFTTw_RNS_ROM (crom): 128b x nextPow2(344+8*LOGN). Content is a function of
  // LOGN but NOT proportional to N (408 words @N=256, 448 @N=8192); the addr width
  // is 9b (512 words) for all N up to 2^21, then auto-grows.
  `ALOHA_MEM_ROM_SIG(128, `FHE_CROM_AW, crom)
  // 1x FFTAllTwiddleROM : 128b x N/2 (LOGN-1 addr), stored FFT twiddles.
  `ALOHA_MEM_ROM_SIG(128, `ALOHA_SDP_AW, ftwrom)

  modport req (
    output phase_read, phase_execute, phase_write, table_load_ready,
    output ntt_msg0_mask, ntt_msg1_mask,
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
    `ALOHA_MEM_ROM_REQ(crom),
    `ALOHA_MEM_ROM_REQ(ftwrom)
  );

  modport resp (
    input phase_read, phase_execute, phase_write, table_load_ready,
    input ntt_msg0_mask, ntt_msg1_mask,
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
    `ALOHA_MEM_ROM_RESP(crom),
    `ALOHA_MEM_ROM_RESP(ftwrom)
  );

endinterface
