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
//   Unit testbench for fhe_top with register map v2 (docs/fhe/16 in the
//   Chipyard checkout) and the real datapath (+define+FHE_WALKER).
//
//   The TB plays firmware and host: it provisions a modeled KeyVault entry,
//   reads the 160-bit seed through KV_RD_SEED_CTRL, writes CONFIG and the slot
//   bases, issues commands, and sets up and finishes AES-GCM. Every segment
//   moves through Caliptra's axi_dma and AES engine against an AXI memory over
//   a TB memory array. It checks keygen -> encrypt -> decrypt round trips,
//   coefficient recovery, level refresh, single-seed stream behaviour, the
//   command preconditions, the commit barrier, lease, errors and aborts. With
//   +RPC it is the emulator's Aloha RTL link instead (fhe_rtl.rs).
//
//   Run: tb/run_fhe_top_dma_tb.sh [LOGN]   (default LOGN=8 / N=256)
//   Expect: "fhe_top_dma_tb RESULT: PASS".
//
`timescale 1ns/1ps
module fhe_top_dma_tb
  import fhe_params_pkg::*;
  import kv_defines_pkg::*;   // C'-1b: KeyVault seed model types
;
  localparam int N    = FHE_N;
  localparam int LOGN = FHE_LOGN;
  localparam int AHW  = 15;            // FHE 32KB AHB window -> 15-bit client address
  localparam int DW   = 64;

  // Poly-buffer layout (byte addresses). STRIDE = max(N*8, 2KB).
  localparam int STRIDE = (N*8 > 2048) ? N*8 : 2048;
  localparam int ADDR_P   = 0*STRIDE;  // plaintext
  localparam int ADDR_C0  = 1*STRIDE;  // ciphertext c0
  localparam int ADDR_C1  = (1+FHE_L)*STRIDE;  // ciphertext c1
  localparam int ADDR_OUT = (1+2*FHE_L)*STRIDE;  // recovered slots / limbs
  localparam int ADDR_SEALED = (1+3*FHE_L)*STRIDE;  // the host-sealed ENCRYPT message
  // DMA stream test buffers, 64 KiB each, after the polynomial buffers.
  localparam int SCRATCH  = ((ADDR_SEALED + STRIDE + 'hFFFF) / 'h10000) * 'h10000;
  localparam int COPY_DST = SCRATCH + 'h10000, MARK_DST = SCRATCH + 'h20000;

  // Memory model (64-bit words): at least 1 MiB, and all of the above.
  localparam int MEM_AW = ($clog2(MARK_DST + 'h10000) > 20) ? $clog2(MARK_DST + 'h10000) : 20;
  localparam int DEPTH  = 1 << (MEM_AW - 3);

  // Register byte offsets (register map v2).
  localparam logic [AHW-1:0] A_CTRL        = 'h10;
  localparam logic [AHW-1:0] A_STATUS      = 'h14;
  localparam logic [AHW-1:0] A_CONFIG      = 'h18;
  localparam logic [AHW-1:0] A_CAP         = 'h1C;
  localparam logic [AHW-1:0] A_KV_CTRL     = 'h20;
  localparam logic [AHW-1:0] A_KV_STATUS   = 'h24;
  localparam logic [AHW-1:0] A_XFER_STATUS = 'h28;
  localparam logic [AHW-1:0] A_XFER_LEFT   = 'h2C;
  localparam logic [AHW-1:0] A_SLOT0       = 'h30;   // slot n at 0x30 + 8n
  localparam logic [AHW-1:0] A_OLD_XFER_DATA = 'h50; // removed with the firmware-forward stream
  localparam logic [31:0]    CTRL_ZEROIZE  = 32'h8;
  localparam logic [31:0]    CTRL_INPUT_COMMIT = 32'h10;
  // STATUS fields.
  localparam int ST_READY = 0, ST_VALID = 1, ST_ERROR = 2, ST_KEY_VALID = 3;
  localparam int ST_COMMIT_WAIT = 8, ST_DMA_LEASED = 9;
  // CROM window (docs/fhe/19): word w, lane k at A_CROM + 16*w + 4*k.
  localparam logic [AHW-1:0] A_CROM = 'h4000;
  localparam int CROM_DEPTH = 1 << FHE_CROM_AW;
  localparam logic [31:0] CAP_DMA = 32'd1 << 24;   // DMA_STREAM
  localparam int DMA_AW = 48;   // axi_dma address width (slot range checks)
  localparam logic [31:0] CAP_EXPECTED = 32'(N) | (32'(FHE_L) << 16) | (32'd1 << 20) | CAP_DMA | (32'd2 << 28);  // [20] generated twiddles

  localparam int     RT_SCALE    = 17 + LOGN;
  // The pre-reuse golden key was sampled from this 64-bit seed with IV 0, which
  // is the 160-bit seed {96'b0, KEYGEN_SEED}.
  localparam longint KEYGEN_SEED = 64'hA105_BEEF_0006_A001;
  localparam logic [159:0] SEED_A = {96'd0, KEYGEN_SEED};
  localparam logic [159:0] SEED_B = 160'h0BADF00D_89ABCDEF_01234567_DEADBEEF_CAFEBABE;
  // v1 per-pass ENCRYPT seeds used to capture the pre-reuse ciphertext golden.
  localparam longint REPLAY_A_SEED   = 64'h0006_A002_C0FF_EE77;
  localparam longint REPLAY_ERR_SEED = 64'h2350_e171_5239_2f72;

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
  axi_pkg::axi_dma_hw_req_t  dma_req;
  axi_pkg::axi_dma_hw_resp_t dma_resp;

  fhe_top #(
    .AHB_DATA_WIDTH(DW), .AHB_ADDR_WIDTH(AHW), .DMA_AW(DMA_AW)
  ) dut (
    .clock_live(parent_clock_live),
    .clk(parent_clk), .rst_b(rst_b),
    .haddr_i(haddr), .hwdata_i(hwdata), .hsel_i(hsel), .hwrite_i(hwrite),
    .hready_i(hready), .htrans_i(htrans), .hsize_i(hsize),
    .hresp_o(hresp), .hreadyout_o(hreadyout), .hrdata_o(hrdata),
    .busy_o(busy_o), .error_intr(error_intr), .notif_intr(notif_intr),
    .fhe_memory_export(mem_if),
    // KeyVault seed port, backed by the single-entry model below.
    .fhe_kv_read(dut_kv_read), .fhe_kv_rd_resp(dut_kv_rd_resp),
    // C'-3: Aloha ComputeCore storage banks lifted to the top; the TB supplies
    // them via the behavioral fhe_aloha_mem_top (real SRAM at the SoC level).
    .fhe_aloha_mem(aloha_mem.req)
    , .fhe_dma_req(dma_req), .fhe_dma_resp(dma_resp)
  );

  fhe_aloha_mem_if aloha_mem();
  fhe_aloha_mem_top #(.ILV(1), .SRAM_REUSE(1)) u_aloha_mem (.clk_i(clk), .m(aloha_mem.resp));

  fhe_completion_checker completion_check (
    .clk(clk), .rst_b(rst_b), .zeroize(dut.zeroize),
    .cmd_accept(dut.cmd_write), .ready(dut.ready),
    .status_valid(dut.status_valid), .completions()
  );

  // Match the full-SoC monitor's legal backpressure injection. Never suppress
  // ext_dout_we after issue: it is a registered beat and the walker advanced.
  bit input_stall_checked = 0, output_stall_checked = 0;
  initial if ($test$plusargs("STREAM_STALLS")) begin
    wait (rst_b);
    @(negedge clk);
    while (!(dut.cmd_q == FHE_ENCRYPT && dut.w_busy && dut.w_rd_valid)) @(negedge clk);
    force dut.w_rd_valid = 0;
    force dut.w_rd_pop = 0;
    repeat (64) @(negedge clk);
    release dut.w_rd_valid;
    release dut.w_rd_pop;
    input_stall_checked = 1;
  end
  initial if ($test$plusargs("STREAM_STALLS")) begin
    wait (rst_b);
    @(negedge clk);
    while (!(dut.cmd_q == FHE_ENCRYPT && dut.w_busy && dut.br_active && dut.stream_status[1] &&
             !dut.w_wr_push && dut.w_wr_ready)) @(negedge clk);
    force dut.w_wr_ready = 0;
    repeat (64) @(negedge clk);
    release dut.w_wr_ready;
    output_stall_checked = 1;
  end
  final if ($test$plusargs("STREAM_STALLS")) begin
    assert (input_stall_checked && output_stall_checked)
      else $error("stream stall injections did not execute");
    $display("PASS legal input/output stream backpressure injection");
  end

  // Banked resident keys are transformed in place and never written by
  // application commands. Count only final representation-conversion writes.
  // Independent refresh oracle: record the sampler's committed signed errors,
  // then compare decrypted output to centered input + exactly these samples.
  int refresh_noise [0:N-1];
  int refresh_samples = 0;
  int refresh_snapshots = 0;
  int refresh_lifts = 0;
  always @(posedge clk) begin
    if (rst_b && aloha_mem.eng_step && dut.cmd_q == FHE_REFRESH && dut.w_busy) begin
      if (aloha_mem.ntt_msg0_wea && aloha_mem.ntt_msg0_mask == 8'h80) begin
        refresh_noise[2*int'(aloha_mem.ntt_msg0_addra)] = aloha_mem.ntt_msg0_dina[61] ? -int'(aloha_mem.ntt_msg0_dina[60:56]) : int'(aloha_mem.ntt_msg0_dina[60:56]);
        refresh_samples++;
      end
      if (aloha_mem.ntt_msg1_wea && aloha_mem.ntt_msg1_mask == 8'h80) begin
        refresh_noise[2*int'(aloha_mem.ntt_msg1_addra)+1] = aloha_mem.ntt_msg1_dina[61] ? -int'(aloha_mem.ntt_msg1_dina[60:56]) : int'(aloha_mem.ntt_msg1_dina[60:56]);
        refresh_samples++;
      end
      if (dut.core.CORE.lift_active && dut.core.CORE.lift_we) begin
        if (dut.core.CORE.lift_snapshot) refresh_snapshots++;
        else refresh_lifts++;
      end
    end
  end
  int key_writes [0:FHE_L-1];
  int key_reads [0:FHE_L-1];
  always @(posedge clk) begin
    if (!rst_b) begin
      foreach (key_writes[i]) key_writes[i] = 0;
      foreach (key_reads[i]) key_reads[i] = 0;
    end else if (aloha_mem.eng_step) begin
      assert (!aloha_mem.sk_en) else $fatal(1,"obsolete resident-key copy port used");
      if ((dut.cmd_q == FHE_RECOVER || dut.cmd_q == FHE_REFRESH) && dut.w_busy) begin
        assert (dut.core.CORE.transform_rst || !dut.core.CORE.do_fft)
          else $fatal(1,"recovery entered FFT");
        assert (dut.core.CORE.i2f_rst && dut.core.CORE.prj_rst)
          else $fatal(1,"recovery entered floating decode/project");
        if (dut.cmd_q == FHE_RECOVER) assert (!aloha_mem.fft_higher0_wea && !aloha_mem.fft_higher1_wea)
          else $fatal(1,"recovery modified FFT real workspace");
      end
      if (dut.cmd_q != FHE_KEYGEN)
        assert (!aloha_mem.ntt_v0_wea && !aloha_mem.ntt_v1_wea)
          else $fatal(1,"application command overwrote persistent key");
      if (dut.cmd_q == FHE_KEYGEN && !dut.core.CORE.pwm_rst) begin
        if(aloha_mem.ntt_v0_wea) key_writes[int'(aloha_mem.ntt_v0_addra)/(N/2)]++;
        if(aloha_mem.ntt_v1_wea) key_writes[int'(aloha_mem.ntt_v1_addra)/(N/2)]++;
      end
      if (dut.cmd_q == FHE_ENCRYPT && !dut.core.CORE.pwm_rst)
        key_reads[int'(aloha_mem.ntt_v0_addrb)/(N/2)]++;
      // Modular writes must never clobber samples; sampler writes touch only
      // the upper byte. The stream must serialize only residue bits.
      assert (aloha_mem.ntt_msg0_mask inside {8'h7f,8'h80});
      assert (aloha_mem.ntt_msg1_mask inside {8'h7f,8'h80});
    end
  end

  string state_dump_dir;
  task automatic dump_state(input bit keys);
    int fd;
    if ($value$plusargs("STATE_DUMP=%s", state_dump_dir)) begin
      fd=$fopen({state_dump_dir, keys ? "/key.hex" : "/ciphertext.hex"},"w");
      assert(fd!=0) else $fatal(1,"cannot open state dump");
      for(int limb=0;limb<tb_limbs();limb++)
        for(int i=0;i<N;i++) begin
          if(keys) begin
            if(i%2==0) $fdisplay(fd,"%014h",u_aloha_mem.ntt_v0.mem[limb*(N/2)+i/2]);
            else $fdisplay(fd,"%014h",u_aloha_mem.ntt_v1.mem[limb*(N/2)+i/2]);
          end else begin
            $fdisplay(fd,"%016h",dram[ADDR_C0/8+limb*N+i]);
            $fdisplay(fd,"%016h",dram[ADDR_C1/8+limb*N+i]);
          end
        end
      $fclose(fd);
    end
  endtask
  task automatic check_baseline(input bit keys);
    string dir;
    // The golden holds two limbs; with more installed, limbs 0 and 1 of the
    // key and of a level-2 ciphertext must still match it.
    localparam int GL = 2;
    logic [63:0] expected [0:2*N*GL-1];
    logic [63:0] actual;
    if($value$plusargs("GOLDEN_DIR=%s",dir)) begin
      assert(N==256 && FHE_L>=GL && $test$plusargs("LIMBS2")) else $fatal(1,"golden geometry mismatch");
      $readmemh({dir,keys ? "/key.hex" : "/ciphertext.hex"},expected,0,keys ? N*GL-1 : 2*N*GL-1);
      for(int limb=0;limb<GL;limb++)
        for(int i=0;i<N;i++) begin
          if(keys) begin
            actual=i%2==0 ? {10'd0,u_aloha_mem.ntt_v0.mem[limb*(N/2)+i/2]} :
                           {10'd0,u_aloha_mem.ntt_v1.mem[limb*(N/2)+i/2]};
            assert(actual===expected[limb*N+i]) else $fatal(1,"baseline key mismatch limb=%0d i=%0d",limb,i);
          end else begin
            assert(dram[ADDR_C0/8+limb*N+i]===expected[2*(limb*N+i)])
              else $fatal(1,"baseline c0 mismatch limb=%0d i=%0d",limb,i);
            assert(dram[ADDR_C1/8+limb*N+i]===expected[2*(limb*N+i)+1])
              else $fatal(1,"baseline c1 mismatch limb=%0d i=%0d",limb,i);
          end
        end
      $display("PASS pre-reuse baseline %s: both limbs bit-exact",keys ? "secret" : "ciphertext");
    end
  endtask
  longint measured_cycles;
  bit measured_busy;
  always @(posedge clk) begin
    if(!rst_b) begin measured_busy=0; measured_cycles=0; end
    else begin
      if(dut.w_busy && !measured_busy) measured_cycles=0;
      if(dut.w_busy) measured_cycles++;
      if(!dut.w_busy && measured_busy) $display("FHE_CYCLES cmd=%0d base_cycles=%0d",dut.cmd_q,measured_cycles);
      measured_busy=dut.w_busy;
    end
  end

  // ---- Testbench-only v1 seed replay (no RTL support, nothing to synthesize) ----
  // v1 reloaded the sampler on every ENCRYPT sampling pass from per-pass seeds
  // (ERR_SEED for e0, A_SEED for each limb's a). Forcing the walker's reseed gate
  // and the 160-bit seed (at its source register) reproduces that, so the pre-reuse ciphertext
  // golden can still be checked bit-exact.
  localparam logic [3:0] OP_EXE_CODE = 4'd5;
  localparam logic [1:0] PS_A_CODE = 2'd2, PS_ERR_CODE = 2'd3;
  bit replay_on = 0;
  // Re-force constants every clock (a force with a changing expression is not
  // re-evaluated by every simulator). The walker holds op_w for the whole EXE,
  // and the sampler's reseed pulse comes several cycles after decode.
  always @(posedge clk) begin
    if (replay_on) begin
      if (dut.walker.op_w[31:28] == OP_EXE_CODE && dut.walker.op_w[27:26] == PS_A_CODE) begin
        force dut.i_fhe_kv_seed.seed_q = {96'd0, REPLAY_A_SEED};
        force dut.w_reseed_en = 1'b1;
      end else if (dut.walker.op_w[31:28] == OP_EXE_CODE && dut.walker.op_w[27:26] == PS_ERR_CODE) begin
        force dut.i_fhe_kv_seed.seed_q = {96'd0, REPLAY_ERR_SEED};
        force dut.w_reseed_en = 1'b1;
      end else begin
        force dut.w_reseed_en = 1'b0;
      end
    end
  end
  task automatic replay_v1_seeds(input bit on);
    replay_on = on;
    if (!on) begin
      @(posedge clk); #1;
      release dut.w_reseed_en;
      // A released variable keeps the forced value until its next assignment;
      // the following KeyVault read clears and reloads seed_q.
      release dut.i_fhe_kv_seed.seed_q;
    end
  endtask

  // ---- Behavioral single-entry KeyVault model (slot 9, the FHE seed slot) ----
  localparam int    KV_ENTRY = 9;
  kv_read_t         dut_kv_read;
  kv_rd_resp_t      dut_kv_rd_resp;
  logic [31:0]      kv_ent [0:KV_NUM_DWORDS-1];
  bit               kv_deny = 0;   // model a missing dest_valid / lock_use
  always_comb begin
    dut_kv_rd_resp.read_data = kv_ent[dut_kv_read.read_offset];
    dut_kv_rd_resp.error     = kv_deny || (dut_kv_read.read_entry != KV_ENTRY_ADDR_W'(KV_ENTRY));
    dut_kv_rd_resp.last      = (dut_kv_read.read_offset == KV_ENTRY_SIZE_W'(4));
  end

  fhe_mem_top mem_inst (.clk_i(clk), .fhe_memory_export(mem_if));

  // Firmware memory: plaintext, ciphertext and output buffers.
  logic [63:0] dram [0:DEPTH-1];

`include "caliptra_reg_defines.svh"
`include "caliptra_reg_field_defines.svh"
  // ---- Caliptra axi_dma with an AXI memory over the same `dram` ----
  axi_if #(.AW(DMA_AW), .DW(32), .IW(1), .UW(32)) dma_axi (.clk(clk), .rst_n(rst_b));

  // ---- Caliptra AES engine: the DMA's AES port, and an AHB port for the
  //      firmware/host GCM steps (key, IV, AAD, tag, host-side seal/open) ----
  localparam int AES_AW = 12;
  logic [AES_AW-1:0]         aes_haddr = '0;
  logic [DW-1:0]             aes_hwdata = '0, aes_hrdata;
  logic                      aes_hsel = 1'b0, aes_hwrite = 1'b0, aes_hresp, aes_hreadyout;
  logic [1:0]                aes_htrans = 2'b00;
  logic                      aes_input_ready, aes_output_valid, aes_status_idle;
  logic                      aes_dma_dv, aes_dma_hold, aes_dma_err;
  soc_ifc_pkg::soc_ifc_req_t aes_dma_req;
  logic [31:0]               aes_dma_rdata;
  aes_clp_wrapper #(.CIF_DATA_WIDTH(32), .AHB_DATA_WIDTH(DW), .AHB_ADDR_WIDTH(AES_AW)) i_aes (
    .clk(clk), .reset_n(rst_b), .cptra_pwrgood(rst_b),
    .haddr_i(aes_haddr), .hwdata_i(aes_hwdata), .hsel_i(aes_hsel), .hwrite_i(aes_hwrite),
    .hready_i(aes_hreadyout), .htrans_i(aes_htrans), .hsize_i(3'b010),
    .hresp_o(aes_hresp), .hreadyout_o(aes_hreadyout), .hrdata_o(aes_hrdata),
    .ocp_lock_in_progress(1'b0), .key_release_key_size('0),
    .input_ready_o(aes_input_ready), .output_valid_o(aes_output_valid), .status_idle_o(aes_status_idle),
    .dma_req_dv(aes_dma_dv), .dma_req_write(aes_dma_req.write),
    .dma_req_addr(aes_dma_req.addr[AES_AW-1:0]), .dma_req_wdata(aes_dma_req.wdata),
    .dma_req_hold(aes_dma_hold), .dma_req_error(aes_dma_err), .dma_req_rdata(aes_dma_rdata),
    .kv_read(), .kv_rd_resp('0), .kv_write(), .kv_wr_resp('0),
    .busy_o(), .error_intr(), .notif_intr(), .debugUnlock_or_scan_mode_switch(1'b0)
  );
  logic                       dma_dv = 1'b0, dma_hold, dma_err, dma_notif, dma_error_intr;
  logic [31:0]                dma_rdata;
  soc_ifc_pkg::soc_ifc_req_t  dma_reg_req = '0;
  axi_dma_top #(.AW(DMA_AW), .DW(32), .UW(32), .IW(1)) i_dma (
    .clk(clk), .cptra_pwrgood(rst_b), .rst_n(rst_b),
    .recovery_data_avail(1'b0), .recovery_image_activated(1'b0),
    .mbox_lock(1'b0), .sha_lock(1'b0), .debugUnlock_or_scan_mode_switch(1'b0),
    .ocp_lock_in_progress(1'b0), .key_release_addr('0), .key_release_size('0),
    .aes_input_ready(aes_input_ready), .aes_output_valid(aes_output_valid), .aes_status_idle(aes_status_idle),
    .aes_req_dv(aes_dma_dv), .aes_req_hold(aes_dma_hold), .aes_req_data(aes_dma_req),
    .aes_rdata(aes_dma_rdata), .aes_err(aes_dma_err),
    .kv_read(), .kv_rd_resp('0), .axuser('0),
    .m_axi_w_if(dma_axi.w_mgr), .m_axi_r_if(dma_axi.r_mgr),
    .dv(dma_dv), .req_data(dma_reg_req), .hold(dma_hold), .rdata(dma_rdata), .error(dma_err),
    .mb_dv(), .mb_hold(1'b0), .mb_error(1'b0), .mb_data(), .mb_rdata('0),
    .notif_intr(dma_notif), .error_intr(dma_error_intr),
    .hw_req(dma_req), .hw_resp(dma_resp)
  );
  logic              mem_dv, mem_write, mem_hld = 1'b0, mem_rd_err = 1'b0;
  logic [DMA_AW-1:0] mem_addr;
  logic [31:0]       mem_wdata, mem_rdata;
  axi_sub #(.AW(DMA_AW), .DW(32), .UW(32), .IW(1), .EX_EN(0), .C_LAT(0)) i_axi_mem (
    .clk(clk), .rst_n(rst_b), .s_axi_w_if(dma_axi.w_sub), .s_axi_r_if(dma_axi.r_sub),
    .dv(mem_dv), .addr(mem_addr), .write(mem_write), .user(), .id(),
    .wdata(mem_wdata), .wstrb(), .size(), .rdata(mem_rdata), .last(),
    .hld(mem_hld), .rd_err(mem_rd_err), .wr_err(1'b0)
  );
  assign mem_rdata = mem_addr[2] ? dram[mem_addr[MEM_AW-1:3]][63:32] : dram[mem_addr[MEM_AW-1:3]][31:0];
  always @(posedge clk)
    if (mem_dv && !mem_hld && mem_write) begin
      if (mem_addr[2]) dram[mem_addr[MEM_AW-1:3]][63:32] = mem_wdata;
      else             dram[mem_addr[MEM_AW-1:3]][31:0]  = mem_wdata;
    end
  // Memory backpressure under STREAM_STALLS.
  bit stream_stalls;
  initial stream_stalls = $test$plusargs("STREAM_STALLS");
  always @(negedge clk) if (stream_stalls) mem_hld <= ($urandom_range(0, 3) == 0);

  // Firmware view of the DMA registers (generated axi_dma_reg offsets and fields).
  localparam logic [31:0] DMA_GO_AXI_COPY = `AXI_DMA_REG_CTRL_GO_MASK |
      (32'(axi_dma_reg_pkg::axi_dma_reg__ctrl__rd_route__rd_route_e__AXI_WR) << `AXI_DMA_REG_CTRL_RD_ROUTE_LOW) |
      (32'(axi_dma_reg_pkg::axi_dma_reg__ctrl__wr_route__wr_route_e__AXI_RD) << `AXI_DMA_REG_CTRL_WR_ROUTE_LOW);
  task automatic dma_fw_access(input bit write, input logic [31:0] a, input logic [31:0] wd,
                               output logic [31:0] rd);
    @(negedge clk);
    dma_reg_req = '0;
    dma_reg_req.addr = 18'(a); dma_reg_req.wdata = wd; dma_reg_req.wstrb = '1; dma_reg_req.write = write;
    dma_dv = 1'b1;
    do @(posedge clk); while (dma_hold);
    rd = dma_rdata;
    @(negedge clk);
    dma_dv = 1'b0;
  endtask
  task automatic dma_fw_write(input logic [31:0] a, input logic [31:0] wd);
    logic [31:0] unused;
    dma_fw_access(1'b1, a, wd, unused);
  endtask
  task automatic dma_fw_read(input logic [31:0] a, output logic [31:0] rd);
    dma_fw_access(1'b0, a, '0, rd);
  endtask
  // Firmware memory-to-memory DMA copy (no wait for completion).
  task automatic dma_fw_copy_start(input int src, input int dst, input int bytes);
    dma_fw_write(`AXI_DMA_REG_SRC_ADDR_L, 32'(src)); dma_fw_write(`AXI_DMA_REG_SRC_ADDR_H, 0);
    dma_fw_write(`AXI_DMA_REG_DST_ADDR_L, 32'(dst)); dma_fw_write(`AXI_DMA_REG_DST_ADDR_H, 0);
    dma_fw_write(`AXI_DMA_REG_BYTE_COUNT, 32'(bytes));
    dma_fw_write(`AXI_DMA_REG_CTRL, DMA_GO_AXI_COPY);
  endtask

  // ------------------------------------------------------------------
  int notif_count;
  always @(posedge clk or negedge rst_b)
    if (!rst_b)          notif_count <= 0;
    else if (notif_intr) notif_count <= notif_count + 1;

  int    errors = 0;
  string tvdir;
  longint g_input [0:N];
  logic [63:0] first_a [0:N-1];   // c1 (= uniform a, limb 0) of the first ENCRYPT after KEYGEN
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

  // write a 64-bit register pair (lo @ a, hi @ a+4)
  task automatic ahb_write64(input logic [AHW-1:0] a, input logic [63:0] v);
    begin ahb_write(a, v[31:0]); ahb_write(a + 'h4, v[63:32]); end
  endtask

  // Slot base addresses: firmware's copy, used to service the stream.
  logic [63:0] slot_base [0:3];
  task automatic set_slot(input int slot, input logic [63:0] base);
    slot_base[slot] = base;
    ahb_write64(A_SLOT0 + AHW'(8*slot), base);
  endtask
  // ENCRYPT: message in slot 0, c0/c1 out in slots 2/3.
  task automatic enc_slots();
    set_slot(0, 64'(ADDR_P)); set_slot(2, 64'(ADDR_C0)); set_slot(3, 64'(ADDR_C1));
  endtask
  // DECRYPT: c0/c1 in slots 0/1, decoded slots out in slot 2.
  task automatic dec_slots();
    set_slot(0, 64'(ADDR_C0)); set_slot(1, 64'(ADDR_C1)); set_slot(2, 64'(ADDR_OUT));
  endtask
  function automatic int tb_limbs();
    return $test$plusargs("LIMBS2") ? 2 : 1;
  endfunction

  // CONFIG = {SCALE[27:16], LOGN[7:4], L[3:0]}; LOGN defaults to the built value.
  task automatic cfg(input int l, input logic [11:0] scale, input int logn = LOGN);
    ahb_write(A_CONFIG, {4'd0, scale, 8'd0, 4'(logn), 4'(l)});
  endtask

  // Provision the KeyVault model and read the seed through KV_RD_SEED_CTRL.
  task automatic provision_kv(input logic [159:0] seed);
    for (int i = 0; i < KV_NUM_DWORDS; i++) kv_ent[i] = (i < 5) ? seed[32*i +: 32] : 32'd0;
  endtask
  task automatic kv_seed_read(input int entry, output logic [7:0] kv_err);
    logic [31:0] d;
    int guard = 0;
    ahb_write(A_KV_CTRL, {26'd0, 5'(entry), 1'b1});
    do begin ahb_read(A_KV_STATUS, d); guard++; end while (!(d[0] && d[1]) && guard < 1000);
    if (!(d[0] && d[1])) begin $display("FAIL: KeyVault seed read never completed"); errors++; end
    kv_err = d[9:2];
  endtask
  task automatic load_seed(input logic [159:0] seed);
    logic [7:0] kv_err;
    provision_kv(seed);
    kv_seed_read(KV_ENTRY, kv_err);
    if (kv_err != 0) begin $display("FAIL: KeyVault seed read error %0d", kv_err); errors++; end
    if (dut.kv_seed !== seed) begin
      $display("FAIL: fhe_kv_seed holds %h, expected %h", dut.kv_seed, seed); errors++;
    end
  endtask

  // Directed bus-level checks of the private stream while the walker is idle.
  // ---- Firmware/host AES-GCM steps, over the AES engine's AHB port ----
  // The ENCRYPT message and the DECRYPT slots cross the AES boundary: the host
  // seals the message, the DMA decrypts it into Aloha, firmware checks the tag
  // at COMMIT_WAIT; DECRYPT's output is encrypted on its way to memory and the
  // host opens it. Word order on both paths is memory order (low word first).
  localparam logic [255:0] GCM_KEY = 256'h6d6a8f94_67308308_feffe992_8665731c_6d6a8f94_67308308_feffe992_8665731c;
  localparam logic [95:0]  GCM_IV  = 96'hdecaf888_faced8ad_cafebabe;
  localparam logic [31:0]  AES_CTRL_GCM_256 = (32'(aes_pkg::AES_GCM) << `AES_REG_CTRL_SHADOWED_MODE_LOW) |
                                              (32'(aes_pkg::AES_256) << `AES_REG_CTRL_SHADOWED_KEY_LEN_LOW);
  localparam logic [31:0]  AES_CLP_CTRL0 = `CLP_AES_CLP_REG_CTRL0 - `CLP_AES_REG_BASE_ADDR;
  logic [127:0]            sealed_tag;

  // Same AHB-Lite sequence as ahb_access, on the AES engine's port.
  task automatic aes_access(input bit write, input logic [31:0] a, input logic [31:0] wd,
                            output logic [31:0] rd);
    bit err;
    @(negedge clk);
    aes_hsel <= 1'b1; aes_htrans <= 2'b10; aes_hwrite <= write; aes_haddr <= AES_AW'(a);
    @(negedge clk);
    aes_hsel <= 1'b0; aes_htrans <= 2'b00; aes_hwrite <= 1'b0;
    if (write) aes_hwdata <= a[2] ? {wd, 32'h0} : {32'h0, wd};
    #1;
    err = aes_hresp;
    while (!aes_hreadyout) begin @(negedge clk); #1; end
    err |= aes_hresp;
    if (err) begin $display("FAIL: AES AHB error at 0x%0h", a); errors++; end
    rd = a[2] ? aes_hrdata[63:32] : aes_hrdata[31:0];
    @(negedge clk);
    aes_hwdata <= '0;
  endtask
  task automatic aes_wr(input logic [31:0] a, input logic [31:0] d);
    logic [31:0] unused;
    aes_access(1'b1, a, d, unused);
  endtask
  task automatic aes_wr2(input logic [31:0] a, input logic [31:0] d);   // shadowed register
    aes_wr(a, d); aes_wr(a, d);
  endtask
  task automatic aes_wait(input logic [31:0] mask);
    logic [31:0] st;
    int guard = 0;
    do begin aes_access(1'b0, `AES_REG_STATUS, '0, st); guard++; end while (!(st & mask) && guard < 10000);
    if (!(st & mask)) begin $display("FAIL: AES STATUS 0x%08h never showed 0x%0h", st, mask); errors++; end
  endtask
  function automatic logic [31:0] gcm_ctrl(input aes_pkg::gcm_phase_e phase, input int bytes);
    return (32'(phase) << `AES_REG_CTRL_GCM_SHADOWED_PHASE_LOW) |
           (32'(bytes) << `AES_REG_CTRL_GCM_SHADOWED_NUM_VALID_BYTES_LOW);
  endfunction

  // GCM context up to the text phase: mode, key, IV. No extra data, as in the
  // session protocol (docs/fhe/16 "Session protocol on the DMA path").
  task automatic gcm_begin(input aes_pkg::aes_op_e op);
    aes_wait(`AES_REG_STATUS_IDLE_MASK);
    aes_wr(AES_CLP_CTRL0, 32'h0);   // no endian swap
    aes_wait(`AES_REG_STATUS_IDLE_MASK);
    aes_wr2(`AES_REG_CTRL_SHADOWED, (32'(op) << `AES_REG_CTRL_SHADOWED_OPERATION_LOW) | AES_CTRL_GCM_256);
    aes_wait(`AES_REG_STATUS_IDLE_MASK);
    aes_wr2(`AES_REG_CTRL_GCM_SHADOWED, gcm_ctrl(aes_pkg::GCM_INIT, 16));
    aes_wait(`AES_REG_STATUS_IDLE_MASK);
    for (int j = 0; j < 8; j++) begin
      aes_wr(`AES_REG_KEY_SHARE0_0 + 4*j, GCM_KEY[32*j +: 32]);
      aes_wr(`AES_REG_KEY_SHARE1_0 + 4*j, 32'h0);
    end
    aes_wait(`AES_REG_STATUS_IDLE_MASK);
    for (int j = 0; j < 4; j++) aes_wr(`AES_REG_IV_0 + 4*j, (j < 3) ? GCM_IV[32*j +: 32] : 32'h0);
    aes_wait(`AES_REG_STATUS_IDLE_MASK);
  endtask
  // Text phase over AHB: `words` 64-bit words from dram[src] to dram[dst].
  task automatic gcm_text_ahb(input int src, input int dst, input int words);
    logic [31:0] o [0:3];
    aes_wait(`AES_REG_STATUS_IDLE_MASK);
    aes_wr2(`AES_REG_CTRL_GCM_SHADOWED, gcm_ctrl(aes_pkg::GCM_TEXT, 16));
    for (int b = 0; b < words/2; b++) begin
      aes_wait(`AES_REG_STATUS_INPUT_READY_MASK);
      for (int j = 0; j < 4; j++) aes_wr(`AES_REG_DATA_IN_0 + 4*j, dram[src/8 + 2*b + j/2][32*(j%2) +: 32]);
      aes_wait(`AES_REG_STATUS_OUTPUT_VALID_MASK);
      for (int j = 0; j < 4; j++) aes_access(1'b0, `AES_REG_DATA_OUT_0 + 4*j, '0, o[j]);
      dram[dst/8 + 2*b]     = {o[1], o[0]};
      dram[dst/8 + 2*b + 1] = {o[3], o[2]};
    end
  endtask
  // Tag phase, then discard the context.
  task automatic gcm_finish(input int text_bytes, output logic [127:0] tag);
    aes_wait(`AES_REG_STATUS_IDLE_MASK);
    aes_wr2(`AES_REG_CTRL_GCM_SHADOWED, gcm_ctrl(aes_pkg::GCM_TAG, 16));
    // len(AAD) = 0 || len(text) in bits, big-endian 64-bit fields
    aes_wr(`AES_REG_DATA_IN_0 + 0,  32'h0);
    aes_wr(`AES_REG_DATA_IN_0 + 4,  32'h0);
    aes_wr(`AES_REG_DATA_IN_0 + 8,  32'h0);
    aes_wr(`AES_REG_DATA_IN_0 + 12, {<<8{32'(text_bytes * 8)}});
    aes_wait(`AES_REG_STATUS_OUTPUT_VALID_MASK);
    for (int j = 0; j < 4; j++) aes_access(1'b0, `AES_REG_DATA_OUT_0 + 4*j, '0, tag[32*j +: 32]);
    gcm_discard();
  endtask
  // Return the engine to manual mode with cleared state.
  task automatic gcm_discard();
    aes_wr2(`AES_REG_CTRL_SHADOWED, 32'h1 << `AES_REG_CTRL_SHADOWED_MANUAL_OPERATION_LOW);
    aes_wr(`AES_REG_TRIGGER, (32'h1 << `AES_REG_TRIGGER_KEY_IV_DATA_IN_CLEAR_LOW) |
                             (32'h1 << `AES_REG_TRIGGER_DATA_OUT_CLEAR_LOW));
  endtask

  // Host: seal the slot-0 plaintext (firmware's slot_base[0]) and point the
  // hardware slot 0 at the sealed copy.
  task automatic seal_message();
    gcm_begin(aes_pkg::AES_ENC);
    gcm_text_ahb(int'(slot_base[0]), ADDR_SEALED, N);
    gcm_finish(N*8, sealed_tag);
    ahb_write64(A_SLOT0, 64'(ADDR_SEALED));
  endtask
  // Firmware at COMMIT_WAIT: finish GCM; INPUT_COMMIT if the tag matches,
  // else ZEROIZE.
  task automatic commit_input(output bit tag_ok);
    logic [127:0] tag;
    gcm_finish(N*8, tag);
    tag_ok = (tag == sealed_tag);
    ahb_write(A_CTRL, tag_ok ? CTRL_INPUT_COMMIT : CTRL_ZEROIZE);
  endtask
  // From COMMIT_WAIT: check the tag and wait for the command's completion.
  task automatic commit_and_wait(input string nm, output bit tag_ok);
    int base = notif_count;
    commit_input(tag_ok);
    if (tag_ok) wait_notif(base, nm);
    else        wait_status(ST_VALID, nm);
  endtask
  // After DECRYPT: finish GCM; the host opens the output in place.
  task automatic open_output(input bit open);
    logic [127:0] tag, host_tag;
    gcm_finish(N*8, tag);
    if (open) begin
      gcm_begin(aes_pkg::AES_DEC);
      gcm_text_ahb(int'(slot_base[2]), int'(slot_base[2]), N);
      gcm_finish(N*8, host_tag);
      if (host_tag !== tag) begin
        $display("FAIL: DECRYPT output tag %h, host computed %h", tag, host_tag); errors++;
      end
    end
  endtask

  // Issue a command, with the AES-GCM context it needs;
  // `base` is notif_count before it. forge >= 0 flips a bit of that sealed
  // message word (one plaintext mantissa bit, CTR mode) after sealing.
  task automatic issue_cmd(input fhe_cmd_e c, output int base, input int forge = -1);
    base = notif_count;
    if (c == FHE_ENCRYPT) begin
      seal_message();
      if (forge >= 0) dram[ADDR_SEALED/8 + forge] ^= 64'h1;
      gcm_begin(aes_pkg::AES_DEC);
    end
    if (c == FHE_DECRYPT) gcm_begin(aes_pkg::AES_ENC);
    ahb_write(A_CTRL, {29'd0, c});
  endtask

  // Wait for the next notif, polling STATUS meanwhile.
  task automatic wait_notif(input int base, input string nm);
    int guard = 0;
    logic [31:0] st;
    while ((notif_count == base) && (guard < 50_000_000)) begin ahb_read(A_STATUS, st); guard++; end
    if (notif_count == base) begin $display("  FAIL: %s never completed (timeout)", nm); errors++; end
    else                          $display("  [fhe] %s notif (%0d polling iterations)", nm, guard);
  endtask

  // Complete a command issued when notif_count was `base`; it must end with
  // `cause` (ERROR unless NONE). With the DMA stream, ENCRYPT stops at
  // COMMIT_WAIT for the tag check.
  task automatic finish_cmd(input fhe_cmd_e c, input int base, input string nm,
                            input logic [3:0] cause = FHE_EC_NONE);
    logic [31:0] st;
    cpu_sleep = 1; // parent must stay awake through the stream and completion delivery
    wait_notif(base, nm);
    if (c == FHE_ENCRYPT) begin
      bit tag_ok;
      ahb_read(A_STATUS, st);
      if (!st[ST_COMMIT_WAIT] || st[ST_VALID]) begin
        $display("  FAIL: %s notif without COMMIT_WAIT (STATUS 0x%08h)", nm, st); errors++;
      end
      commit_and_wait(nm, tag_ok);
      if (!tag_ok) begin $display("  FAIL: %s message tag mismatch", nm); errors++; end
    end
    @(negedge clk);
    cpu_sleep = 0;
    ahb_read(A_STATUS, st);
    if (st[ST_ERROR] != (cause != FHE_EC_NONE) || st[7:4] != cause) begin
      $display("  FAIL: %s completed with STATUS 0x%08h, expected cause %0d", nm, st, cause); errors++;
    end else if (cause != FHE_EC_NONE)
      $display("PASS %s -> ERROR cause %0d", nm, cause);
    if (c == FHE_DECRYPT) open_output(cause == FHE_EC_NONE);
  endtask

  task automatic run_cmd(input fhe_cmd_e c, input string nm, input logic [3:0] cause = FHE_EC_NONE);
    int base;
    issue_cmd(c, base);
    finish_cmd(c, base, nm, cause);
  endtask

  task automatic wait_status(input int bit_idx, input string nm);
    logic [31:0] d;
    int guard = 0;
    do begin ahb_read(A_STATUS, d); guard++; end while (!d[bit_idx] && guard < 100000);
    if (!d[bit_idx]) begin $display("FAIL: %s: STATUS bit %0d never set (0x%08h)", nm, bit_idx, d); errors++; end
  endtask

  // Issue a command expected to be refused, and check the reported cause.
  task automatic expect_reject(input logic [2:0] c, input logic [3:0] cause, input string nm);
    logic [31:0] st;
    int guard = 0;
    ahb_write(A_CTRL, {29'd0, c});
    do begin ahb_read(A_STATUS, st); guard++; end while (!(st[ST_READY] && st[ST_VALID]) && guard < 1000);
    if (st[ST_ERROR] && st[7:4] == cause) $display("PASS precondition: %s -> ERROR cause %0d", nm, cause);
    else begin
      $display("FAIL precondition: %s -> STATUS 0x%08h, expected ERROR cause %0d", nm, st, cause); errors++;
    end
  endtask

  // Read N words of firmware memory at `base` (e.g. the ciphertext c1 = uniform
  // `a`, or the recovered OUT slots) into dst.
  task automatic capture_slots(ref longint dst [], input int base);
    for (int i = 0; i < N; i++) dst[i] = dram[(base/8) + i];
  endtask

  // Resident key snapshot, to compare a later KEYGEN against.
  logic [53:0] key0 [0:N*FHE_L/2-1], key1 [0:N*FHE_L/2-1];
  task automatic save_key();
    for (int i = 0; i < N*FHE_L/2; i++) begin
      key0[i] = u_aloha_mem.ntt_v0.mem[i];
      key1[i] = u_aloha_mem.ntt_v1.mem[i];
    end
  endtask
  function automatic int key_diff();
    key_diff = 0;
    for (int i = 0; i < N*FHE_L/2; i++)
      if (u_aloha_mem.ntt_v0.mem[i] !== key0[i] || u_aloha_mem.ntt_v1.mem[i] !== key1[i]) key_diff++;
  endfunction

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
    real max_abs_error = 0.0;
    for (i = 0; i < ndbl; i++) begin
      real delta;
      delta = $bitstoreal(res[i]) - $bitstoreal(gold[i]);
      if (delta < 0.0) delta = -delta;
      if (delta > max_abs_error) max_abs_error = delta;
    end
    $display("FHE_PRECISION %s max_abs_error=%.12g", name, max_abs_error);
    for (i = 0; i < ndbl; i++)
      if (!close(res[i], gold[i], eps)) begin
        if (nerr < 8) $display("  %s[%0d]: got %h (%g) exp %h (%g)", name, i,
                               res[i], $bitstoreal(res[i]), gold[i], $bitstoreal(gold[i]));
        nerr++;
      end
    if (nerr) begin $display("FAIL %s: %0d/%0d", name, nerr, ndbl); errors++; end
    else        $display("PASS %s (%0d doubles, relative tolerance=%g, absolute floor=%g)", name, ndbl, eps, fft_abs_floor);
  endtask

  int          rns_scale;
  logic [31:0] i2f_val;

  task automatic rekey(input string nm);
    load_seed(SEED_A);
    cfg(2, 12'(rns_scale));
    run_cmd(FHE_KEYGEN, nm);
  endtask

  // Residue v of limb li, centred in (-q_i/2, q_i/2].
  function automatic longint signed centred(input int li, input logic [63:0] v);
    logic [63:0] q;
    q = fhe_q(4'(li));
    return (v > q/2) ? longint'(v - q) : longint'(v);
  endfunction

  // RECOVER the ciphertext in slots 0/1 at level l; every limb must give the
  // same centred coefficient as limb 0.
  task automatic check_limbs_agree(input int l, input string nm);
    if (!FHE_RECOVER_EN) return;  // production build: no RECOVER
    cfg(l, 12'(rns_scale));
    dec_slots();
    run_cmd(FHE_RECOVER, {nm, ": RECOVER"});
    for (int i = 0; i < N; i++) begin
      longint signed c0;
      c0 = centred(0, dram[ADDR_OUT/8 + i]);
      for (int li = 1; li < l; li++)
        assert (centred(li, dram[ADDR_OUT/8 + li*N + i]) == c0)
          else $fatal(1, "%s: limb %0d disagrees with limb 0 at %0d", nm, li, i);
    end
  endtask

  // Level sweep, optional MNIST, verdict.
  task automatic finish_run();
    string mnist_dir;
    level_sweep();
    if ($value$plusargs("MNIST=%s",mnist_dir)) run_mnist(mnist_dir);
    if (errors == 0) $display("fhe_top_dma_tb RESULT: PASS");
    else             $display("fhe_top_dma_tb RESULT: FAIL (%0d error(s))", errors);
    $finish;
  endtask

  // Every level 1..FHE_L against the resident key, which holds all FHE_L limbs.
  task automatic level_sweep();
    longint reco [];
    int nonzero;
    reco = new[N];
    // Key: c0 = 0 and c1 = 1 (a constant NTT) recover s in every limb, so a
    // wrong per-limb prime, R^2 or table entry shows as a non-ternary or
    // disagreeing limb, independent of how encryption uses the key.
    if (FHE_RECOVER_EN) begin
    for (int i = 0; i < FHE_L*N; i++) begin
      dram[ADDR_C0/8 + i] = 0;
      dram[ADDR_C1/8 + i] = 1;
    end
    check_limbs_agree(FHE_L, "resident key");
    nonzero = 0;
    for (int i = 0; i < N; i++) begin
      longint signed s;
      s = centred(0, dram[ADDR_OUT/8 + i]);
      assert (s >= -1 && s <= 1) else $fatal(1, "key coefficient %0d is %0d, not ternary", i, s);
      if (s != 0) nonzero++;
    end
    assert (nonzero > 0 && nonzero < N) else $fatal(1, "degenerate key: %0d nonzero coefficients", nonzero);
    $display("PASS key: all %0d limbs recover the same ternary secret (%0d nonzero)", FHE_L, nonzero);
    end

    for (int l = 1; l <= FHE_L; l++) begin
      cfg(l, 12'(rns_scale));
      enc_slots();
      run_cmd(FHE_ENCRYPT, $sformatf("ENCRYPT at level %0d", l));
      check_limbs_agree(l, $sformatf("ENCRYPT level %0d", l));
      cfg(1, 12'(i2f_val));
      dec_slots();
      run_cmd(FHE_DECRYPT, $sformatf("DECRYPT level-%0d ciphertext", l));
      capture_slots(reco, ADDR_OUT);
      check_fft(reco, g_input, N, $sformatf("level %0d ENCRYPT round trip", l), 1.0e-3);

      // REFRESH limb 0 up to level l, in place.
      cfg(l, 12'(rns_scale));
      dec_slots();
      set_slot(2, 64'(ADDR_C0)); set_slot(3, 64'(ADDR_C1));
      run_cmd(FHE_REFRESH, $sformatf("REFRESH to level %0d", l));
      check_limbs_agree(l, $sformatf("REFRESH level %0d", l));
      cfg(1, 12'(i2f_val));
      dec_slots();
      run_cmd(FHE_DECRYPT, $sformatf("DECRYPT refreshed level-%0d ciphertext", l));
      capture_slots(reco, ADDR_OUT);
      check_fft(reco, g_input, N, $sformatf("level %0d REFRESH round trip", l), 1.0e-3);
    end
    $display("PASS level sweep: ENCRYPT and REFRESH at every level 1..%0d", FHE_L);
  endtask

  task automatic expect_dma_released(input string nm);
    if (!dma_resp.idle || dut.br_lease) begin
      $display("FAIL: %s left the DMA busy or leased", nm); errors++;
    end
  endtask

  // The table firmware embeds (fft_rns_rom.mem in the run directory), copied
  // through the CROM window as firmware does: ascending 32-bit stores.
  logic [127:0] crom_image [0:FHE_CROM_WORDS-1];
  task automatic crom_store(input int w, input logic [127:0] v);
    for (int k = 0; k < 4; k++) ahb_write(A_CROM + AHW'(16*w + 4*k), v[32*k +: 32]);
  endtask
  // A word reaches the array the cycle after its lane-3 store; settle before
  // reading the array by backdoor.
  task automatic crom_settle();
    repeat (2) @(posedge clk);
  endtask
  task automatic load_crom();
    $readmemh("fft_rns_rom.mem", crom_image);
    for (int w = 0; w < FHE_CROM_WORDS; w++) crom_store(w, crom_image[w]);
    crom_settle();
  endtask
  // Checks the copy, and the window rules: write-only, idle-only, bounded, and
  // invisible to the register block.
  task automatic check_crom_window();
    logic [31:0] d, cfg_before;
    bit err;
    int bad = 0;
    for (int w = 0; w < FHE_CROM_WORDS; w++)
      if (u_aloha_mem.crom.mem[w] !== crom_image[w]) begin
        if (bad < 4) $display("  CROM word %0d: 0x%032h, expected 0x%032h", w, u_aloha_mem.crom.mem[w], crom_image[w]);
        bad++;
      end
    if (bad) begin $display("FAIL: %0d CROM words differ after the copy", bad); errors++; end
    ahb_access(1'b0, A_CROM + 'h10, '0, d, err);
    if (err || d != 0) begin $display("FAIL: CROM window read err %0d data 0x%08h", err, d); errors++; end
    // Word 1, lane 0 and lane 2 alias CTRL (0x10) and CONFIG (0x18) in the low
    // address bits; neither register may change.
    ahb_read(A_CONFIG, cfg_before);
    ahb_write(A_CROM + 'h18, 32'hffff_ffff);
    ahb_write(A_CROM + 'h10, 32'h2);
    ahb_read(A_CONFIG, d);
    if (d != cfg_before) begin $display("FAIL: CROM store reached CONFIG"); errors++; end
    ahb_read(A_STATUS, d);
    if (!d[ST_READY] || d[ST_VALID]) begin $display("FAIL: CROM store started a command"); errors++; end
    crom_store(1, crom_image[1]);
    // A store past the CROM depth must not wrap onto word 0.
    if (CROM_DEPTH < 512) crom_store(CROM_DEPTH, ~crom_image[0]);
    crom_settle();
    if (u_aloha_mem.crom.mem[0] !== crom_image[0] || u_aloha_mem.crom.mem[1] !== crom_image[1]) begin
      $display("FAIL: CROM word 0/1 changed by an aliased or out-of-range store"); errors++;
    end
    if (!errors) $display("PASS CROM copy (%0d words), write-only, bounded, separate from registers", FHE_CROM_WORDS);
  endtask
  // A store while a command runs is dropped (called with a command in flight).
  task automatic crom_store_while_busy();
    logic [31:0] d;
    ahb_read(A_STATUS, d);
    if (d[ST_READY]) $fatal(1, "crom_store_while_busy needs a running command");
    crom_store(2, ~crom_image[2]);
    crom_settle();
    if (u_aloha_mem.crom.mem[2] !== crom_image[2]) begin
      $display("FAIL: CROM store accepted while busy"); errors++;
    end else $display("PASS CROM store dropped while a command runs");
  endtask

  // CAP reports the DMA stream; the former XFER_DATA offset is unmapped
  // (reads 0, writes ignored, no bus error).
  task automatic check_cap();
    logic [31:0] d;
    bit rd_err, wr_err;
    ahb_read(A_CAP, d);
    if (d != CAP_EXPECTED) begin $display("FAIL: CAP=0x%08h expected 0x%08h", d, CAP_EXPECTED); errors++; end
    ahb_access(1'b1, A_OLD_XFER_DATA, 32'h1234_5678, d, wr_err);
    ahb_access(1'b0, A_OLD_XFER_DATA, '0, d, rd_err);
    if (rd_err || wr_err || d != 0) begin
      $display("FAIL: unmapped 0x50 err %0d/%0d data 0x%08h", rd_err, wr_err, d); errors++;
    end else $display("PASS CAP.DMA_STREAM; 0x50 unmapped");
  endtask

  // Fill `words` 64-bit words at `addr` with a marker; count words still marked.
  task automatic mark(input int addr, input int words);
    for (int i = 0; i < words; i++) dram[addr/8 + i] = 64'hFEED_0000_0000_0000 | 64'(addr + i);
  endtask
  function automatic int marked(input int addr, input int words);
    int n = 0;
    for (int i = 0; i < words; i++) if (dram[addr/8 + i] === (64'hFEED_0000_0000_0000 | 64'(addr + i))) n++;
    return n;
  endfunction
  // The output slots c0/c1 (all limbs) are marked / still marked.
  task automatic mark_ct();
    mark(ADDR_C0, tb_limbs()*N); mark(ADDR_C1, tb_limbs()*N);
  endtask
  function automatic bit ct_untouched();
    return marked(ADDR_C0, tb_limbs()*N) == tb_limbs()*N && marked(ADDR_C1, tb_limbs()*N) == tb_limbs()*N;
  endfunction

  // DMA stream: the ENCRYPT commit barrier, AES routes, lease conflicts, slot
  // checks, input checks, transport errors and aborts that drain a segment in
  // flight. Ends with KEY_VALID = 0.
  bit saw_abort_drain = 0;
  always @(posedge clk) if (dut.abort_wait && dut.br_active) saw_abort_drain = 1;
  task automatic dma_stream_tests();
    logic [31:0] d;
    logic [63:0] saved;
    bit          saw_lease, fw_go_landed, tag_ok;
    int          guard, diff, base;
    int          limbs = tb_limbs();
    longint      reco [];
    reco = new[N];
    $display("== DMA stream: commit barrier, AES routes, lease, checks, errors, aborts ==");
    rekey("KEYGEN (DMA stream tests)");
    cfg(limbs, 12'(rns_scale));
    enc_slots();
    run_cmd(FHE_ENCRYPT, "ENCRYPT (DMA stream)");
    expect_dma_released("ENCRYPT");

    // (1) Commit barrier: an early INPUT_COMMIT is ignored; in COMMIT_WAIT the
    //     walker waits before its first arithmetic pass (ENCRYPT program word
    //     1, the FFT EXE) and writes nothing; the commit releases it, and the
    //     result decrypts correctly.
    mark_ct();
    issue_cmd(FHE_ENCRYPT, base);
    ahb_write(A_CTRL, CTRL_INPUT_COMMIT);
    wait_notif(base, "ENCRYPT to COMMIT_WAIT");
    repeat (500) @(negedge clk);
    ahb_read(A_STATUS, d);
    if (!d[ST_COMMIT_WAIT] || d[ST_VALID] || !d[ST_DMA_LEASED] || dut.br_active || dut.walker.pc != 8'd17 ||
        !ct_untouched()) begin
      $display("FAIL: commit barrier (STATUS 0x%08h, active %0d, pc %0d, ciphertext untouched %0d)", d,
               dut.br_active, dut.walker.pc, ct_untouched()); errors++;
    end else $display("PASS COMMIT_WAIT stops the walker before its first arithmetic pass; early INPUT_COMMIT ignored");
    commit_and_wait("ENCRYPT after INPUT_COMMIT", tag_ok);
    ahb_read(A_STATUS, d);
    if (!tag_ok || !d[ST_VALID] || d[ST_ERROR] || d[ST_COMMIT_WAIT]) begin
      $display("FAIL: ENCRYPT after commit: tag ok %0d, STATUS 0x%08h", tag_ok, d); errors++;
    end
    cfg(limbs, 12'(i2f_val));
    dec_slots();
    run_cmd(FHE_DECRYPT, "DECRYPT (AES-GCM egress)");
    capture_slots(reco, ADDR_OUT);
    check_fft(reco, g_input, N, "AES-GCM ingress/egress round trip (recovered vs input)", 1.0e-3);

    // (2) A forged message: the tag check fails, firmware zeroizes in
    //     COMMIT_WAIT, nothing is written and the lease is released.
    cfg(limbs, 12'(rns_scale));
    enc_slots();
    mark_ct();
    issue_cmd(FHE_ENCRYPT, base, 7);
    wait_notif(base, "forged ENCRYPT to COMMIT_WAIT");
    commit_and_wait("forged ENCRYPT", tag_ok);
    ahb_read(A_STATUS, d);
    if (tag_ok || d[7:4] != FHE_EC_ABORTED || d[ST_DMA_LEASED] || !ct_untouched()) begin
      $display("FAIL: forged message (tag ok %0d, STATUS 0x%08h)", tag_ok, d); errors++;
    end else $display("PASS forged message: tag mismatch, ZEROIZE in COMMIT_WAIT, nothing written");
    expect_dma_released("forged ENCRYPT");
    rekey("KEYGEN (after the forged message)");

    // (3) A non-finite message word taints ENCRYPT (cause 8), reported only
    //     after the commit; nothing is written.
    cfg(limbs, 12'(rns_scale));
    enc_slots();
    mark_ct();
    saved = dram[ADDR_P/8 + 3];
    dram[ADDR_P/8 + 3] = 64'h7FF8_0000_0000_0001;   // NaN
    run_cmd(FHE_ENCRYPT, "ENCRYPT with a NaN message word", FHE_EC_BAD_WORD);
    dram[ADDR_P/8 + 3] = saved;
    if (!ct_untouched()) begin
      $display("FAIL: tainted ENCRYPT wrote output"); errors++;
    end else $display("PASS tainted ENCRYPT writes nothing");
    expect_dma_released("tainted ENCRYPT");

    // (4) A firmware DMA transfer in progress refuses the command (cause 6);
    //     the firmware copy completes intact.
    for (int i = 0; i < 8192; i++) dram[SCRATCH/8 + i] = {32'(i), 32'hA5A5_0000 | 32'(i)};
    dma_fw_copy_start(SCRATCH, COPY_DST, 64 * 1024);
    expect_reject(FHE_ENCRYPT, FHE_EC_DMA_BUSY, "ENCRYPT while a firmware DMA copy runs");
    guard = 0;
    do begin dma_fw_read(`AXI_DMA_REG_STATUS0, d); guard++; end while ((d & `AXI_DMA_REG_STATUS0_BUSY_MASK) && guard < 100000);
    diff = 0;
    for (int i = 0; i < 8192; i++) if (dram[COPY_DST/8 + i] !== dram[SCRATCH/8 + i]) diff++;
    if (d[0] || diff != 0) begin $display("FAIL: firmware DMA copy (busy=%0d, %0d bad words)", d[0], diff); errors++; end
    else $display("PASS firmware DMA copy completed alongside the refused command");

    // (5) Slot addresses: 16-byte alignment and the DMA address range (cause 9).
    set_slot(2, 64'(ADDR_C0 + 8));
    expect_reject(FHE_ENCRYPT, FHE_EC_BAD_ADDR, "ENCRYPT with a misaligned output slot");
    enc_slots();
    set_slot(3, (64'd1 << DMA_AW) - 64'(N * 8));
    if (limbs == 2) expect_reject(FHE_ENCRYPT, FHE_EC_BAD_ADDR, "ENCRYPT whose c1 slot runs past the DMA range");
    enc_slots();

    // (6) Firmware DMA register writes during the lease are dropped.
    for (int i = 0; i < 512; i++) dram[MARK_DST/8 + i] = 64'hDEAD_0000_0000_0000 | 64'(i);
    issue_cmd(FHE_ENCRYPT, base);
    wait (dut.br_lease);
    saw_lease = dut.hwif_in.FHE_STATUS.DMA_LEASED.next;
    dma_fw_copy_start(SCRATCH, MARK_DST, 4096);
    fw_go_landed = i_dma.i_axi_dma_ctrl.hwif_out_reg.ctrl.go.value;
    finish_cmd(FHE_ENCRYPT, base, "ENCRYPT (firmware DMA writes during the lease)");
    diff = 0;
    for (int i = 0; i < 512; i++) if (dram[MARK_DST/8 + i] !== (64'hDEAD_0000_0000_0000 | 64'(i))) diff++;
    dma_fw_read(`AXI_DMA_REG_STATUS0, d);
    if (!saw_lease || fw_go_landed || diff != 0 || d[0]) begin
      $display("FAIL: lease leaked a firmware transfer (leased=%0d go=%0d diff=%0d busy=%0d)",
               saw_lease, fw_go_landed, diff, d[0]); errors++;
    end else $display("PASS STATUS.DMA_LEASED during the command; firmware DMA writes dropped");
    expect_dma_released("ENCRYPT under lease");

    // (7) An inbound residue not below its prime taints the command (cause 8);
    //     its AES output segment then writes nothing.
    cfg(limbs, 12'(i2f_val));
    dec_slots();
    mark(ADDR_OUT, N);
    saved = dram[ADDR_C0/8 + 5];
    dram[ADDR_C0/8 + 5] = fhe_q(0);
    run_cmd(FHE_DECRYPT, "DECRYPT with c0[5] = q0", FHE_EC_BAD_WORD);
    dram[ADDR_C0/8 + 5] = saved;
    if (marked(ADDR_OUT, N) != N) begin $display("FAIL: tainted DECRYPT wrote output"); errors++; end
    else $display("PASS tainted DECRYPT writes nothing");
    expect_dma_released("tainted DECRYPT");

    // (8) An AXI read error fails the command (cause 10); the DMA is flushed
    //     and the next command runs normally.
    mem_rd_err = 1'b1;
    run_cmd(FHE_DECRYPT, "DECRYPT with AXI read errors", FHE_EC_TRANSPORT);
    mem_rd_err = 1'b0;
    expect_dma_released("DECRYPT transport error");
    run_cmd(FHE_DECRYPT, "DECRYPT after a transport error");
    capture_slots(reco, ADDR_OUT);
    check_fft(reco, g_input, N, "DECRYPT after transport error (recovered vs input)", 1.0e-3);
    // A command without segments must not inherit a failure: KEYGEN right
    // after one (same seed, so the key is unchanged).
    mem_rd_err = 1'b1;
    run_cmd(FHE_DECRYPT, "DECRYPT with AXI read errors, again", FHE_EC_TRANSPORT);
    mem_rd_err = 1'b0;
    rekey("KEYGEN after a transport error");

    // (9) ZEROIZE in the middle of a DMA output segment: the segment drains,
    //     then the command completes as aborted and the lease is released.
    cfg(limbs, 12'(rns_scale));
    enc_slots();
    issue_cmd(FHE_ENCRYPT, base);
    wait_notif(base, "ENCRYPT to COMMIT_WAIT");
    commit_input(tag_ok);
    guard = 0;
    while (!(dut.br_active && dut.stream_status[1] && dut.stream_left < N/2) && guard < 1000000) begin
      @(negedge clk); guard++;
    end
    ahb_write(A_CTRL, CTRL_ZEROIZE);
    wait_status(ST_VALID, "ZEROIZE mid DMA segment");
    ahb_read(A_STATUS, d);
    if (d[ST_READY] && d[ST_ERROR] && d[7:4] == FHE_EC_ABORTED && !d[ST_DMA_LEASED] && dma_resp.idle && saw_abort_drain)
      $display("PASS ZEROIZE mid DMA segment drains, then reports an aborted completion");
    else begin $display("FAIL: ZEROIZE mid DMA segment left STATUS=0x%08h", d); errors++; end
    expect_dma_released("abort");
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
    cfg(2, 12'(rns_scale));
    for (int feature_idx=0; feature_idx<197; feature_idx++) begin
      $readmemh($sformatf("%s/input_%03d.mem", directory, feature_idx), slots);
      for (int i=0;i<N;i++) dram[ADDR_P/8+i] = slots[i];
      enc_slots();
      run_cmd(FHE_ENCRYPT, $sformatf("MNIST ingress %0d", feature_idx));
      for (int k=0;k<10;k++) begin
        weight = int'(weights[k*197+feature_idx]);
        for (int component=0;component<2;component++)
          for (int li=0;li<2;li++) begin
            q = fhe_q(4'(li));
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
      cfg(2, 12'(i2f_val));
      dec_slots();
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
    cfg(2, 12'(rns_scale));
  endtask


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
      bit refresh_aborted = 0, abort_acknowledged = 0;
      int abort_polls = 0;
      forever begin
        count = $fscanf(32'h80000000, "%d %h %h", op, addr, value);
        if (count != 3) $finish;
        else begin
          // Cancel once, mid-transfer, at a firmware poll. Use a real CSR write
          // so the regression covers actual ZEROIZE semantics.
          if ($test$plusargs("RPC_ZEROIZE_REFRESH") && !refresh_aborted &&
              op == 0 && addr == A_STATUS && dut.cmd_q == FHE_REFRESH && dut.br_active) begin
            ahb_write(A_CTRL, 32'h8);
            refresh_aborted = 1;
            $display("FHE_FAULT injected ZEROIZE during refresh");
          end
          if (refresh_aborted && !abort_acknowledged) begin
            // Firmware reports the abort (ERR_CAUSE 11) from the completion,
            // after the segment in flight drains.
            if (op == 0 && addr == A_STATUS) begin
              abort_polls++;
              if (abort_polls > 1000)
                $fatal(1, "firmware kept polling the aborted refresh");
            end
          end
          // Reply "RPC <read data> <1 if AHB ERROR>"; the emulator raises a
          // load/store access fault for an ERROR response. Address space (see
          // fhe_rtl.rs): FHE window at its offset; the AES window at
          // 0x1_0000 + offset and the memory at its DRAM address
          // (0x8000_0000 and up, aliased onto `dram`). Memory accesses are the
          // host's buffer loads and reads and take no time.
          err = 0;
          if (addr >= 32'h8000_0000) begin
            if (op == 1) begin
              if (addr[2]) dram[addr[MEM_AW-1:3]][63:32] = value;
              else         dram[addr[MEM_AW-1:3]][31:0]  = value;
            end
            rdata = addr[2] ? dram[addr[MEM_AW-1:3]][63:32] : dram[addr[MEM_AW-1:3]][31:0];
          end else if (addr[31:16] == 16'h1) begin
            aes_access(op == 1, {16'h0, addr[15:0]}, value, rdata);
          end else begin
            ahb_access(op == 1, addr, value, rdata, err);
          end
          if (addr < 32'h8000_0000) repeat (32) @(negedge clk);
          if (refresh_aborted && !abort_acknowledged && op == 0 && addr == A_STATUS &&
              rdata[ST_VALID] && rdata[7:4] == 4'd11) begin
            abort_acknowledged = 1;
            $display("PASS firmware observed the aborted refresh");
          end
          $display("RPC %08x %0d", rdata, err);
          $fflush();
        end
      end
    end

    load_crom();
    check_crom_window();
    check_cap();

    // Pause the parent clock while the lifted SRAMs keep receiving base-clock
    // edges: no engine step reaches them and their responses hold.
    for (int pause = 0; pause < 3; pause++) begin
      logic [63:0] held_response;
      repeat (pause + 1) @(negedge clk);
      parent_manual_enable = 0;
      @(negedge clk);
      held_response = aloha_mem.ntt_msg0_doutb;
      repeat (9) begin
        @(negedge clk);
        assert (!aloha_mem.eng_step) else $fatal(1, "engine step escaped stopped parent clock");
        assert (aloha_mem.ntt_msg0_doutb === held_response)
          else $fatal(1, "memory response advanced while parent clock stopped");
      end
      parent_manual_enable = 1;
      repeat (4) @(negedge clk);
    end
    $display("PASS idle parent-clock pause/resume");

    $display("== fhe_top register map v2 round trip, N=%0d ==", N);

    // plaintext -> firmware memory (ENCRYPT slot 0 source)
    $readmemh({tvdir, "/input.txt"}, g_input);
    for (int i = 0; i < N; i++) dram[(ADDR_P/8) + i] = g_input[i];

    rns_scale = RT_SCALE - 52 - 1023 - LOGN; if (rns_scale < 0) rns_scale += 4096;
    i2f_val   = -RT_SCALE;

    begin
      logic [31:0] d;
      ahb_read(A_CAP, d);
      if (d != CAP_EXPECTED) begin $display("FAIL: CAP=0x%08h expected 0x%08h", d, CAP_EXPECTED); errors++; end
      ahb_read(A_STATUS, d);
      if (!d[ST_READY] || d[ST_KEY_VALID]) begin $display("FAIL: reset STATUS=0x%08h", d); errors++; end
    end

    // ---- firmware: KeyVault seed, then KEYGEN ----
    rekey("KEYGEN");
    dump_state(1);
    check_baseline(1);
    begin
      logic [31:0] d;
      ahb_read(A_STATUS, d);
      if (!d[ST_KEY_VALID]) begin $display("FAIL: KEY_VALID not set after KEYGEN"); errors++; end
      ahb_read(A_KV_STATUS, d);
      if (d[1]) begin $display("FAIL: seed still valid after KEYGEN consumed it"); errors++; end
      if (dut.kv_seed !== '0) begin $display("FAIL: seed copy not wiped after KEYGEN"); errors++; end
    end

    // KEYGEN always fills every installed limb.
    for (int limb=0; limb < FHE_L; limb++) begin
      assert (key_writes[limb] == N)
        else $fatal(1, "key limb %0d: expected %0d writes, got %0d", limb, N, key_writes[limb]);
    end

    // ---- ENCRYPT: msg <- slot 0, c0 -> slot 2, c1 -> slot 3 ----
    cfg(tb_limbs(), 12'(rns_scale));
    enc_slots();
    begin
      string golden;
      if ($value$plusargs("GOLDEN_DIR=%s", golden) || $test$plusargs("STATE_DUMP")) begin
        // Replay v1's per-pass seeds for one ENCRYPT, check the pre-reuse
        // ciphertext golden, then re-run KEYGEN so the key's own stream restarts.
        replay_v1_seeds(1);
        run_cmd(FHE_ENCRYPT, "ENCRYPT (testbench v1 seed replay)");
        replay_v1_seeds(0);
        dump_state(0);
        rekey("KEYGEN (restart stream after replay)");
        cfg(tb_limbs(), 12'(rns_scale));
      end
    end
    run_cmd(FHE_ENCRYPT, "ENCRYPT");
    for (int i = 0; i < N; i++) first_a[i] = dram[ADDR_C1/8 + i];
    for (int limb=0; limb < tb_limbs(); limb++) begin
      assert (key_reads[limb] >= N)
        else $fatal(1, "key limb %0d: expected %0d reads, got %0d", limb, N, key_reads[limb]);
    end

    // ---- DECRYPT: c0 <- slot 0, c1 <- slot 1, slots -> slot 2 ----
    cfg(tb_limbs(), 12'(i2f_val));
    dec_slots();
    begin
      int base;
      issue_cmd(FHE_DECRYPT, base);
      crom_store_while_busy();
      finish_cmd(FHE_DECRYPT, base, "DECRYPT");
    end

    // recovered slots read back from DRAM @ OUT
    begin
      longint reco [];
      reco = new[N];
      capture_slots(reco, ADDR_OUT);
      check_fft(reco, g_input, N, "fhe_top round-trip (recovered vs input)", 1.0e-3);
    end

    // Production build (no RECOVER): RECOVER is illegal; the level sweep checks
    // ENCRYPT and REFRESH by round trip only. The rest of this bench uses RECOVER.
    if (!FHE_RECOVER_EN) begin
      expect_reject(FHE_RECOVER, FHE_EC_BAD_OPCODE, "RECOVER in a production build");
      finish_run();
    end

    // Interoperate with the stored-FFT reference, not just an OTF round trip.
    // (Generated twiddles round differently, so the ciphertext itself is not
    // bit-exact against that reference.)
    begin
      string dir;
      logic [63:0] reference [0:4*N-1], saved0 [0:2*N-1], saved1 [0:2*N-1];
      longint reco[];
      if ($value$plusargs("GOLDEN_DIR=%s",dir)) begin
        $readmemh({dir,"/ciphertext.hex"},reference);
        for(int i=0;i<2*N;i++) begin
          saved0[i]=dram[ADDR_C0/8+i]; saved1[i]=dram[ADDR_C1/8+i];
          dram[ADDR_C0/8+i]=reference[2*i]; dram[ADDR_C1/8+i]=reference[2*i+1];
        end
        run_cmd(FHE_DECRYPT,"OTF decode stored-FFT golden ciphertext");
        reco=new[N]; capture_slots(reco,ADDR_OUT);
        check_fft(reco,g_input,N,"OTF / stored-table ciphertext interoperability",1.0e-3);
        for(int i=0;i<2*N;i++) begin
          dram[ADDR_C0/8+i]=saved0[i]; dram[ADDR_C1/8+i]=saved1[i];
        end
      end
    end

    // +QUICK (large N): skip from here to the level sweep. An early exit, not
    // an enclosing if: Verilator emits one block as one C++ function, too large
    // to compile.
    if ($test$plusargs("QUICK")) finish_run();
    // Coefficient recovery exercises both key/modulus limbs without decoding.
    // First use the real encrypted input, then an independent constant-polynomial
    // vector whose NTT is constant in every lane and whose c1 is zero.
    begin
      logic [63:0] saved_c0 [0:2*N-1], saved_c1 [0:2*N-1];
      logic [63:0] q [0:1];
      logic signed [63:0] centered0, centered1;
      logic [63:0] expected;
      int limbs;
      string recovery_dir;
      logic [63:0] reference_ntt [0:2*N-1], reference_coeff [0:2*N-1];
      limbs = tb_limbs();
      q[0] = fhe_q(0);
      q[1] = fhe_q(1);
      for (int i=0;i<limbs*N;i++) begin
        saved_c0[i] = dram[ADDR_C0/8+i];
        saved_c1[i] = dram[ADDR_C1/8+i];
      end
      cfg(limbs, 12'(rns_scale));
      run_cmd(FHE_RECOVER, "RECOVER encrypted coefficients");
      for (int i=0;i<N;i++) begin
        assert (dram[ADDR_OUT/8+i] < q[0]) else $fatal(1,"noncanonical recovery limb 0");
        if (limbs == 2) begin
          assert (dram[ADDR_OUT/8+N+i] < q[1]) else $fatal(1,"noncanonical recovery limb 1");
          centered0 = centred(0, dram[ADDR_OUT/8+i]);
          centered1 = centred(1, dram[ADDR_OUT/8+N+i]);
          assert (centered0 == centered1) else $fatal(1,"recovery limb disagreement at %0d: %0d vs %0d",i,centered0,centered1);
        end
      end
      for (int sign_case=0;sign_case<2;sign_case++) begin
        for (int li=0;li<limbs;li++) begin
          // Distinct residues: exercise basis recovery beyond q0's centered range.
          expected = sign_case ? q[li] - ((q[0]+123) % q[li]) : (q[0]+123) % q[li];
          for (int i=0;i<N;i++) begin
            dram[ADDR_C0/8+li*N+i] = expected;
            dram[ADDR_C1/8+li*N+i] = 0;
          end
        end
        run_cmd(FHE_RECOVER, "RECOVER known constant polynomial");
        for (int li=0;li<limbs;li++) begin
          expected = sign_case ? q[li] - ((q[0]+123) % q[li]) : (q[0]+123) % q[li];
          for (int i=0;i<N;i++)
            assert (dram[ADDR_OUT/8+li*N+i] == (i == 0 ? expected : 0))
              else $fatal(1,"coefficient recovery mismatch limb=%0d index=%0d got=%h expected=%h",li,i,dram[ADDR_OUT/8+li*N+i],i == 0 ? expected : 0);
        end
      end
      if (N == 256 && $value$plusargs("RECOVERY_DIR=%s", recovery_dir)) begin
        $readmemh({recovery_dir,"/recovery_ntt.hex"},reference_ntt);
        $readmemh({recovery_dir,"/recovery_coeff.hex"},reference_coeff);
        for (int i=0;i<limbs*N;i++) begin
          dram[ADDR_C0/8+i] = reference_ntt[i];
          dram[ADDR_C1/8+i] = 0;
        end
        run_cmd(FHE_RECOVER,"RECOVER dense direct-evaluation reference");
        for (int i=0;i<limbs*N;i++)
          assert (dram[ADDR_OUT/8+i] == reference_coeff[i])
            else $fatal(1,"dense recovery mismatch index=%0d got=%h expected=%h",i,dram[ADDR_OUT/8+i],reference_coeff[i]);
        $display("PASS dense coefficient recovery against independent polynomial evaluation");
      end
      for (int i=0;i<limbs*N;i++) begin
        dram[ADDR_C0/8+i] = saved_c0[i];
        dram[ADDR_C1/8+i] = saved_c1[i];
      end
      for (int command_case=0;command_case<2;command_case++)
      for (int invalid=0;invalid<2;invalid++) begin
        logic [31:0] status;
        int guard;
        cfg(invalid == 0 ? 0 : FHE_L+1, 12'(rns_scale));
        ahb_write(A_CTRL, 32'(command_case == 0 ? FHE_RECOVER : FHE_REFRESH));
        guard=0;
        do begin ahb_read(A_STATUS,status); guard++; end while (!(status[ST_READY] && status[ST_VALID]) && guard<1000);
        assert (status[ST_READY] && status[ST_ERROR] && status[7:4] == FHE_EC_BAD_L) else $fatal(1,"invalid recovery limb count accepted");
      end
      cfg(limbs, 12'(rns_scale));
      // Rejection must leave the controller usable without destroying the key.
      run_cmd(FHE_RECOVER, "RECOVER after invalid count");
      $display("PASS coefficient recovery: encrypted input and signed constant polynomials, %0d limbs, no floating decode",limbs);
    end

    // Level refresh: q0 only in, both limbs out. Verify signed coefficients
    // against a pre-refresh recovery, allowing only the fresh CBD error.
    begin
      logic [63:0] original0 [0:2*N-1], original1 [0:2*N-1];
      logic [63:0] previous_a [0:2*N-1];
      longint signed before_coeff [0:N-1];
      longint unsigned q [0:1];
      longint signed got, delta;
      int limbs, changed;
      limbs = tb_limbs();
      q[0]=fhe_q(0); q[1]=fhe_q(1);
      for (int i=0;i<limbs*N;i++) begin
        original0[i]=dram[ADDR_C0/8+i]; original1[i]=dram[ADDR_C1/8+i];
      end
      // Real ciphertext, then known positive/negative/center-boundary constants.
      for (int trial=0;trial<6;trial++) begin
        if (trial>=2) begin
          longint unsigned c;
          case (trial)
            2: c=0;
            3: c=q[0]-3;
            4: c=q[0]/2;
            default: c=q[0]/2+1;
          endcase
          for (int i=0;i<N;i++) begin
            dram[ADDR_C0/8+i]=c; dram[ADDR_C1/8+i]=0;
          end
        end
        set_slot(2,64'(ADDR_OUT));
        cfg(1, 12'(rns_scale));
        run_cmd(FHE_RECOVER,"pre-refresh single-limb recovery");
        for (int i=0;i<N;i++)
          before_coeff[i] = centred(0, dram[ADDR_OUT/8+i]);
        cfg(limbs, 12'(rns_scale));
        set_slot(2,64'(ADDR_C0));
        set_slot(3,64'(ADDR_C1));
        refresh_samples=0; refresh_snapshots=0; refresh_lifts=0;
        run_cmd(FHE_REFRESH,"REFRESH q0 to target chain");
        assert(refresh_samples==N && refresh_snapshots==N && refresh_lifts==limbs*N)
          else $fatal(1,"refresh length mismatch: samples=%0d snapshot=%0d lifts=%0d",refresh_samples,refresh_snapshots,refresh_lifts);
        changed=0;
        for (int i=0;i<limbs*N;i++) begin
          assert(dram[ADDR_C0/8+i]<q[i/N] && dram[ADDR_C1/8+i]<q[i/N])
            else $fatal(1,"noncanonical refresh ciphertext");
          if(trial==1 && previous_a[i]!=dram[ADDR_C1/8+i]) changed++;
          previous_a[i]=dram[ADDR_C1/8+i];
        end
        if(trial==1) assert(changed>0) else $fatal(1,"refresh reused uniform randomness");
        set_slot(2,64'(ADDR_OUT));
        run_cmd(FHE_RECOVER,"recover refreshed coefficients");
        for (int i=0;i<N;i++) begin
          longint signed first_delta;
          for (int li=0;li<limbs;li++) begin
            got = dram[ADDR_OUT/8+li*N+i]>q[li]/2 ? dram[ADDR_OUT/8+li*N+i]-q[li] : dram[ADDR_OUT/8+li*N+i];
            delta=got-before_coeff[i];
            // Centered q0 boundary can wrap after adding the fresh error.
            if(delta>$signed(q[li]/2)) delta-=$signed(q[li]);
            if(delta< -$signed(q[li]/2)) delta+=$signed(q[li]);
            assert(delta==refresh_noise[i]) else $fatal(1,"refresh coefficient mismatch trial=%0d limb=%0d i=%0d before=%0d got=%0d delta=%0d",trial,li,i,before_coeff[i],got,delta);
            if(li==0) first_delta=delta;
            else assert(delta==first_delta) else $fatal(1,"different refresh noise across limbs");
          end
        end
      end
      for (int i=0;i<limbs*N;i++) begin
        dram[ADDR_C0/8+i]=original0[i]; dram[ADDR_C1/8+i]=original1[i];
      end
      $display("PASS level refresh: real ciphertext, repeated refresh, signed center boundaries, common noise, no FFT");
    end

    // ---- Single-seed stream and command preconditions ----
    begin
      logic [31:0] d;
      logic [7:0]  kv_err;
      int          diff, guard, limbs, base;
      longint      reco [];
      reco  = new[N];
      limbs = tb_limbs();
      $display("== single-seed stream and command preconditions ==");
      save_key();

      // (1) A later ENCRYPT continues the key's stream: fresh a, never repeated.
      cfg(limbs, 12'(rns_scale));
      enc_slots();
      run_cmd(FHE_ENCRYPT, "ENCRYPT (stream continues)");
      diff = 0;
      for (int i = 0; i < N; i++) if (dram[ADDR_C1/8 + i] !== first_a[i]) diff++;
      if (diff == 0) begin $display("FAIL: second ENCRYPT reused a"); errors++; end
      else $display("PASS stream continues: c1 differs in %0d/%0d coefficients", diff, N);

      // (2) Preconditions, each refused without running a pass.
      expect_reject(FHE_KEYGEN, FHE_EC_NO_SEED, "KEYGEN without a fresh seed read");
      expect_reject(3'b011, FHE_EC_BAD_OPCODE, "opcode 011 (former REENC)");
      expect_reject(3'b111, FHE_EC_BAD_OPCODE, "opcode 111");
      cfg(limbs, 12'(rns_scale), LOGN + 1);
      expect_reject(FHE_ENCRYPT, FHE_EC_BAD_LOGN, "ENCRYPT with LOGN mismatch");
      cfg(limbs, 12'(rns_scale));
      kv_deny = 1;
      kv_seed_read(KV_ENTRY, kv_err);
      if (kv_err != 8'h01) begin $display("FAIL: denied KeyVault read reported error %0d", kv_err); errors++; end
      expect_reject(FHE_KEYGEN, FHE_EC_KV_READ, "KEYGEN after a refused KeyVault read");
      kv_deny = 0;
      ahb_read(A_STATUS, d);
      if (!d[ST_KEY_VALID]) begin $display("FAIL: refused KEYGEN destroyed KEY_VALID"); errors++; end

      // (3) The same seed reproduces the same key and the same stream position.
      load_seed(SEED_A);
      run_cmd(FHE_KEYGEN, "KEYGEN (same seed)");
      diff = key_diff();
      if (diff != 0) begin $display("FAIL: same seed gave a different key (%0d words)", diff); errors++; end
      run_cmd(FHE_ENCRYPT, "ENCRYPT after re-KEYGEN");
      diff = 0;
      for (int i = 0; i < N; i++) if (dram[ADDR_C1/8 + i] !== first_a[i]) diff++;
      if (diff != 0) begin $display("FAIL: same seed did not reproduce a (%0d diffs)", diff); errors++; end
      else $display("PASS same KeyVault seed reproduces the key and the first a");

      // (4) A different 160-bit seed gives a different key that still round-trips.
      load_seed(SEED_B);
      run_cmd(FHE_KEYGEN, "KEYGEN (seed B, nonzero IV)");
      diff = key_diff();
      if (diff == 0) begin $display("FAIL: seed B produced the seed-A key"); errors++; end
      run_cmd(FHE_ENCRYPT, "ENCRYPT (seed B)");
      cfg(limbs, 12'(i2f_val));
      dec_slots();
      run_cmd(FHE_DECRYPT, "DECRYPT (seed B)");
      capture_slots(reco, ADDR_OUT);
      check_fft(reco, g_input, N, "seed-B round-trip (recovered vs input)", 1.0e-3);

      // (5) ZEROIZE while idle clears KEY_VALID; a key-dependent command is refused.
      ahb_write(A_CTRL, CTRL_ZEROIZE);
      ahb_read(A_STATUS, d);
      if (d[ST_KEY_VALID] || d[ST_VALID]) begin $display("FAIL: idle ZEROIZE left STATUS=0x%08h", d); errors++; end
      cfg(limbs, 12'(i2f_val));
      expect_reject(FHE_DECRYPT, FHE_EC_NO_KEY, "DECRYPT after ZEROIZE (no key)");

      // (6) ZEROIZE during a command completes it as aborted (cause 11).
      load_seed(SEED_B);
      cfg(limbs, 12'(rns_scale));
      run_cmd(FHE_KEYGEN, "KEYGEN before abort");
      // Interrupted halfway through the message segment (AES-GCM decrypt with
      // the DMA stream), which then drains.
      enc_slots();
      issue_cmd(FHE_ENCRYPT, base);
      guard = 0;
      while (!(dut.br_active && !dut.stream_status[1] && dut.stream_left < N/2) && guard < 100000) begin
        @(negedge clk); guard++;
      end
      ahb_write(A_CTRL, CTRL_ZEROIZE);
      wait_status(ST_VALID, "ZEROIZE mid-ENCRYPT");
      ahb_read(A_STATUS, d);
      if (d[ST_READY] && d[ST_VALID] && d[ST_ERROR] && d[7:4] == FHE_EC_ABORTED && !d[ST_KEY_VALID])
        $display("PASS ZEROIZE mid-ENCRYPT reports an aborted completion and clears KEY_VALID");
      else begin $display("FAIL: ZEROIZE mid-ENCRYPT left STATUS=0x%08h", d); errors++; end
      ahb_read(A_XFER_STATUS, d);
      if (d != 0) begin $display("FAIL: ZEROIZE left XFER_STATUS=0x%08h", d); errors++; end
      gcm_discard();   // abandon the GCM context

      dma_stream_tests();

      // Restore the seed-A key for the level sweep and the optional MNIST run.
      rekey("KEYGEN (restore seed A)");
    end

    finish_run();
  end

  initial begin
    #(64'd800_000_000 * (N > 256 ? N / 256 : 1));
    $display("fhe_top_dma_tb RESULT: FAIL (global timeout)");
    $finish;
  end

endmodule
