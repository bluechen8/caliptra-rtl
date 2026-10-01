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
//   Stage-B' 2c-step-2 unit testbench: fhe_top with the REAL datapath AND the
//   dedicated FHE DMA engine moving polynomials over a real AXI4 manager port.
//   Built with +define+FHE_WALKER, so fhe_top instantiates fhe_microseq +
//   ComputeCore + fhe_dma and exposes the AXI manager (fhe_axi_r_if/w_if).
//
//   The TB plays *firmware* (AHB writes: seeds/scales/CONFIG + the 4 DMA pointer
//   registers + CMD) and backs the DMA's manager port with a small behavioral
//   AXI4 subordinate DRAM model (TB-level array, so the plaintext can be
//   preloaded and the recovered output read back directly). It runs
//   keygen -> encrypt -> decrypt as three AHB commands, with the ciphertext
//   round-tripping through actual AXI bursts to/from DRAM, and checks
//   recovered ~= input. Seed/scale constants mirror the green 2b round-trip.
//
//   Run: tb/run_fhe_top_dma_tb.sh [LOGN]   (default LOGN=8 / N=256)
//   Expect: "fhe_top_dma_tb RESULT: PASS".
//
`timescale 1ns/1ps
module fhe_top_dma_tb
  import fhe_params_pkg::*;
  import axi_pkg::*;
  import kv_defines_pkg::*;   // C'-1b: KeyVault seed model types
;
  localparam int N    = FHE_N;
  localparam int LOGN = FHE_LOGN;
  localparam int AHW  = 15;            // FHE 32KB AHB window -> 15-bit client address
  localparam int DW   = 64;

  // AXI manager / DRAM model geometry (small so the SRAM array is TB-sized).
  localparam int AXI_AW = 20;          // 1 MB DRAM model
  localparam int AXI_UW = 32;
  localparam int AXI_IW = 1;
  localparam int DEPTH  = 1 << (AXI_AW - 3);   // 64-bit words

  // Poly-buffer layout in DRAM (byte addresses), >=2KB-aligned per the AXI
  // chunking rule. STRIDE = max(N*8, 2KB).
  localparam int STRIDE = (N*8 > 2048) ? N*8 : 2048;
  localparam int ADDR_P   = 0*STRIDE;  // plaintext
  localparam int ADDR_C0  = 1*STRIDE;  // ciphertext c0
  localparam int ADDR_C1  = (1+FHE_L)*STRIDE;  // ciphertext c1
  localparam int ADDR_OUT = (1+2*FHE_L)*STRIDE;  // recovered slots

  // Register byte offsets (match fhe_top OFF_*).
  localparam logic [AHW-1:0] A_CTRL     = 'h10;
  localparam logic [AHW-1:0] A_STATUS   = 'h14;
  localparam logic [AHW-1:0] A_CONFIG   = 'h30;
  localparam logic [AHW-1:0] A_KGSEED0  = 'h34;
  localparam logic [AHW-1:0] A_KGSEED1  = 'h38;
  localparam logic [AHW-1:0] A_ASEED0   = 'h3C;
  localparam logic [AHW-1:0] A_ASEED1   = 'h40;
  localparam logic [AHW-1:0] A_ESEED0   = 'h44;
  localparam logic [AHW-1:0] A_ESEED1   = 'h48;
  localparam logic [AHW-1:0] A_KGSCALE  = 'h4C;
  localparam logic [AHW-1:0] A_ENCSCALE = 'h50;
  localparam logic [AHW-1:0] A_I2FSCALE = 'h54;
  localparam logic [AHW-1:0] A_PTR0_LO  = 'h58;
  localparam logic [AHW-1:0] A_PTR1_LO  = 'h60;
  localparam logic [AHW-1:0] A_PTR2_LO  = 'h68;
  localparam logic [AHW-1:0] A_PTR3_LO  = 'h70;
  localparam logic [AHW-1:0] A_KGKV_CTRL = 'h78;   // C'-1b KeyVault seed ctrl
  localparam logic [AHW-1:0] A_ENTSEED0  = 'h7C;   // C'-2 a/e0 stream seed [31:0]
  localparam logic [AHW-1:0] A_ENTSEED1  = 'h80;   // C'-2 a/e0 stream seed [63:32]
  localparam logic [AHW-1:0] A_RNG_CTRL  = 'h84;   // C'-2 bit0=FREERUN_EN bit1=RESEED_REQ
  localparam logic [AHW-1:0] A_STREAM_STATUS = 'h88; // private stream (FHE_LOCAL_STREAM)
  localparam logic [AHW-1:0] A_STREAM_LEFT   = 'h8C;
  localparam logic [AHW-1:0] A_STREAM_DATA   = 'h90;
  localparam logic [AHW-1:0] A_STREAM_CAP    = 'h94;
  localparam logic [31:0]    CTRL_ZEROIZE    = 32'h8;
  // Aloha limb moduli (profile 0xa108).
  localparam logic [63:0] Q_LIMB [2] = '{(64'd1<<46)-(64'd9<<24)+1, (64'd1<<47)-(64'd1<<24)+1};

  localparam int     RT_SCALE    = 17 + LOGN;
  localparam longint KEYGEN_SEED = 64'hA105_BEEF_0006_A001;
  localparam longint A_SEED      = 64'h0006_A002_C0FF_EE77;
  localparam longint ERR_SEED    = 64'h2350_e171_5239_2f72;
  localparam longint ENT_SEED    = 64'hC5A9_1234_FEED_0FF1;  // CSRNG-sourced a/e0 stream seed

  // ------------------------------------------------------------------
  logic clk = 1'b0;
  logic rst_b;
  logic parent_clock_live;
  logic parent_manual_enable = 1'b1;
  logic cpu_sleep = 1'b0;
  always_latch if (!clk)
    parent_clock_live <= parent_manual_enable && (!cpu_sleep || busy_o || error_intr || notif_intr);
  wire parent_clk = clk & parent_clock_live;
  always #5 clk = ~clk;

  // AHB-Lite responder signals
  logic [AHW-1:0] haddr;
  logic [DW-1:0]  hwdata;
  logic           hsel, hwrite, hready;
  logic [1:0]     htrans;
  logic [2:0]     hsize;
  logic           hresp, hreadyout;
  // Single-responder AHB-Lite: the bus HREADY is the responder's HREADYOUT, so
  // wait states and the two-cycle ERROR response behave as on the real fabric.
  assign hready = hreadyout;
  logic [DW-1:0]  hrdata;
  logic busy_o, error_intr, notif_intr;

  fhe_mem_if mem_if();

  // AXI manager interface driven by fhe_top's FHE DMA, serviced by the TB sub.
  axi_if #(.AW(AXI_AW), .DW(DW), .IW(AXI_IW), .UW(AXI_UW)) axi (.clk(clk), .rst_n(rst_b));

  fhe_top #(
    .AHB_DATA_WIDTH(DW), .AHB_ADDR_WIDTH(AHW),
    .FHE_AXI_AW(AXI_AW), .FHE_AXI_UW(AXI_UW), .FHE_AXI_IW(AXI_IW)
  ) dut (
    .clock_live(parent_clock_live),
    .clk(parent_clk), .rst_b(rst_b),
    .haddr_i(haddr), .hwdata_i(hwdata), .hsel_i(hsel), .hwrite_i(hwrite),
    .hready_i(hready), .htrans_i(htrans), .hsize_i(hsize),
    .hresp_o(hresp), .hreadyout_o(hreadyout), .hrdata_o(hrdata),
    .busy_o(busy_o), .error_intr(error_intr), .notif_intr(notif_intr),
    .fhe_memory_export(mem_if),
    .fhe_axi_r_if(axi), .fhe_axi_w_if(axi),
    // C'-1b: KeyVault seed port. Default run leaves KGKV_CTRL.KV_EN=0 (AHB
    // KGSEED register path); the +KVSEED run provisions dut_kv_* below and
    // enables KV so the keygen root comes from the (modeled) KeyVault instead.
    .fhe_kv_read(dut_kv_read), .fhe_kv_rd_resp(dut_kv_rd_resp),
    // C'-3: Aloha ComputeCore storage banks lifted to the top; the TB supplies
    // them via the behavioral fhe_aloha_mem_top (real SRAM at the SoC level).
    .fhe_aloha_mem(aloha_mem.req)
  );

  fhe_aloha_mem_if aloha_mem();
  fhe_aloha_mem_top #(.PHASED(1)) u_aloha_mem (.clk_i(clk), .m(aloha_mem.resp));

  // Check the narrowed, synchronous resident-key port independently of the
  // round-trip (which can otherwise hide matching corruption on both paths).
  logic [53:0] key_shadow [0:N*FHE_L-1];
  bit key_written [0:N*FHE_L-1];
  bit key_read_pending;
  logic [$clog2(N*FHE_L)-1:0] key_read_addr;
  int key_writes [0:FHE_L-1];
  int key_reads [0:FHE_L-1];
  always @(posedge clk) begin
    if (!rst_b) begin
      key_read_pending <= 0;
      foreach (key_written[i]) key_written[i] = 0;
      foreach (key_writes[i]) key_writes[i] = 0;
      foreach (key_reads[i]) key_reads[i] = 0;
    end else begin
      if (key_read_pending) begin
        key_reads[int'(key_read_addr)/N]++;
        assert (key_written[key_read_addr]) else $fatal(1, "key read before write");
        assert (aloha_mem.sk_rdata === key_shadow[key_read_addr])
          else $fatal(1, "key SRAM read/latency mismatch at %0d", key_read_addr);
      end
      key_read_pending <= aloha_mem.sk_en && !aloha_mem.sk_we;
      key_read_addr <= aloha_mem.sk_addr;
      if (aloha_mem.sk_en && aloha_mem.sk_we) begin
        assert (dut.walker.dout_high[31:22] == 0)
          else $fatal(1, "resident key truncation would discard nonzero bits");
        key_shadow[aloha_mem.sk_addr] = aloha_mem.sk_wdata;
        key_written[aloha_mem.sk_addr] = 1;
        key_writes[int'(aloha_mem.sk_addr)/N]++;
      end
    end
  end

  // ---- C'-1b: behavioral single-entry KeyVault model ----
  localparam int    KV_ENTRY = 5;
  kv_read_t         dut_kv_read;
  kv_rd_resp_t      dut_kv_rd_resp;
  logic [31:0]      kv_ent [0:KV_NUM_DWORDS-1];
  always_comb begin
    dut_kv_rd_resp.read_data = kv_ent[dut_kv_read.read_offset];
    dut_kv_rd_resp.error     = 1'b0;   // authorization covered by fhe_kv_seed_tb
    dut_kv_rd_resp.last      = (dut_kv_read.read_offset == KV_ENTRY_SIZE_W'(1));
  end

  fhe_mem_top mem_inst (.clk_i(clk), .fhe_memory_export(mem_if));

  // ------------------------------------------------------------------
  // Behavioral AXI4 subordinate DRAM model (single outstanding; the FHE DMA
  // serializes one <=256-beat burst at a time). TB-level array for preload/peek.
  // ------------------------------------------------------------------
  logic [63:0] dram [0:DEPTH-1];

  // read channel
  typedef enum logic {R_IDLE, R_DATA} r_st_e;
  r_st_e         rst_q;
  logic [AXI_AW-4:0] r_word;   // word index
  logic [8:0]    r_rem;        // beats remaining (arlen+1, up to 256)

  // write channel
  typedef enum logic [1:0] {W_IDLE, W_DATA, W_RESP} w_st_e;
  w_st_e         wst_q;
  logic [AXI_AW-4:0] w_word;

  always_ff @(posedge clk or negedge rst_b) begin
    if (!rst_b) begin
      rst_q <= R_IDLE; r_word <= '0; r_rem <= '0;
      axi.arready <= 1'b0; axi.rvalid <= 1'b0; axi.rlast <= 1'b0;
      axi.rdata <= '0; axi.rresp <= '0; axi.rid <= '0; axi.ruser <= '0;
      wst_q <= W_IDLE; w_word <= '0;
      axi.awready <= 1'b0; axi.wready <= 1'b0;
      axi.bvalid <= 1'b0; axi.bresp <= '0; axi.bid <= '0; axi.buser <= '0;
    end else begin
      // -------- read --------
      unique case (rst_q)
        R_IDLE: begin
          axi.rvalid <= 1'b0; axi.rlast <= 1'b0;
          axi.arready <= 1'b1;
          if (axi.arvalid && axi.arready) begin
            axi.arready <= 1'b0;
            r_word <= axi.araddr[AXI_AW-1:3];
            r_rem  <= {1'b0, axi.arlen} + 9'd1;
            rst_q  <= R_DATA;
          end
        end
        R_DATA: begin
          // Present the current beat; advance only when it is accepted.
          axi.rvalid <= 1'b1;
          axi.rdata  <= dram[r_word];
          axi.rresp  <= '0;
          axi.rlast  <= (r_rem == 9'd1);
          if (axi.rvalid && axi.rready) begin
            if (r_rem == 9'd1) begin
              axi.rvalid <= 1'b0;
              axi.rlast  <= 1'b0;
              rst_q      <= R_IDLE;
            end else begin
              r_word    <= r_word + 1'b1;
              r_rem     <= r_rem - 1'b1;
              axi.rdata <= dram[r_word + 1'b1];
              axi.rlast <= (r_rem == 9'd2);
            end
          end
        end
        default: rst_q <= R_IDLE;
      endcase

      // -------- write --------
      unique case (wst_q)
        W_IDLE: begin
          axi.bvalid <= 1'b0;
          axi.wready <= 1'b0;
          axi.awready <= 1'b1;
          if (axi.awvalid && axi.awready) begin
            axi.awready <= 1'b0;
            w_word <= axi.awaddr[AXI_AW-1:3];
            wst_q  <= W_DATA;
          end
        end
        W_DATA: begin
          axi.wready <= 1'b1;
          if (axi.wvalid && axi.wready) begin
            dram[w_word] <= axi.wdata;
            w_word <= w_word + 1'b1;
            if (axi.wlast) begin
              axi.wready <= 1'b0;
              wst_q <= W_RESP;
            end
          end
        end
        W_RESP: begin
          axi.bvalid <= 1'b1;
          axi.bresp  <= '0;
          if (axi.bvalid && axi.bready) begin
            axi.bvalid <= 1'b0;
            wst_q <= W_IDLE;
          end
        end
        default: wst_q <= W_IDLE;
      endcase
    end
  end

  // ------------------------------------------------------------------
  int notif_count;
  always @(posedge clk or negedge rst_b)
    if (!rst_b)          notif_count <= 0;
    else if (notif_intr) notif_count <= notif_count + 1;

  int    errors = 0;
  string tvdir;
  longint g_input [0:N];
  real   fft_abs_floor = 1.0e-4;

  // AHB-Lite single 32-bit register access. The data phase (and HWDATA) is
  // held while HREADYOUT is low; err reports an ERROR response.
  task automatic ahb_access(input bit write, input logic [AHW-1:0] a,
                            input logic [31:0] wd, output logic [31:0] rd,
                            output bit err);
    begin
      @(negedge clk);
      hsel <= 1'b1; htrans <= 2'b10; hsize <= 3'b010; hwrite <= write; haddr <= a;
      @(negedge clk);
      hsel <= 1'b0; htrans <= 2'b00; hwrite <= 1'b0;
      if (write) hwdata <= a[2] ? {wd, 32'h0} : {32'h0, wd};
      #1;
      err = hresp;
      while (!hreadyout) begin @(negedge clk); #1; end
      err |= hresp;
      rd = a[2] ? hrdata[63:32] : hrdata[31:0];
      @(negedge clk);
      hwdata <= '0;
    end
  endtask

  task automatic ahb_write(input logic [AHW-1:0] a, input logic [31:0] d);
    logic [31:0] unused;
    bit err;
    ahb_access(1'b1, a, d, unused, err);
    if (err) begin $display("FAIL: unexpected AHB error on write 0x%0h", a); errors++; end
  endtask

  task automatic ahb_read(input logic [AHW-1:0] a, output logic [31:0] d);
    bit err;
    ahb_access(1'b0, a, '0, d, err);
    if (err) begin $display("FAIL: unexpected AHB error on read 0x%0h", a); errors++; end
  endtask

  // AHB-Lite ERROR is exactly two cycles: HREADYOUT low, then high, with
  // HRESP=ERROR in both. Sampled before each edge.
  logic resp_err_first;
  always @(posedge clk or negedge rst_b) begin
    if (!rst_b) resp_err_first <= 1'b0;
    else begin
      if (resp_err_first)
        assert (hresp && hreadyout) else $fatal(1, "AHB ERROR response did not complete in its second cycle");
      else if (hresp)
        assert (!hreadyout) else $fatal(1, "AHB ERROR response skipped its first (wait) cycle");
      resp_err_first <= hresp && !hreadyout;
    end
  end

  // write a 64-bit DMA pointer register (lo @ a, hi @ a+4)
  task automatic ahb_write64(input logic [AHW-1:0] a, input logic [63:0] v);
    begin ahb_write(a, v[31:0]); ahb_write(a + 'h4, v[63:32]); end
  endtask

`ifdef FHE_LOCAL_STREAM
  // Directed bus-level checks of the private stream while the walker is idle.
  // Illegal DATA accesses must return ERROR without changing stream state.
  // The race case forces a walker push into the first ERROR cycle: the access
  // must still fail and must not consume the newly available word.
  task automatic stream_check(input bit ok, input string what);
    if (!ok) begin $display("FAIL[STREAM]: %s", what); errors++; end
  endtask

  task automatic check_local_stream_bus();
    logic [31:0] d, lo, hi;
    bit err;
    int start_errors = errors;
    ahb_read(A_STREAM_CAP, d);
    stream_check(d == (32'h80000000 | N), $sformatf("CAP=0x%08h", d));
    ahb_access(1'b0, A_STREAM_DATA, '0, d, err);
    stream_check(err, "idle DATA read accepted");
    ahb_access(1'b1, A_STREAM_DATA, 32'h1234_5678, d, err);
    stream_check(err, "idle DATA write accepted");
    ahb_read(A_STREAM_STATUS, d);
    stream_check(d == 0, $sformatf("rejected access changed STATUS=0x%08h", d));
    // Keep the next address valid through ERROR completion: no idle bubble
    // between the rejected transfers. Exercise both read and write errors,
    // followed immediately by a legal CAP read to check recovery.
    for (int write_access = 0; write_access < 2; write_access++) begin
      @(negedge clk);
      hsel = 1; htrans = 2'b10; haddr = A_STREAM_DATA;
      hwrite = 1'(write_access); hsize = 3'b010; hwdata = 64'h1234_5678;
      @(negedge clk);
      stream_check(hresp && !hreadyout, "first access skipped ERROR wait cycle");
      @(negedge clk);
      stream_check(hresp && hreadyout, "first ERROR did not complete");
      @(negedge clk);
      stream_check(hresp && !hreadyout, "back-to-back access skipped ERROR wait cycle");
      haddr = A_STREAM_CAP; hwrite = 0;
      @(negedge clk);
      stream_check(hresp && hreadyout, "second ERROR did not complete");
      @(negedge clk);
      stream_check(!hresp && hreadyout, "legal access after ERROR did not complete OKAY");
      stream_check(hrdata[63:32] == (32'h80000000 | N), "CAP read after ERROR returned wrong data");
      hsel = 0; htrans = 0; hwdata = 0;
      @(negedge clk);
      stream_check(!hresp && hreadyout, "spurious ERROR after final access");
    end
    ahb_read(A_STREAM_STATUS, d);
    stream_check(d == 0, "back-to-back errors changed stream state");
    // Open an output descriptor without running the walker.
    @(negedge clk);
    force dut.w_desc_valid = 1'b1; force dut.w_desc_wr = 1'b1;
    force dut.w_desc_ptr = 3'd2; force dut.w_desc_limb = 4'd0;
    @(negedge clk);
    release dut.w_desc_valid; release dut.w_desc_wr; release dut.w_desc_ptr; release dut.w_desc_limb;
    fork
      ahb_access(1'b0, A_STREAM_DATA, '0, d, err);
      begin
        @(negedge clk); @(posedge clk); #1;   // data phase, first ERROR cycle
        force dut.w_wr_push = 1'b1; force dut.w_wr_data = 64'hfeed_beef_0bad_cafe;
        @(posedge clk); #1;
        release dut.w_wr_push; release dut.w_wr_data;
      end
    join
    stream_check(err, "DATA read completed after its ERROR cycle");
    ahb_read(A_STREAM_STATUS, d);
    stream_check(d[3:0] == 4'b1011 && !d[12], $sformatf("race changed STATUS=0x%08h", d));
    ahb_read(A_STREAM_DATA, lo); ahb_read(A_STREAM_DATA, hi);
    stream_check({hi, lo} == 64'hfeed_beef_0bad_cafe, $sformatf("word=0x%08h%08h", hi, lo));
    ahb_read(A_STREAM_LEFT, d);
    stream_check(d == N-1, $sformatf("LEFT=%0d after one word", d));
    ahb_write(A_CTRL, CTRL_ZEROIZE);   // discards the open descriptor
    ahb_read(A_STREAM_STATUS, d);
    stream_check(d == 0, $sformatf("ZEROIZE left STATUS=0x%08h", d));
    if (errors == start_errors) $display("PASS local-stream AHB errors, back-to-back errors/recovery, error-cycle race, ZEROIZE");
  endtask
`endif

  // Firmware model: private memory <-> AHB stream, no FHE AXI traffic.
  task automatic service_local_stream();
`ifdef FHE_LOCAL_STREAM
    logic [31:0] status, left, lo, hi;
    int idx;
    ahb_read(A_STREAM_STATUS, status);
    if (status[2] || status[3]) begin   // input ready / output valid (both imply active)
      ahb_read(A_STREAM_LEFT, left);
      idx = int'(dut.dma_ptr[status[6:4]]/8) + int'(status[11:8])*N + N-int'(left);
      if (status[1]) begin
        ahb_read(A_STREAM_DATA, lo); ahb_read(A_STREAM_DATA, hi);
        dram[idx] = {hi,lo};
      end else begin
        ahb_write(A_STREAM_DATA, dram[idx][31:0]); ahb_write(A_STREAM_DATA, dram[idx][63:32]);
      end
    end
`else
    @(posedge clk);
`endif
  endtask
`ifdef FHE_LOCAL_STREAM
  always @(posedge clk) if (rst_b)
    assert (!axi.arvalid && !axi.awvalid && !axi.wvalid)
      else $fatal(1, "private stream leaked external AXI request");
`endif

  task automatic run_cmd(input fhe_cmd_e c, input string nm);
    int base, guard;
    base = notif_count;
    ahb_write(A_CTRL, {29'd0, c});
    cpu_sleep = 1; // parent must stay awake through DMA and completion delivery
    guard = 0;
    while ((notif_count == base) && (guard < 50_000_000)) begin service_local_stream(); guard++; end
    if (notif_count == base) begin $display("  FAIL: %s never completed (timeout)", nm); errors++; end
    else                          $display("  [dma] %s done (%0d polling iterations)", nm, guard);
    @(negedge clk);
    cpu_sleep = 0;
  endtask

  // C'-2 free-run helpers ------------------------------------------------------
  // read N words from DRAM at `base` (e.g. the ciphertext c1 = uniform `a`, or the
  // recovered OUT slots) into dst.
  task automatic capture_slots(ref longint dst [], input int base);
    for (int i = 0; i < N; i++) dst[i] = dram[(base/8) + i];
  endtask
  function automatic int diff_count(ref longint x [], ref longint y []);
    diff_count = 0;
    for (int i = 0; i < N; i++) if (x[i] !== y[i]) diff_count++;
  endfunction
  // firmware doorbell: write the CSRNG-sourced ENTSEED + assert RESEED_REQ.
  task automatic doorbell(input longint s);
    ahb_write64(A_ENTSEED0, s);
    ahb_write(A_RNG_CTRL, 32'h3);                  // FREERUN_EN=1, RESEED_REQ=1
  endtask

  function automatic bit close(input longint ab, input longint bb, input real eps);
    real a = $bitstoreal(ab);
    real b = $bitstoreal(bb);
    real t, d;
    d = a - b; if (d < 0.0) d = -d;
    if (d < fft_abs_floor) close = 1;
    else if (a == 0.0 || b == 0.0) close = (d < eps);
    else begin t = b/a - 1.0; if (t < 0.0) t = -t; close = (t < eps); end
  endfunction

  task automatic check_fft(input longint res[], input longint gold[0:N],
                           input int ndbl, input string name, input real eps);
    int i, nerr = 0;
    for (i = 0; i < ndbl; i++)
      if (!close(res[i], gold[i], eps)) begin
        if (nerr < 8) $display("  %s[%0d]: got %h (%g) exp %h (%g)", name, i,
                               res[i], $bitstoreal(res[i]), gold[i], $bitstoreal(gold[i]));
        nerr++;
      end
    if (nerr) begin $display("FAIL %s: %0d/%0d", name, nerr, ndbl); errors++; end
    else        $display("PASS %s (%0d doubles, relative tolerance=%g, absolute floor=%g)", name, ndbl, eps, fft_abs_floor);
  endtask

  // Independent public integer evaluator: scalar multiply/add only, using
  // unbounded-domain model weights and canonical modular reduction per term.
  // An encrypted constant-one channel supplies bias without assuming an NTT
  // or Montgomery representation for a freshly constructed plaintext constant.
  task automatic run_mnist(input string directory);
    longint slots[0:N-1];
    longint expected[0:2*10-1];          // two images x ten logits
    logic [31:0] weights[0:10*197-1];     // ten classes x (196 pixels + bias)
    logic [63:0] acc[0:10*4*N-1];
    logic [63:0] q, x, term;
    int weight;
    real error, max_error;
    foreach (acc[i]) acc[i] = 0;
    $readmemh({directory, "/weights.mem"}, weights);
    $readmemh({directory, "/expected.mem"}, expected);
    ahb_write(A_CONFIG, 2);
    ahb_write(A_RNG_CTRL, 1);
    for (int feature_idx=0; feature_idx<197; feature_idx++) begin
      $readmemh($sformatf("%s/input_%03d.mem", directory, feature_idx), slots);
      for (int i=0;i<N;i++) dram[ADDR_P/8+i] = slots[i];
      ahb_write64(A_PTR0_LO, 64'(ADDR_P));
      ahb_write64(A_PTR2_LO, 64'(ADDR_C0));
      ahb_write64(A_PTR3_LO, 64'(ADDR_C1));
      doorbell(ENT_SEED + 64'(feature_idx));
      run_cmd(FHE_ENCRYPT, $sformatf("MNIST ingress %0d", feature_idx));
      for (int k=0;k<10;k++) begin
        weight = int'(weights[k*197+feature_idx]);
        for (int component=0;component<2;component++)
          for (int li=0;li<2;li++) begin
            q = Q_LIMB[li];
            for (int i=0;i<N;i++) begin
              int a;
              a = k*4*N + (component*2+li)*N+i;
              x = dram[(component == 0 ? ADDR_C0 : ADDR_C1)/8+li*N+i] % q;
              term = (x * 64'(weight < 0 ? -weight : weight)) % q;
              if (weight < 0 && term != 0) term = q-term;
              acc[a] = (acc[a]+term) % q;
            end
          end
      end
    end
    max_error = 0;
    for (int k=0;k<10;k++) begin
      for (int i=0;i<2*N;i++) begin
        dram[ADDR_C0/8+i] = acc[k*4*N+i];
        dram[ADDR_C1/8+i] = acc[k*4*N+2*N+i];
      end
      ahb_write64(A_PTR0_LO, 64'(ADDR_C0));
      ahb_write64(A_PTR1_LO, 64'(ADDR_C1));
      ahb_write64(A_PTR2_LO, 64'(ADDR_OUT));
      run_cmd(FHE_DECRYPT, $sformatf("MNIST egress %0d",k));
      for (int image_idx=0;image_idx<2;image_idx++) begin
        error = $bitstoreal(dram[ADDR_OUT/8+2*image_idx]) - $bitstoreal(expected[image_idx*10+k]);
        if (error < 0) error = -error;
        if (error > max_error) max_error = error;
        // Fail closed: comparisons against NaN are false, including >=.
        if (!(error < 0.5)) begin
          errors++;
          $display("FAIL MNIST image=%0d class=%0d got=%g expected=%g", image_idx,k,
            $bitstoreal(dram[ADDR_OUT/8+2*image_idx]), $bitstoreal(expected[image_idx*10+k]));
        end
      end
    end
    $display("MNIST two-image max absolute logit error=%g", max_error);
  endtask

  // ------------------------------------------------------------------
  int          rns_scale;
  logic [31:0] i2f_val;

  initial begin
    if (!$value$plusargs("TVDIR=%s", tvdir)) tvdir = ".";

    hsel=0; hwrite=0; haddr=0; hwdata=0; htrans=0; hsize=3'b010;
    for (int i = 0; i < DEPTH; i++) dram[i] = 64'd0;
    rst_b = 1'b0;
    repeat (4) @(negedge clk);
    rst_b = 1'b1;
    repeat (2) @(negedge clk);

    // Functional firmware co-simulation: time advances only for MMIO requests.
    // This deliberately makes no CPU/peripheral timing claim.
    if ($test$plusargs("RPC")) begin
      int op, count;
      logic [31:0] addr, value, rdata;
      bit err;
      forever begin
        count = $fscanf(32'h80000000, "%d %h %h", op, addr, value);
        if (count != 3) $finish;
        else begin
          // Reply "RPC <read data> <1 if AHB ERROR>"; the emulator raises a
          // load/store access fault for an ERROR response.
          ahb_access(op == 1, addr, value, rdata, err);
          repeat (32) @(negedge clk);
          $display("RPC %08x %0d", rdata, err);
          $fflush();
        end
      end
    end

`ifdef FHE_LOCAL_STREAM
    check_local_stream_bus();
`endif

    // Pause the parent clock in each idle phase while lifted SRAMs continue
    // to receive base-clock edges. No repeated requests/response shifts allowed.
    for (int phase = 0; phase < 3; phase++) begin
      logic [53:0] held_response;
      while (dut.mem_phase != 2'(phase)) @(negedge clk);
      held_response = aloha_mem.ntt_msg0_doutb;
      parent_manual_enable = 0;
      repeat (9) begin
        @(negedge clk);
        assert ({aloha_mem.phase_read, aloha_mem.phase_execute, aloha_mem.phase_write} == 0)
          else $fatal(1, "memory request escaped stopped parent clock");
        assert (aloha_mem.ntt_msg0_doutb === held_response)
          else $fatal(1, "memory response advanced while parent clock stopped");
        assert (dut.mem_phase == 2'(phase)) else $fatal(1, "phase changed while parent clock stopped");
      end
      parent_manual_enable = 1;
      repeat (4) @(negedge clk);
    end
    $display("PASS idle parent-clock pause/resume in all three phases");

    $display("== Stage-B' 2c-step-2: fhe_top + FHE DMA round-trip (AXI), N=%0d ==", N);

    // plaintext -> DRAM (the ENCRYPT DMA_IN source @ PTR0)
    $readmemh({tvdir, "/input.txt"}, g_input);
    for (int i = 0; i < N; i++) dram[(ADDR_P/8) + i] = g_input[i];

    // ---- firmware: seeds + scales + CONFIG.L ----
    // C'-1b: in +KVSEED mode the keygen root comes from the KeyVault. Provision
    // the KV entry with the correct seed, enable KGKV_CTRL, and deliberately
    // write the WRONG value to the AHB KGSEED regs. (The sk-scheme round-trip
    // cancels for ANY key blob -- Rung-6 fact -- so recovery alone can't prove
    // the source; the decisive check is the hierarchical assert on the walker's
    // effective keygen seed after KEYGEN, below.)
    if ($test$plusargs("KVSEED")) begin
      kv_ent[0] = KEYGEN_SEED[31:0];
      kv_ent[1] = KEYGEN_SEED[63:32];
      ahb_write(A_KGKV_CTRL, {23'd0, 5'(KV_ENTRY), 3'd0, 1'b1}); // entry, KV_EN=1
      ahb_write(A_KGSEED0, 32'hDEAD_0000); ahb_write(A_KGSEED1, 32'h0000_BEEF); // wrong on purpose
      $display("  [dma] +KVSEED: keygen seed sourced from KeyVault entry %0d", KV_ENTRY);
    end else begin
      ahb_write(A_KGSEED0, KEYGEN_SEED[31:0]); ahb_write(A_KGSEED1, KEYGEN_SEED[63:32]);
    end
    ahb_write(A_ASEED0,  A_SEED[31:0]);      ahb_write(A_ASEED1,  A_SEED[63:32]);
    ahb_write(A_ESEED0,  ERR_SEED[31:0]);    ahb_write(A_ESEED1,  ERR_SEED[63:32]);
    rns_scale = RT_SCALE - 52 - 1023 - LOGN; if (rns_scale < 0) rns_scale += 4096;
    i2f_val   = -RT_SCALE;
    ahb_write(A_KGSCALE,  rns_scale[31:0]);
    ahb_write(A_ENCSCALE, rns_scale[31:0]);
    ahb_write(A_I2FSCALE, i2f_val);
    ahb_write(A_CONFIG, $test$plusargs("LIMBS2") ? 32'd2 : 32'd1);

    // ---- KEYGEN (no DMA) ----
    run_cmd(FHE_KEYGEN, "KEYGEN");

    // C'-1b decisive check: the walker's effective keygen seed must equal the
    // KeyVault-provisioned value (NOT the deliberately-wrong KGSEED registers).
    if ($test$plusargs("KVSEED")) begin
      if (dut.kg_seed_eff !== KEYGEN_SEED) begin
        $display("FAIL[KVSEED]: kg_seed_eff=%h expected %h (KV seed did not reach walker)",
                 dut.kg_seed_eff, KEYGEN_SEED);
        errors++;
      end else begin
        $display("  [dma] +KVSEED: walker keygen seed = %h (from KeyVault) OK", dut.kg_seed_eff);
      end
    end

    for (int limb=0; limb < ($test$plusargs("LIMBS2") ? 2 : 1); limb++) begin
      assert (key_writes[limb] == N)
        else $fatal(1, "key limb %0d: expected %0d writes, got %0d", limb, N, key_writes[limb]);
    end

    // ---- ENCRYPT: msg<-PTR0(P), c0->PTR2(C0), c1->PTR3(C1) ----
    ahb_write64(A_PTR0_LO, 64'(ADDR_P));
    ahb_write64(A_PTR2_LO, 64'(ADDR_C0));
    ahb_write64(A_PTR3_LO, 64'(ADDR_C1));
    run_cmd(FHE_ENCRYPT, "ENCRYPT");
    for (int limb=0; limb < ($test$plusargs("LIMBS2") ? 2 : 1); limb++) begin
      assert (key_reads[limb] == N)
        else $fatal(1, "key limb %0d: expected %0d reads, got %0d", limb, N, key_reads[limb]);
    end

    // ---- DECRYPT: c0<-PTR0(C0), c1<-PTR1(C1), out->PTR2(OUT) ----
    ahb_write64(A_PTR0_LO, 64'(ADDR_C0));
    ahb_write64(A_PTR1_LO, 64'(ADDR_C1));
    ahb_write64(A_PTR2_LO, 64'(ADDR_OUT));
    run_cmd(FHE_DECRYPT, "DECRYPT");

    // recovered slots read back from DRAM @ OUT
    begin
      longint reco [];
      reco = new[N];
      capture_slots(reco, ADDR_OUT);
      check_fft(reco, g_input, N, "fhe_top+DMA round-trip (recovered vs input)", 1.0e-3);
    end

    // ---- C'-2 free-run PRNG test (+FREERUN) ----
    // Enable free-run, then: (1) two back-to-back encrypts with NO doorbell must
    // produce DIFFERENT c1(=a) -> the keystream continues, a never repeats;
    // (2) a doorbell reseed with the SAME ENTSEED must restart the stream and
    // reproduce encrypt#1's c1 -> the inject is deterministic; (3) a free-run
    // ciphertext still decrypts to the input.
    if ($test$plusargs("FREERUN")) begin
      longint a1 [], a2 [], a3 [];
      int diff12, diff13, base, guard;
      logic [31:0] sdata;
      a1 = new[N]; a2 = new[N]; a3 = new[N];
      $display("== C'-2 free-run PRNG test ==");

      ahb_write(A_RNG_CTRL, 32'h1);                 // FREERUN_EN=1 (NO doorbell yet)

      // KEYGEN marks the a/e0 stream unseeded -> the first encrypt MUST wait for a
      // firmware RESEED_REQ (enforced fresh entropy after keygen / cold reset).
      run_cmd(FHE_KEYGEN, "KEYGEN(freerun)");
      ahb_write64(A_PTR0_LO, 64'(ADDR_P));
      ahb_write64(A_PTR2_LO, 64'(ADDR_C0));
      ahb_write64(A_PTR3_LO, 64'(ADDR_C1));

      // (0) ENFORCEMENT + OBSERVABILITY: the first encrypt with NO reseed must
      //     STALL (not complete), raise a NOTIF interrupt, and set the bus-readable
      //     STATUS.RESEED_REQ_PENDING (bit4) -- an observable wait, not a silent hang.
      base = notif_count;
      ahb_write(A_CTRL, {29'd0, FHE_ENCRYPT});
      // Reach the entropy wait after the N-dependent load/conversion prefix.
      // A fixed 20k-cycle delay is too short for the phased full-size engine.
      guard = 0;
      while (!dut.ctrl_wait_entropy && !dut.status_valid && guard < 50_000_000) begin
        service_local_stream(); guard++;
      end
      repeat (200) @(posedge clk); // prove it remains blocked without the doorbell
      ahb_read(A_STATUS, sdata);                     // sdata[1]=VALID, sdata[4]=RESEED_REQ_PENDING
      if (dut.status_valid) begin
        $display("FAIL[FREERUN]: first encrypt completed with NO reseed (enforcement broken)"); errors++;
      end else if (!dut.ctrl_wait_entropy) begin
        $display("FAIL[FREERUN]: encrypt neither completed nor in reseed-wait (wedged?)"); errors++;
      end else
        $display("  [freerun] enforcement OK: first encrypt STALLED in reseed-wait");
      if (notif_count == base) begin
        $display("FAIL[FREERUN]: no NOTIF interrupt raised on entering reseed-wait"); errors++;
      end else
        $display("  [freerun] wait-notify OK: NOTIF raised on entering reseed-wait");
      if (!sdata[4]) begin
        $display("FAIL[FREERUN]: STATUS.RESEED_REQ_PENDING (bit4) not readable over AHB (read=%08h)", sdata); errors++;
      end else
        $display("  [freerun] STATUS OK: RESEED_REQ_PENDING readable over AHB (bit4=1)");

      // release: deliver the doorbell WHILE the command is busy/stalled.
      doorbell(ENT_SEED);
      guard = 0;
      while (!dut.status_valid && (guard < 50_000_000)) begin service_local_stream(); guard++; end
      ahb_read(A_STATUS, sdata);
      if (!dut.status_valid) begin
        $display("FAIL[FREERUN]: stalled encrypt never released after RESEED_REQ"); errors++;
      end else if (sdata[4]) begin
        $display("FAIL[FREERUN]: RESEED_REQ_PENDING still set after release"); errors++;
      end else
        $display("  [freerun] release OK: encrypt#1 completed after RESEED_REQ (~%0d cyc)", guard);
      @(negedge clk);
      capture_slots(a1, ADDR_C1);

      run_cmd(FHE_ENCRYPT, "ENCRYPT#2 (freerun: continue stream)");
      capture_slots(a2, ADDR_C1);

      diff12 = diff_count(a1, a2);
      if (diff12 == 0) begin
        $display("FAIL[FREERUN]: encrypt#1 and #2 produced IDENTICAL c1 -- a was REUSED"); errors++;
      end else
        $display("  [freerun] non-repeat OK: c1(=a) differs in %0d/%0d coeffs across two encrypts", diff12, N);

      // doorbell: re-seed the stream with the SAME ENTSEED -> must reproduce a1.
      doorbell(ENT_SEED);
      run_cmd(FHE_ENCRYPT, "ENCRYPT#3 (freerun: doorbell reseed)");
      capture_slots(a3, ADDR_C1);
      diff13 = diff_count(a1, a3);
      if (diff13 != 0) begin
        $display("FAIL[FREERUN]: doorbell reseed (same ENTSEED) did not reproduce c1 (%0d diffs)", diff13); errors++;
      end else
        $display("  [freerun] reseed-determinism OK: same ENTSEED -> identical c1");

      // functional: the last free-run ciphertext still decrypts to the input.
      ahb_write64(A_PTR0_LO, 64'(ADDR_C0));
      ahb_write64(A_PTR1_LO, 64'(ADDR_C1));
      ahb_write64(A_PTR2_LO, 64'(ADDR_OUT));
      run_cmd(FHE_DECRYPT, "DECRYPT(freerun)");
      begin
        longint reco []; reco = new[N];
        capture_slots(reco, ADDR_OUT);
        check_fft(reco, g_input, N, "freerun round-trip (recovered vs input)", 1.0e-3);
      end
    end

    begin
      string mnist_dir;
      if ($value$plusargs("MNIST=%s",mnist_dir)) run_mnist(mnist_dir);
    end
    if (errors == 0) $display("fhe_top_dma_tb RESULT: PASS");
    else             $display("fhe_top_dma_tb RESULT: FAIL (%0d error(s))", errors);
    $finish;
  end

  initial begin
    #800_000_000;
    $display("fhe_top_dma_tb RESULT: FAIL (global timeout)");
    $finish;
  end

endmodule
