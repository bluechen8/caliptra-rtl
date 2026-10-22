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
//   One Aloha working array (M, A, R or K, one parity half) built from four
//   single-port sub-banks, so an engine step can read and write the array in
//   one clock. It behaves exactly like an ideal one-read/one-write memory with
//   Aloha's two-step read latency:
//     * the read at step k returns the array as it stood before step k's write,
//       except `forward` bits, which take step k's write to the same address;
//     * that data is on q from the step after next (step k+2 samples it).
//
//   A row's sub-bank is the XOR of all its bit pairs, which spreads Aloha's
//   power-of-two strides; its row in that sub-bank is addr[AW-1:2]. Per clock
//   the read takes its sub-bank and each write needs another. A write that
//   cannot get one waits in a one-entry buffer and retires on the next free
//   sub-bank; reads see buffered data. The array stalls the engine for a clock
//   only when a new write finds the buffer full and cannot retire either.
//   A read whose address did not move is served from a held copy (invalidated
//   by any write to that address), so idle readers do not take a sub-bank.
//
//   The sub-banks read synchronously: data the clock after en && !we.
//   Chipyard maps each to an SRAM macro (Caliptra.scala); fhe_aloha_mem_top
//   models them for the unit testbench.
module fhe_ilv_bank #(
  parameter int W    = 64,                 // word width
  parameter int AW   = 12,                 // array address width (rows)
  parameter int GRAN = W,                  // write-mask granularity
  localparam int MW  = W / GRAN,
  localparam int SAW = AW - 2              // sub-bank address width
)(
  input  logic          clk,
  input  logic          rst_n,
  input  logic [W-1:0]  forward,           // constant: write-first bits on a same-row hit
  input  logic          step,              // the engine takes this step this clock
  output logic          stall,             // the step cannot be taken this clock
  // the engine's request for the current step
  input  logic          we,
  input  logic [AW-1:0] wa,
  input  logic [W-1:0]  wd,
  input  logic [MW-1:0] mask,
  input  logic [AW-1:0] ra,
  output logic [W-1:0]  q,
  // four 1RW sub-banks, packed {3, 2, 1, 0}
  output logic [3:0]      sb_en,
  output logic [3:0]      sb_we,
  output logic [4*SAW-1:0] sb_addr,
  output logic [4*W-1:0]   sb_wdata,
  output logic [4*MW-1:0]  sb_mask,
  input  logic [4*W-1:0]   sb_rdata
);

  function automatic logic [1:0] sub_of(input logic [AW-1:0] a);
    sub_of = '0;
    for (int i = 0; i < AW; i += 2) sub_of ^= 2'(a >> i);
  endfunction

  function automatic logic [W-1:0] bits_of(input logic [MW-1:0] m);
    for (int b = 0; b < MW; b++) bits_of[b*GRAN +: GRAN] = {GRAN{m[b]}};
  endfunction

  // write buffer
  logic          bv;
  logic [AW-1:0] ba;
  logic [W-1:0]  bd;
  logic [MW-1:0] bm;
  // the last read address; while hv, st0 (or the fresh read) is its current value
  logic          hv;
  logic [AW-1:0] ha;
  // read issued last clock, and the buffered or same-step write bits to lay over it
  logic          fresh;
  logic [1:0]    fsub;
  logic [W-1:0]  f_d, f_bits;
  logic [W-1:0]  st0;                      // read data of the last step, once in

  wire [W-1:0] s0     = (sb_rdata[fsub*W +: W] & ~f_bits) | (f_d & f_bits);
  wire [W-1:0] held   = fresh ? s0 : st0;

  // this step's plan, assuming it is taken
  wire       rd_need  = !(hv && ra == ha);
  wire [1:0] rs       = sub_of(ra);
  wire [1:0] bs       = sub_of(ba);
  wire [1:0] ns       = sub_of(wa);
  wire       b_go     = bv && !(rd_need && bs == rs);           // buffer retires this clock
  wire       b_merge  = we && bv && !b_go && (ba == wa);         // same row still waiting: merge
  wire       n_go     = we && !b_merge && !(rd_need && ns == rs) && !(b_go && bs == ns);
  wire       hit      = we && (wa == ra);
  wire [W-1:0] fwd_bits = hit ? (bits_of(mask) & forward) : '0;
  assign stall = we && !n_go && !b_merge && bv && !b_go;

  // sub-bank ports: the read, the retiring buffer and the new write, each on
  // its own sub-bank; a clock without a step only retires the buffer
  always_comb begin
    sb_en = '0; sb_we = '0; sb_addr = '0; sb_wdata = '0; sb_mask = '0;
    if (step && rd_need) begin
      sb_en[rs] = 1'b1;
      sb_addr[rs*SAW +: SAW] = ra[AW-1:2];
    end
    if (bv && (!step || b_go)) begin
      sb_en[bs] = 1'b1; sb_we[bs] = 1'b1;
      sb_addr[bs*SAW +: SAW] = ba[AW-1:2];
      sb_wdata[bs*W +: W] = bd;
      sb_mask[bs*MW +: MW] = bm;
    end
    if (step && n_go) begin
      sb_en[ns] = 1'b1; sb_we[ns] = 1'b1;
      sb_addr[ns*SAW +: SAW] = wa[AW-1:2];
      sb_wdata[ns*W +: W] = wd;
      sb_mask[ns*MW +: MW] = mask;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      bv <= 1'b0; hv <= 1'b0; fresh <= 1'b0;
    end else begin
      if (fresh) st0 <= s0;
      if (step) begin
        q <= held;
        // buffer
        if (b_merge) begin
          bd <= (bd & ~bits_of(mask)) | (wd & bits_of(mask));
          bm <= bm | mask;
        end else if (we && !n_go) begin
          bv <= 1'b1; ba <= wa; bd <= wd; bm <= mask;
        end else if (b_go) bv <= 1'b0;
        // read: from a sub-bank (data next clock) or from the held value
        fresh <= rd_need;
        ha <= ra; hv <= !hit;
        if (rd_need) begin
          fsub   <= rs;
          f_bits <= ((bv && ba == ra) ? bits_of(bm) : '0) | fwd_bits;
          f_d    <= (bd & ~fwd_bits) | (wd & fwd_bits);
        end else st0 <= (held & ~fwd_bits) | (wd & fwd_bits);
      end else begin
        fresh <= 1'b0;
        bv <= 1'b0;
      end
    end
  end

endmodule
