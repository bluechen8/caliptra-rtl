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
  localparam int ADDR_C1  = 2*STRIDE;  // ciphertext c1
  localparam int ADDR_OUT = 3*STRIDE;  // recovered slots

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

  localparam int     RT_SCALE    = 17 + LOGN;
  localparam longint KEYGEN_SEED = 64'hA105_BEEF_0006_A001;
  localparam longint A_SEED      = 64'h0006_A002_C0FF_EE77;
  localparam longint ERR_SEED    = 64'h2350_e171_5239_2f72;
  localparam longint ENT_SEED    = 64'hC5A9_1234_FEED_0FF1;  // CSRNG-sourced a/e0 stream seed

  // ------------------------------------------------------------------
  logic clk = 1'b0;
  logic rst_b;
  always #5 clk = ~clk;

  // AHB-Lite responder signals
  logic [AHW-1:0] haddr;
  logic [DW-1:0]  hwdata;
  logic           hsel, hwrite, hready;
  logic [1:0]     htrans;
  logic [2:0]     hsize;
  logic           hresp, hreadyout;
  logic [DW-1:0]  hrdata;
  logic busy_o, error_intr, notif_intr;

  fhe_mem_if mem_if();

  // AXI manager interface driven by fhe_top's FHE DMA, serviced by the TB sub.
  axi_if #(.AW(AXI_AW), .DW(DW), .IW(AXI_IW), .UW(AXI_UW)) axi (.clk(clk), .rst_n(rst_b));

  fhe_top #(
    .AHB_DATA_WIDTH(DW), .AHB_ADDR_WIDTH(AHW),
    .FHE_AXI_AW(AXI_AW), .FHE_AXI_UW(AXI_UW), .FHE_AXI_IW(AXI_IW)
  ) dut (
    .clk(clk), .rst_b(rst_b),
    .haddr_i(haddr), .hwdata_i(hwdata), .hsel_i(hsel), .hwrite_i(hwrite),
    .hready_i(hready), .htrans_i(htrans), .hsize_i(hsize),
    .hresp_o(hresp), .hreadyout_o(hreadyout), .hrdata_o(hrdata),
    .busy_o(busy_o), .error_intr(error_intr), .notif_intr(notif_intr),
    .fhe_memory_export(mem_if),
    .fhe_axi_r_if(axi), .fhe_axi_w_if(axi),
    // C'-1b: KeyVault seed port. Default run leaves KGKV_CTRL.KV_EN=0 (AHB
    // KGSEED register path); the +KVSEED run provisions dut_kv_* below and
    // enables KV so the keygen root comes from the (modeled) KeyVault instead.
    .fhe_kv_read(dut_kv_read), .fhe_kv_rd_resp(dut_kv_rd_resp)
  );

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

  // AHB-Lite single 32-bit register access
  task automatic ahb_write(input logic [AHW-1:0] a, input logic [31:0] d);
    begin
      @(negedge clk);
      hsel <= 1'b1; htrans <= 2'b10; hsize <= 3'b010; hwrite <= 1'b1; haddr <= a;
      @(negedge clk);
      hsel <= 1'b0; htrans <= 2'b00; hwrite <= 1'b0;
      hwdata <= a[2] ? {d, 32'h0} : {32'h0, d};
      @(negedge clk);
      hwdata <= '0;
    end
  endtask

  task automatic ahb_read(input logic [AHW-1:0] a, output logic [31:0] d);
    begin
      @(negedge clk);
      hsel <= 1'b1; htrans <= 2'b10; hsize <= 3'b010; hwrite <= 1'b0; haddr <= a;
      @(negedge clk);
      hsel <= 1'b0; htrans <= 2'b00;
      @(negedge clk);
      d = a[2] ? hrdata[63:32] : hrdata[31:0];
    end
  endtask

  // write a 64-bit DMA pointer register (lo @ a, hi @ a+4)
  task automatic ahb_write64(input logic [AHW-1:0] a, input logic [63:0] v);
    begin ahb_write(a, v[31:0]); ahb_write(a + 'h4, v[63:32]); end
  endtask

  task automatic run_cmd(input fhe_cmd_e c, input string nm);
    int base, guard;
    base = notif_count;
    ahb_write(A_CTRL, {29'd0, c});
    guard = 0;
    while ((notif_count == base) && (guard < 50_000_000)) begin @(posedge clk); guard++; end
    if (notif_count == base) begin $display("  FAIL: %s never completed (timeout)", nm); errors++; end
    else                          $display("  [dma] %s done (~%0d cyc)", nm, guard);
    @(negedge clk);
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
    else        $display("PASS %s (%0d doubles, rel<2^-30)", name, ndbl);
  endtask

  // ------------------------------------------------------------------
  int          rns_scale;
  logic [31:0] i2f_val;

  initial begin
    if (!$value$plusargs("TVDIR=%s", tvdir)) tvdir = ".";

    hsel=0; hwrite=0; haddr=0; hwdata=0; htrans=0; hsize=3'b010; hready=1'b1;
    for (int i = 0; i < DEPTH; i++) dram[i] = 64'd0;
    rst_b = 1'b0;
    repeat (4) @(negedge clk);
    rst_b = 1'b1;
    repeat (2) @(negedge clk);

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
    ahb_write(A_CONFIG,   32'h0000_0001);    // L = 1

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

    // ---- ENCRYPT: msg<-PTR0(P), c0->PTR2(C0), c1->PTR3(C1) ----
    ahb_write64(A_PTR0_LO, 64'(ADDR_P));
    ahb_write64(A_PTR2_LO, 64'(ADDR_C0));
    ahb_write64(A_PTR3_LO, 64'(ADDR_C1));
    run_cmd(FHE_ENCRYPT, "ENCRYPT");

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
      repeat (20000) @(posedge clk);                // >> a normal encrypt (~5567 cyc)
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
      while (!dut.status_valid && (guard < 50_000_000)) begin @(posedge clk); guard++; end
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
