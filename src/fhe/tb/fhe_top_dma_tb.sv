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
//   The TB plays firmware: it provisions a modeled KeyVault entry, reads the
//   160-bit seed through KV_RD_SEED_CTRL, writes CONFIG and the slot bases,
//   issues commands, and services the firmware-forward stream (XFER_*) against
//   a TB memory array. It checks keygen -> encrypt -> decrypt round trips,
//   coefficient recovery, level refresh, single-seed stream behaviour and the
//   command preconditions.
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

  // Firmware memory model (1 MB of 64-bit words) for the forwarded stream.
  localparam int MEM_AW = 20;
  localparam int DEPTH  = 1 << (MEM_AW - 3);

  // Poly-buffer layout (byte addresses). STRIDE = max(N*8, 2KB).
  localparam int STRIDE = (N*8 > 2048) ? N*8 : 2048;
  localparam int ADDR_P   = 0*STRIDE;  // plaintext
  localparam int ADDR_C0  = 1*STRIDE;  // ciphertext c0
  localparam int ADDR_C1  = (1+FHE_L)*STRIDE;  // ciphertext c1
  localparam int ADDR_OUT = (1+2*FHE_L)*STRIDE;  // recovered slots

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
  localparam logic [AHW-1:0] A_XFER_DATA   = 'h50;
  localparam logic [31:0]    CTRL_ZEROIZE  = 32'h8;
  // STATUS fields.
  localparam int ST_READY = 0, ST_VALID = 1, ST_ERROR = 2, ST_KEY_VALID = 3;
`ifdef FHE_FFT_ON_THE_FLY
  localparam logic [31:0] CAP_EXPECTED = 32'(N) | (32'(FHE_L) << 16) | (32'd1 << 20) | (32'd1 << 25) | (32'd2 << 28);
`else
  localparam logic [31:0] CAP_EXPECTED = 32'(N) | (32'(FHE_L) << 16) | (32'd1 << 25) | (32'd2 << 28);
