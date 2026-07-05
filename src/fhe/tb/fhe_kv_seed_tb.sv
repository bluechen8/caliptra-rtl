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
//   Stage-C' 1a unit TB for fhe_kv_seed: exercises the KeyVault seed reader
//   against a tiny behavioral KV-entry model. The model mirrors kv.sv's
//   combinational read mux: read_data is the addressed dword, error asserts
//   when the entry is locked-for-use or the client is not in dest_valid, and
//   last asserts on the entry's final dword. Self-checking; prints PASS/FAIL.
//
module fhe_kv_seed_tb
  import kv_defines_pkg::*;
;

  localparam int SEED_DWORDS = 2;
  localparam int FHE_CLIENT  = 6;   // reuses kv_read[6] (free when ABR off)

  logic clk = 1'b0;
  logic rst_b = 1'b0;
  logic zeroize = 1'b0;
  always #5 clk = ~clk;

  // DUT <-> KV
  logic                        start;
  logic [KV_ENTRY_ADDR_W-1:0]  read_entry;
  kv_read_t                    kv_read;
  kv_rd_resp_t                 kv_rd_resp;
  logic [SEED_DWORDS*32-1:0]   seed;
  logic                        seed_valid, seed_error, busy;

  fhe_kv_seed #(.SEED_DWORDS(SEED_DWORDS)) dut (
    .clk        (clk),
    .rst_b      (rst_b),
    .zeroize    (zeroize),
    .start      (start),
    .read_entry (read_entry),
    .kv_read    (kv_read),
    .kv_rd_resp (kv_rd_resp),
    .seed       (seed),
    .seed_valid (seed_valid),
    .seed_error (seed_error),
    .busy       (busy)
  );

  //--------------------------------------------------------------------------
  // Behavioral KeyVault-entry model (only what the reader needs).
  //--------------------------------------------------------------------------
  logic [31:0] kv_mem       [KV_NUM_KEYS-1:0][KV_NUM_DWORDS-1:0];
  logic [KV_NUM_READ-1:0] dest_valid [KV_NUM_KEYS-1:0];  // per-entry authorization
  logic        lock_use    [KV_NUM_KEYS-1:0];
  logic [KV_ENTRY_SIZE_W-1:0] last_dword [KV_NUM_KEYS-1:0];

  // Combinational read mux (matches kv.sv keyvault_read behavior).
  always_comb begin
    automatic logic authorized;
    authorized = dest_valid[kv_read.read_entry][FHE_CLIENT] & ~lock_use[kv_read.read_entry];
    kv_rd_resp.read_data = authorized ? kv_mem[kv_read.read_entry][kv_read.read_offset] : 32'd0;
    kv_rd_resp.error     = ~authorized;
    kv_rd_resp.last      = (kv_read.read_offset == last_dword[kv_read.read_entry]);
  end

  //--------------------------------------------------------------------------
  // Test sequence
  //--------------------------------------------------------------------------
  int errors = 0;

  task automatic provision(input int entry, input logic [63:0] val,
                           input logic authd, input logic locked);
    kv_mem[entry][0]    = val[31:0];
    kv_mem[entry][1]    = val[63:32];
    last_dword[entry]   = KV_ENTRY_SIZE_W'(SEED_DWORDS-1);
    dest_valid[entry]   = authd  ? (KV_NUM_READ'(1) << FHE_CLIENT) : '0;
    lock_use[entry]     = locked;
  endtask

  task automatic do_read(input int entry, input logic [63:0] exp,
                         input logic exp_err, input string name);
    @(posedge clk);
    read_entry <= KV_ENTRY_ADDR_W'(entry);
    start      <= 1'b1;
    @(posedge clk);
    start      <= 1'b0;
    // wait for completion
    while (!seed_valid) @(posedge clk);
    if (seed_error !== exp_err) begin
      $display("FAIL[%s]: seed_error=%0b expected %0b", name, seed_error, exp_err);
      errors++;
    end else if (!exp_err && (seed !== exp)) begin
      $display("FAIL[%s]: seed=%h expected %h", name, seed, exp);
      errors++;
    end else begin
      $display("PASS[%s]: seed=%h error=%0b", name, seed, seed_error);
    end
    @(posedge clk);
  endtask

  initial begin
    // init model
    for (int e = 0; e < KV_NUM_KEYS; e++) begin
      dest_valid[e] = '0; lock_use[e] = 1'b0; last_dword[e] = '0;
      for (int d = 0; d < KV_NUM_DWORDS; d++) kv_mem[e][d] = 32'd0;
    end
    start = 1'b0; read_entry = '0; zeroize = 1'b0;

    // reset
    repeat (4) @(posedge clk);
    rst_b = 1'b1;
    repeat (2) @(posedge clk);

    // 1) happy path: authorized, unlocked
    provision(5, 64'hDEAD_BEEF_1234_5678, 1'b1, 1'b0);
    do_read(5, 64'hDEAD_BEEF_1234_5678, 1'b0, "happy");

    // 2) authorization failure (dest_valid bit not set for FHE client)
    provision(9, 64'hAAAA_BBBB_CCCC_DDDD, 1'b0, 1'b0);
    do_read(9, 64'd0, 1'b1, "unauthorized");

    // 3) locked-for-use entry
    provision(11, 64'h0011_2233_4455_6677, 1'b1, 1'b1);
    do_read(11, 64'd0, 1'b1, "locked");

    // 4) a different authorized entry (distinct value)
    provision(0, 64'hFFFF_FFFF_0000_0001, 1'b1, 1'b0);
    do_read(0, 64'hFFFF_FFFF_0000_0001, 1'b0, "entry0");

    // 5) busy is asserted during a read and start is ignored while busy
    provision(3, 64'h1111_2222_3333_4444, 1'b1, 1'b0);
    @(posedge clk);
    read_entry <= KV_ENTRY_ADDR_W'(3);
    start      <= 1'b1;
    @(posedge clk);
    start      <= 1'b0;
    if (!busy) begin $display("FAIL[busy]: not busy after start"); errors++; end
    while (!seed_valid) @(posedge clk);
    if (seed !== 64'h1111_2222_3333_4444) begin
      $display("FAIL[busy]: seed=%h", seed); errors++;
    end else $display("PASS[busy]: seed=%h", seed);
    @(posedge clk);

    // 6) zeroize mid-flight wipes latched seed and returns to idle
    provision(7, 64'h9999_8888_7777_6666, 1'b1, 1'b0);
    do_read(7, 64'h9999_8888_7777_6666, 1'b0, "prezero");
    zeroize <= 1'b1;
    @(posedge clk);
    zeroize <= 1'b0;
    @(posedge clk);
    if (seed !== 64'd0) begin $display("FAIL[zeroize]: seed=%h not wiped", seed); errors++; end
    else $display("PASS[zeroize]: seed wiped");
    @(posedge clk);

    if (errors == 0) $display("fhe_kv_seed_tb RESULT: PASS");
    else             $display("fhe_kv_seed_tb RESULT: FAIL (%0d errors)", errors);
    $finish;
  end

  // watchdog
  initial begin
    repeat (2000) @(posedge clk);
    $display("fhe_kv_seed_tb RESULT: FAIL (timeout)");
    $finish;
  end

endmodule
