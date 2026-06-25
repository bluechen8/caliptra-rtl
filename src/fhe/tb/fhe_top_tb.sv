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
//   Self-checking unit testbench for fhe_top (the Stage-0 CKKS FHE stub).
//   Drives real AHB-Lite transactions through the block's responder and
//   validates the observable register/command/interrupt contract. No VeeR,
//   firmware, or Chipyard needed.
//
//   Run (from src/fhe): see tb/run_fhe_top_tb.sh, or invoke the simulator
//   with --binary --timing over rtl/*.sv + tb/fhe_top_tb.sv (+incdir+rtl).
//   Expect: "FHE_TOP_TB: TEST PASSED".
//
module fhe_top_tb
  import fhe_params_pkg::*;
;
  localparam int AW = 15;            // FHE 32KB window -> 15-bit client address
  localparam int DW = 64;            // CALIPTRA_AHB_HDATA_SIZE

  // Register byte offsets (match fhe_top / fhe_reg.rdl)
  localparam logic [AW-1:0] A_NAME0   = 'h00;
  localparam logic [AW-1:0] A_NAME1   = 'h04;
  localparam logic [AW-1:0] A_VER0    = 'h08;
  localparam logic [AW-1:0] A_CTRL    = 'h10;
  localparam logic [AW-1:0] A_STATUS  = 'h14;
  localparam logic [AW-1:0] A_SRC0    = 'h18;
  localparam logic [AW-1:0] A_DST0    = 'h20;
  localparam logic [AW-1:0] A_CONFIG  = 'h30;

  logic clk = 1'b0;
  logic rst_b;
  always #5 clk = ~clk;

  // AHB-Lite responder signals
  logic [AW-1:0] haddr;
  logic [DW-1:0] hwdata;
  logic          hsel, hwrite, hready;
  logic [1:0]    htrans;
  logic [2:0]    hsize;
  logic          hresp, hreadyout;
  logic [DW-1:0] hrdata;

  logic busy_o, error_intr, notif_intr;

  // SRAM interface + storage
  fhe_mem_if mem_if();

  fhe_top #(.AHB_DATA_WIDTH(DW), .AHB_ADDR_WIDTH(AW)) dut (
    .clk(clk), .rst_b(rst_b),
    .haddr_i(haddr), .hwdata_i(hwdata), .hsel_i(hsel), .hwrite_i(hwrite),
    .hready_i(hready), .htrans_i(htrans), .hsize_i(hsize),
    .hresp_o(hresp), .hreadyout_o(hreadyout), .hrdata_o(hrdata),
    .busy_o(busy_o), .error_intr(error_intr), .notif_intr(notif_intr),
    .fhe_memory_export(mem_if)
  );

  fhe_mem_top mem_inst (.clk_i(clk), .fhe_memory_export(mem_if));

  // Latch a notification pulse, and count pulses, so the test can observe
  // completions asynchronously.
  logic notif_seen;
  int   notif_count;
  always @(posedge clk or negedge rst_b)
    if (!rst_b)          begin notif_seen <= 1'b0; notif_count <= 0; end
    else if (notif_intr) begin notif_seen <= 1'b1; notif_count <= notif_count + 1; end

  int errors = 0;

  task automatic check(input string name, input logic [31:0] got, exp);
    if (got !== exp) begin
      $display("  FAIL: %-22s got=0x%08x exp=0x%08x", name, got, exp);
      errors++;
    end else begin
      $display("  ok  : %-22s = 0x%08x", name, got);
    end
  endtask

  task automatic ahb_write(input logic [AW-1:0] a, input logic [31:0] d);
    begin
      @(negedge clk);                         // address phase
      hsel <= 1'b1; htrans <= 2'b10; hsize <= 3'b010; hwrite <= 1'b1; haddr <= a;
      @(negedge clk);                         // data phase: present wdata, end addr phase
      hsel <= 1'b0; htrans <= 2'b00; hwrite <= 1'b0;
      hwdata <= a[2] ? {d, 32'h0} : {32'h0, d};
      @(negedge clk);                         // hold wdata across the capture edge
      hwdata <= '0;
    end
  endtask

  task automatic ahb_read(input logic [AW-1:0] a, output logic [31:0] d);
    begin
      @(negedge clk);
      hsel <= 1'b1; htrans <= 2'b10; hsize <= 3'b010; hwrite <= 1'b0; haddr <= a;
      @(negedge clk);
      hsel <= 1'b0; htrans <= 2'b00;
      @(negedge clk);                         // addr registered; hrdata now valid
      d = a[2] ? hrdata[63:32] : hrdata[31:0];
    end
  endtask

  // Wait for VALID (STATUS bit1) or time out.
  task automatic wait_valid(input int max_cycles, output int cycles, output bit timed_out);
    logic [31:0] st;
    begin
      cycles = 0; timed_out = 0;
      forever begin
        ahb_read(A_STATUS, st);
        if (st[1]) break;
        cycles++;
        if (cycles > max_cycles) begin timed_out = 1; break; end
      end
    end
  endtask

  logic [31:0] rd;
  int          cyc;
  bit          tmo;

  initial begin
    // init
    hsel=0; hwrite=0; haddr=0; hwdata=0; htrans=0; hsize=3'b010; hready=1'b1;
    rst_b = 1'b0;
    repeat (4) @(negedge clk);
    rst_b = 1'b1;
    repeat (2) @(negedge clk);

    $display("FHE_TOP_TB: starting");

    // 1) Read-only identity registers
    ahb_read(A_NAME0, rd); check("NAME0 (\"CKKS\")", rd, 32'h534B4B43);
    ahb_read(A_NAME1, rd); check("NAME1",            rd, 32'h00000000);
    ahb_read(A_VER0,  rd); check("VERSION0 (\"1.00\")", rd, 32'h3030312e);

    // 2) Idle status: READY=1, VALID=0
    ahb_read(A_STATUS, rd); check("STATUS idle",     rd, 32'h00000001);

    // 3) Register read/write
    ahb_write(A_SRC0, 32'hDEADBEEF);
    ahb_read (A_SRC0, rd);  check("SRC0 readback",   rd, 32'hDEADBEEF);
    ahb_write(A_CONFIG, 32'h00000023);              // target_level=3, param_set_id=2
    ahb_read (A_CONFIG, rd); check("CONFIG readback",rd, 32'h00000023);

    // 4) Command: ENCRYPT -> busy -> done -> notif -> VALID
    //    (notif_seen is sticky from reset; ENCRYPT is the first command to fire it)
    ahb_write(A_CTRL, 32'h00000001);                // CMD = FHE_ENCRYPT
    wait_valid(64, cyc, tmo);
    if (tmo) begin $display("  FAIL: command never completed (timeout)"); errors++; end
    else        $display("  ok  : ENCRYPT completed in ~%0d status polls", cyc);
    ahb_read(A_STATUS, rd); check("STATUS after done", rd, 32'h00000003); // READY|VALID
    check("notif_intr fired", {31'b0, notif_seen}, 32'h1);

    // 5) Busy rejects a new command. Issue KEYGEN, then immediately a competing
    //    REENC while the block is busy; the second must be dropped. Verify that
    //    EXACTLY ONE completion (notif pulse) occurs, not two.
    cyc = notif_count;                              // baseline count
    ahb_write(A_CTRL, 32'h00000002);                // CMD = FHE_KEYGEN (accepted)
    ahb_write(A_CTRL, 32'h00000003);                // CMD = FHE_REENC  (busy -> dropped)
    begin
      int guard; guard = 0;
      while ((notif_count == cyc) && (guard < 200)) begin @(negedge clk); guard++; end
    end
    repeat (40) @(negedge clk);                     // drain > one stub latency: no 2nd completion
    check("exactly one completion (2nd cmd dropped)", notif_count, cyc + 1);

    // 6) ZEROIZE clears architectural registers and VALID
    ahb_write(A_CTRL, 32'h00000008);                // ZEROIZE (bit3), CMD=NONE
    repeat (2) @(negedge clk);
    ahb_read(A_SRC0, rd);   check("SRC0 after zeroize", rd, 32'h00000000);
    ahb_read(A_STATUS, rd); check("STATUS after zeroize", rd, 32'h00000001); // READY, !VALID

    // summary
    if (errors == 0) $display("FHE_TOP_TB: TEST PASSED");
    else             $display("FHE_TOP_TB: TEST FAILED (%0d error(s))", errors);
    $finish;
  end

  // global watchdog
  initial begin
    #20000;
    $display("FHE_TOP_TB: TEST FAILED (global timeout)");
    $finish;
  end

endmodule