`endif
  // Aloha limb moduli (profile 0xa108).
  localparam logic [63:0] Q_LIMB [2] = '{(64'd1<<46)-(64'd9<<24)+1, (64'd1<<47)-(64'd1<<24)+1};

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

  fhe_top #(
    .AHB_DATA_WIDTH(DW), .AHB_ADDR_WIDTH(AHW)
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
  );

  fhe_aloha_mem_if aloha_mem();
  fhe_aloha_mem_top #(.PHASED(1), .SRAM_REUSE(1)) u_aloha_mem (.clk_i(clk), .m(aloha_mem.resp));

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
    while (!(dut.cmd_q == FHE_ENCRYPT && dut.w_busy &&
             dut.i_local_stream.active && dut.i_local_stream.direction &&
             !dut.w_wr_push && !dut.i_local_stream.full)) @(negedge clk);
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
    if (rst_b && aloha_mem.phase_write && dut.cmd_q == FHE_REFRESH && dut.w_busy) begin
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
    end else if (aloha_mem.phase_read) begin
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
    logic [63:0] expected [0:2*N*FHE_L-1];
    logic [63:0] actual;
    if($value$plusargs("GOLDEN_DIR=%s",dir)) begin
      assert(N==256 && $test$plusargs("LIMBS2")) else $fatal(1,"golden geometry mismatch");
      $readmemh({dir,keys ? "/key.hex" : "/ciphertext.hex"},expected,0,keys ? N*FHE_L-1 : 2*N*FHE_L-1);
      for(int limb=0;limb<FHE_L;limb++)
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
    ahb_read(A_CAP, d);
    stream_check(d == CAP_EXPECTED, $sformatf("CAP=0x%08h expected 0x%08h", d, CAP_EXPECTED));
    ahb_access(1'b0, A_XFER_DATA, '0, d, err);
    stream_check(err, "idle DATA read accepted");
    ahb_access(1'b1, A_XFER_DATA, 32'h1234_5678, d, err);
    stream_check(err, "idle DATA write accepted");
    ahb_read(A_XFER_STATUS, d);
    stream_check(d == 0, $sformatf("rejected access changed STATUS=0x%08h", d));
    // Keep the next address valid through ERROR completion: no idle bubble
    // between the rejected transfers. Exercise both read and write errors,
    // followed immediately by a legal CAP read to check recovery.
    for (int write_access = 0; write_access < 2; write_access++) begin
      @(negedge clk);
      hsel = 1; htrans = 2'b10; haddr = A_XFER_DATA;
      hwrite = 1'(write_access); hsize = 3'b010; hwdata = 64'h1234_5678;
      @(negedge clk);
      stream_check(hresp && !hreadyout, "first access skipped ERROR wait cycle");
      @(negedge clk);
      stream_check(hresp && hreadyout, "first ERROR did not complete");
      @(negedge clk);
      stream_check(hresp && !hreadyout, "back-to-back access skipped ERROR wait cycle");
      haddr = A_CAP; hwrite = 0;
      @(negedge clk);
      stream_check(hresp && hreadyout, "second ERROR did not complete");
      @(negedge clk);
      stream_check(!hresp && hreadyout, "legal access after ERROR did not complete OKAY");
      stream_check(hrdata[63:32] == CAP_EXPECTED, "CAP read after ERROR returned wrong data");
      hsel = 0; htrans = 0; hwdata = 0;
      @(negedge clk);
      stream_check(!hresp && hreadyout, "spurious ERROR after final access");
    end
    ahb_read(A_XFER_STATUS, d);
    stream_check(d == 0, "back-to-back errors changed stream state");
    // Open an output descriptor without running the walker.
    @(negedge clk);
    force dut.w_desc_valid = 1'b1; force dut.w_desc_wr = 1'b1;
    force dut.w_desc_ptr = 3'd2; force dut.w_desc_limb = 4'd0;
    @(negedge clk);
    release dut.w_desc_valid; release dut.w_desc_wr; release dut.w_desc_ptr; release dut.w_desc_limb;
    fork
      ahb_access(1'b0, A_XFER_DATA, '0, d, err);
      begin
        @(negedge clk); @(posedge clk); #1;   // data phase, first ERROR cycle
        force dut.w_wr_push = 1'b1; force dut.w_wr_data = 64'hfeed_beef_0bad_cafe;
        @(posedge clk); #1;
        release dut.w_wr_push; release dut.w_wr_data;
      end
    join
    stream_check(err, "DATA read completed after its ERROR cycle");
    ahb_read(A_XFER_STATUS, d);
    stream_check(d[3:0] == 4'b1011 && !d[12], $sformatf("race changed STATUS=0x%08h", d));
    ahb_read(A_XFER_DATA, lo); ahb_read(A_XFER_DATA, hi);
    stream_check({hi, lo} == 64'hfeed_beef_0bad_cafe, $sformatf("word=0x%08h%08h", hi, lo));
    ahb_read(A_XFER_LEFT, d);
    stream_check(d == N-1, $sformatf("LEFT=%0d after one word", d));
    ahb_write(A_CTRL, CTRL_ZEROIZE);   // discards the open descriptor
    ahb_read(A_XFER_STATUS, d);
    stream_check(d == 0, $sformatf("ZEROIZE left STATUS=0x%08h", d));
    if (errors == start_errors) $display("PASS local-stream AHB errors, back-to-back errors/recovery, error-cycle race, ZEROIZE");
  endtask

  // Firmware model: private memory <-> AHB stream, no FHE AXI traffic.
  task automatic service_local_stream();
    logic [31:0] status, left, lo, hi;
    int idx;
    ahb_read(A_XFER_STATUS, status);
    if (status[2] || status[3]) begin   // input ready / output valid (both imply active)
      ahb_read(A_XFER_LEFT, left);
      idx = int'(slot_base[status[6:4]]/8) + int'(status[11:8])*N + N-int'(left);
      if (status[1]) begin
        ahb_read(A_XFER_DATA, lo); ahb_read(A_XFER_DATA, hi);
        dram[idx] = {hi,lo};
      end else begin
        ahb_write(A_XFER_DATA, dram[idx][31:0]); ahb_write(A_XFER_DATA, dram[idx][63:32]);
      end
    end
  endtask

  task automatic run_cmd(input fhe_cmd_e c, input string nm);
    int base, guard;
    base = notif_count;
    ahb_write(A_CTRL, {29'd0, c});
    cpu_sleep = 1; // parent must stay awake through the stream and completion delivery
    guard = 0;
    while ((notif_count == base) && (guard < 50_000_000)) begin service_local_stream(); guard++; end
    if (notif_count == base) begin $display("  FAIL: %s never completed (timeout)", nm); errors++; end
    else                          $display("  [fhe] %s done (%0d polling iterations)", nm, guard);
    @(negedge clk);
    cpu_sleep = 0;
    begin
      logic [31:0] st;
      ahb_read(A_STATUS, st);
      if (st[ST_ERROR]) begin
        $display("  FAIL: %s completed with ERROR cause %0d", nm, st[7:4]); errors++;
      end
    end
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
          // Cancel once, at a firmware status read between coefficient pairs.
          // Use a real CSR write so the regression covers actual ZEROIZE
          // semantics, without racing an in-flight STREAM_DATA bus access.
          if ($test$plusargs("RPC_ZEROIZE_REFRESH") && !refresh_aborted &&
              op == 0 && addr == A_XFER_STATUS && dut.cmd_q == FHE_REFRESH &&
              dut.i_local_stream.active && !dut.i_local_stream.direction &&
              dut.i_local_stream.left < N && !dut.i_local_stream.half) begin
            ahb_write(A_CTRL, 32'h8);
            refresh_aborted = 1;
            $display("FHE_FAULT injected ZEROIZE during refresh");
          end
          if (refresh_aborted && !abort_acknowledged) begin
            if (op == 1 && addr == A_CTRL && value == 8) begin
              abort_acknowledged = 1;
              $display("PASS firmware noticed cancelled refresh and cleared controller");
            end else if (op == 0 && addr == A_STATUS) begin
              abort_polls++;
              if (abort_polls > 16)
                $fatal(1, "firmware kept polling idle aborted refresh without completion");
            end
          end
          // Reply "RPC <read data> <1 if AHB ERROR>"; the emulator raises a
          // load/store access fault for an ERROR response.
          ahb_access(op == 1, addr, value, rdata, err);
          repeat (32) @(negedge clk);
          $display("RPC %08x %0d", rdata, err);
          $fflush();
        end
      end
    end

    check_local_stream_bus();

    // Pause the parent clock in each idle phase while lifted SRAMs continue
    // to receive base-clock edges. No repeated requests/response shifts allowed.
    for (int phase = 0; phase < 3; phase++) begin
      logic [63:0] held_response;
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

    $display("== fhe_top register map v2 round trip (firmware-forward stream), N=%0d ==", N);

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
    load_seed(SEED_A);
    cfg(2, 12'(rns_scale));
    run_cmd(FHE_KEYGEN, "KEYGEN");
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
`ifndef FHE_FFT_ON_THE_FLY
        check_baseline(0); // floating recurrence can change rounded ciphertext values
