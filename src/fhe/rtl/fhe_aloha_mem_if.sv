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
//   C'-3 SRAM-macro routing. Bundles the Aloha-HE ComputeCore's internal
//   storage banks so they can be LIFTED out of the vendored RTL to the
//   caliptra_top / CaliptraCoreBlackbox boundary and instantiated as real
//   SRAM on the Chisel side (SyncReadMem -> FIRRTL mems.conf -> Sky130 macro),
//   exactly like the VeeR ICCM/DCCM banks. Modeled on abr_mem_if.sv /
//   fhe_mem_if.sv but carries each bank's NATIVE Aloha wrapper port shape and
//   latency contract (aloha_bram_behav.sv): the behavioral bank wrappers live
//   in a fhe_aloha_mem_top module (instantiated in the standalone TBs, and in
//   CaliptraCoreBlackbox for the SoC) so the original TBs keep running.
//
//   Rung 1a scope = the 12 banks instantiated DIRECTLY in ComputeCore.v:
//     8x NTTPolyBank    (simple-dual-port, 54b x 4096, 12b addr, READ_FIRST)
//         ntt_msg0/1, ntt_v0/1, ntt_e1_0/1, ntt_key0/1
//     2x CBDPolyBRAM    (single-port,      6b  x 8192, 13b addr, WRITE_FIRST)
//         e0, e1
//     1x TernaryPolyBRAM(single-port,      2b  x 8192, 13b addr, WRITE_FIRST)
//         vt
//     1x FFTTw_RNS_ROM  (single-port ROM,  128b x 512, 9b  addr)
//         crom
//   plus the stored FFT-twiddle ROM lifted from FFTTwFctStorage (2 hops up through
//   UnifiedTransformation):
//     1x FFTAllTwiddleROM(single-port ROM,  128b x 4096, 12b addr)
//         ftwrom
//   (SharedFFTBrams -- the 74b FFT banks -- are lifted in a later rung.)
//
//   The ntt_e1_* banks are only DRIVEN in the pk reference path (SCHEME==0);
//   the sk product path (SCHEME==1) drops them (C'-3 Part 1), so ComputeCore
//   ties the e1 request side off and the top-side storage may omit them.

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

  // 8x NTTPolyBank : 54b x 4096 (12b addr), simple-dual-port
  `ALOHA_MEM_SDP_SIG(54, 12, ntt_msg0)
  `ALOHA_MEM_SDP_SIG(54, 12, ntt_msg1)
  `ALOHA_MEM_SDP_SIG(54, 12, ntt_v0)
  `ALOHA_MEM_SDP_SIG(54, 12, ntt_v1)
  `ALOHA_MEM_SDP_SIG(54, 12, ntt_e1_0)
  `ALOHA_MEM_SDP_SIG(54, 12, ntt_e1_1)
  `ALOHA_MEM_SDP_SIG(54, 12, ntt_key0)
  `ALOHA_MEM_SDP_SIG(54, 12, ntt_key1)
  // 2x CBDPolyBRAM (6b) + 1x TernaryPolyBRAM (2b) : x 8192 (13b addr), single-port
  `ALOHA_MEM_SP_SIG(6, 13, e0)
  `ALOHA_MEM_SP_SIG(6, 13, e1)
  `ALOHA_MEM_SP_SIG(2, 13, vt)
  // 1x FFTTw_RNS_ROM : 128b x 512 (9b addr), single-port ROM
  `ALOHA_MEM_ROM_SIG(128, 9, crom)
  // 1x FFTAllTwiddleROM : 128b x 4096 (12b addr), stored FFT twiddles
  `ALOHA_MEM_ROM_SIG(128, 12, ftwrom)

  modport req (
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
    `ALOHA_MEM_ROM_REQ(crom),
    `ALOHA_MEM_ROM_REQ(ftwrom)
  );

  modport resp (
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
    `ALOHA_MEM_ROM_RESP(crom),
    `ALOHA_MEM_ROM_RESP(ftwrom)
  );

endinterface