`endif
        load_seed(SEED_A);
        cfg(2, 12'(rns_scale));
        run_cmd(FHE_KEYGEN, "KEYGEN (restart stream after replay)");
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
    run_cmd(FHE_DECRYPT, "DECRYPT");

    // recovered slots read back from DRAM @ OUT
    begin
      longint reco [];
      reco = new[N];
      capture_slots(reco, ADDR_OUT);
      check_fft(reco, g_input, N, "fhe_top round-trip (recovered vs input)", 1.0e-3);
    end

`ifdef FHE_FFT_ON_THE_FLY
    // Interoperate with the stored-FFT reference, not just an OTF round trip.
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
`endif

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
      q[0] = (64'd1 << 46) - (64'd9 << 24) + 1;
      q[1] = (64'd1 << 47) - (64'd1 << 24) + 1;
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
          centered0 = dram[ADDR_OUT/8+i] > q[0]/2 ? dram[ADDR_OUT/8+i]-q[0] : dram[ADDR_OUT/8+i];
          centered1 = dram[ADDR_OUT/8+N+i] > q[1]/2 ? dram[ADDR_OUT/8+N+i]-q[1] : dram[ADDR_OUT/8+N+i];
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
      q[0]=64'd70368593182721; q[1]=64'd140737471578113;
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
          before_coeff[i] = dram[ADDR_OUT/8+i]>q[0]/2 ? dram[ADDR_OUT/8+i]-q[0] : dram[ADDR_OUT/8+i];
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
      int          diff, guard, limbs;
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
      enc_slots();
      ahb_write(A_CTRL, {29'd0, FHE_ENCRYPT});
      guard = 0;
      while (!(dut.i_local_stream.active && dut.i_local_stream.left < N/2) && guard < 100000) begin
        service_local_stream(); guard++;
      end
      ahb_write(A_CTRL, CTRL_ZEROIZE);
      ahb_read(A_STATUS, d);
      if (d[ST_READY] && d[ST_VALID] && d[ST_ERROR] && d[7:4] == FHE_EC_ABORTED && !d[ST_KEY_VALID])
        $display("PASS ZEROIZE mid-ENCRYPT reports an aborted completion and clears KEY_VALID");
      else begin $display("FAIL: ZEROIZE mid-ENCRYPT left STATUS=0x%08h", d); errors++; end
      ahb_read(A_XFER_STATUS, d);
      if (d != 0) begin $display("FAIL: ZEROIZE left XFER_STATUS=0x%08h", d); errors++; end

      // Restore the seed-A key for the optional MNIST run.
      load_seed(SEED_A);
      cfg(2, 12'(rns_scale));
      run_cmd(FHE_KEYGEN, "KEYGEN (restore seed A)");
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
