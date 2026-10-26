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
//   Top wrapper for the CKKS (Aloha-HE) accelerator: an AHB-Lite responder with
//   the register map v2 block (fhe_reg, generated from fhe_reg.rdl), the
//   microsequencer ("walker"), the Aloha ComputeCore and its transports.
//   Specification: docs/fhe/16-register-map-v2.md (Chipyard checkout).
//
//   Transport: every segment moves through Caliptra's axi_dma
//   (fhe_dma_stream_bridge, under a per-command lease), the ENCRYPT message
//   and the DECRYPT slots through AES-GCM, and ENCRYPT computes nothing until
//   firmware commits its input (CTRL.INPUT_COMMIT).
//
//   The datapath is compiled only with FHE_WALKER; otherwise the block ties
//   off its bus and outputs. The former stage-0 stub and the dedicated fhe_dma
//   AXI manager are removed.
//
module fhe_top
  import fhe_params_pkg::*;
#(
  parameter AHB_DATA_WIDTH = 64,
  parameter AHB_ADDR_WIDTH = 32,
  parameter DMA_AW         = 48  // axi_dma address width (slot address checks)
)(
  input  logic clk,
  input  logic clock_live, // parent gate enable, for ungated lifted SRAMs
  input  logic rst_b,
  // AHB-Lite responder slice (from caliptra_top responder_inst[SEL_FHE])
  input  logic [AHB_ADDR_WIDTH-1:0] haddr_i,
  input  logic [AHB_DATA_WIDTH-1:0] hwdata_i,
  input  logic                      hsel_i,
  input  logic                      hwrite_i,
  input  logic                      hready_i,
  input  logic [1:0]                htrans_i,
  input  logic [2:0]                hsize_i,
  output logic                      hresp_o,
  output logic                      hreadyout_o,
  output logic [AHB_DATA_WIDTH-1:0] hrdata_o,
  // Status / interrupts to caliptra_top
  output logic busy_o,
  output logic error_intr,
  output logic notif_intr,
  // Legacy stage-0 bank interface; unused, tied idle.
  fhe_mem_if.req fhe_memory_export
`ifdef FHE_WALKER
  ,
  // KeyVault seed read port (kv_read[2], Adams Bridge's ML-DSA seed client,
  // free when Adams Bridge is compiled out).
  output kv_defines_pkg::kv_read_t    fhe_kv_read,
  input  kv_defines_pkg::kv_rd_resp_t fhe_kv_rd_resp,
  // Aloha ComputeCore storage banks, lifted to real SRAM at the SoC level.
  fhe_aloha_mem_if.req fhe_aloha_mem,
  // Hardware requester port of Caliptra's axi_dma
  output axi_pkg::axi_dma_hw_req_t  fhe_dma_req,
  input  axi_pkg::axi_dma_hw_resp_t fhe_dma_resp
`endif
);

`ifdef FHE_WALKER
  import fhe_reg_pkg::*;

  localparam logic [3:0] MAP_VERSION = 4'd2;
  localparam logic [63:0] VERSION_V2 = 64'h00000000_3030322e; // "2.00"
  // CROM window (docs/fhe/19): word w, lane k at CROM_BASE + 16*w + 4*k.
  localparam int CROM_BASE = 'h4000;

  //----------------------------------------------------------------
  // AHB-Lite slave -> generated register block
  //----------------------------------------------------------------
  logic                      dv, cif_write;
  logic [31:0]               cif_wdata, cif_rdata, reg_rdata;
  logic [AHB_ADDR_WIDTH-1:0] cif_addr;
  // The CROM window takes 0x4000-0x5FFF; the register block never sees it.
  wire crom_window = cif_addr[AHB_ADDR_WIDTH-1:13] == (CROM_BASE >> 13);
  // Registers take 0x00-0x7F; any other offset reads 0 and ignores writes.
  wire reg_window = cif_addr[AHB_ADDR_WIDTH-1:FHE_REG_ADDR_WIDTH] == '0;
  assign cif_rdata = reg_window ? reg_rdata : 32'd0;  // the CROM window is write-only

  fhe_ahb_slv_sif #(
    .AHB_DATA_WIDTH    (AHB_DATA_WIDTH),
    .AHB_ADDR_WIDTH    (AHB_ADDR_WIDTH),
    .CLIENT_DATA_WIDTH (32),
    .CLIENT_ADDR_WIDTH (AHB_ADDR_WIDTH)
  ) ahb_slv_inst (
    .hclk        (clk),
    .hreset_n    (rst_b),
    .haddr_i     (haddr_i),
    .hwdata_i    (hwdata_i),
    .hsel_i      (hsel_i),
    .hwrite_i    (hwrite_i),
    .hready_i    (hready_i),
    .htrans_i    (htrans_i),
    .hsize_i     (hsize_i),
    .hresp_o     (hresp_o),
    .hreadyout_o (hreadyout_o),
    .hrdata_o    (hrdata_o),
    .dv          (dv),
    .hld         (1'b0),
    .err         (1'b0),     // no register access fails on the bus
    .write       (cif_write),
    .wdata       (cif_wdata),
    .addr        (cif_addr),
    .rdata       (cif_rdata)
  );

  fhe_reg__in_t  hwif_in;
  fhe_reg__out_t hwif_out;

  fhe_reg i_fhe_reg (
    .clk                 (clk),
    .rst                 (1'b0),
    .s_cpuif_req         (dv & reg_window),
    .s_cpuif_req_is_wr   (cif_write),
    .s_cpuif_addr        (cif_addr[FHE_REG_ADDR_WIDTH-1:0]),
    .s_cpuif_wr_data     (cif_wdata),
    .s_cpuif_wr_biten    ('1),
    .s_cpuif_req_stall_wr(),
    .s_cpuif_req_stall_rd(),
    .s_cpuif_rd_ack      (),
    .s_cpuif_rd_err      (),
    .s_cpuif_rd_data     (reg_rdata),
    .s_cpuif_wr_ack      (),
    .s_cpuif_wr_err      (),
    .hwif_in             (hwif_in),
    .hwif_out            (hwif_out)
  );

  //----------------------------------------------------------------
  // Command interface
  //----------------------------------------------------------------
  logic        ready, zeroize, cmd_write, cmd_accept, cmd_reject;
  logic        cmd_valid, reject_pending;
  fhe_cmd_e    cmd_q, cmd_in;
  logic [3:0]  reject_cause;
  logic        status_valid, status_error;
  logic [3:0]  status_cause;
  logic        key_valid;
  logic        done, done_error;
  logic        w_busy, w_done, w_error;
  logic        abort_done, abort_wait;
  logic [3:0]  done_cause;
  // DMA stream bridge state
  logic        br_lease, br_word_error, br_xfer_error;

  // CTRL is an external register: decode the write in its request cycle, so a
  // command is accepted in the same cycle as the AHB data phase (v1 timing).
  logic        ctrl_wr;
  logic [31:0] ctrl_wdata;
  assign ctrl_wr    = hwif_out.FHE_CTRL.req & hwif_out.FHE_CTRL.req_is_wr;
  assign ctrl_wdata = hwif_out.FHE_CTRL.wr_data;
  assign hwif_in.FHE_CTRL.wr_ack = hwif_out.FHE_CTRL.req;

  assign zeroize   = ctrl_wr & ctrl_wdata[3];
  assign cmd_in    = fhe_cmd_e'(ctrl_wdata[2:0]);
  assign cmd_write = ctrl_wr & ~ctrl_wdata[3] & ready & (ctrl_wdata[2:0] != 3'b000);
  // CTRL.INPUT_COMMIT (bit 4) releases the ENCRYPT commit barrier.
  logic commit_wait;
  wire  input_commit = ctrl_wr & ctrl_wdata[4] & commit_wait;

  // Engine step: the core, the walker and the working arrays advance together
  // on every clock the arrays accept. An array stalls a step when its write
  // buffer cannot take a write that collides with the step's read
  // (fhe_ilv_bank); the requests are core and walker registers, so the stall
  // settles before the clock-gate latch opens.
  wire core_step = clock_live && rst_b && !zeroize && !fhe_aloha_mem.eng_stall;
  // Low-phase latch is the standard glitch-free clock-gate pattern. The core,
  // including the sampler, runs on core_clk; AHB and the stream stay ungated.
  wire core_clk;
`ifdef TECH_SPECIFIC_ICG
  `USER_ICG fhe_core_icg (.clk(clk), .en(core_step), .clk_cg(core_clk));
`else
  logic core_clock_enable;
  always_latch if (!clk) core_clock_enable <= core_step;
  assign core_clk = clk & core_clock_enable;
`endif
  assign fhe_aloha_mem.eng_step = core_step;

  // VeeR firmware copies its table into the CROM (docs/fhe/19). Lanes 0-2 of a
  // word are staged; the lane-3 store writes the whole word. Stores are taken
  // only while the engine is idle, so a running command never sees CROM change,
  // and stores past the CROM depth are dropped.
  // The write uses the staged lanes in the cycle after the lane-3 store; the
  // next store's data phase cannot change them before that edge.
  logic [95:0] crom_stage;
  logic [31:0] crom_lane3;
  wire [8:0] crom_word = cif_addr[12:4];
  wire crom_store = dv && cif_write && crom_window && ready && (10'(crom_word) < 10'(1 << FHE_CROM_AW));
  wire crom_last  = cif_addr[3:2] == 2'd3;
  always_ff @(posedge clk or negedge rst_b)
    if (!rst_b) fhe_aloha_mem.crom_wea <= 1'b0;
    else        fhe_aloha_mem.crom_wea <= crom_store && crom_last;
  always_ff @(posedge clk)
    if (crom_store) begin
      if (!crom_last) crom_stage[32*cif_addr[3:2] +: 32] <= cif_wdata;
      else begin
        crom_lane3 <= cif_wdata;
        fhe_aloha_mem.crom_wa <= FHE_CROM_AW'(crom_word);
      end
    end
  assign fhe_aloha_mem.crom_wd = {crom_lane3, crom_stage};

  // READY rises only after a completion has latched VALID/ERROR, so firmware
  // sees READY and the completion status together.
  assign busy_o = w_busy | cmd_valid | reject_pending | done | abort_wait | br_lease;
  assign ready  = ~busy_o;

  //----------------------------------------------------------------
  // KeyVault seed: standard kv_read_ctrl_reg / kv_status_reg
  //----------------------------------------------------------------
  localparam int SEED_DWORDS = 5; // 160 bits: Trivium key [79:0], IV [159:80]
  logic [SEED_DWORDS*32-1:0] kv_seed;
  logic kv_start, kv_seed_valid, kv_seed_error, kv_busy;
  logic seed_fresh, seed_wipe;

  assign kv_start  = hwif_out.FHE_KV_RD_SEED_CTRL.read_en.value & ~kv_busy & ready;
  // The seed copy lives only until the KEYGEN that consumes it completes.
  assign seed_wipe = zeroize | (w_done & (cmd_q == FHE_KEYGEN));

  fhe_kv_seed #(.SEED_DWORDS(SEED_DWORDS)) i_fhe_kv_seed (
    .clk        (clk),
    .rst_b      (rst_b),
    .zeroize    (seed_wipe),
    .start      (kv_start),
    .read_entry (hwif_out.FHE_KV_RD_SEED_CTRL.read_entry.value),
    .kv_read    (fhe_kv_read),
    .kv_rd_resp (fhe_kv_rd_resp),
    .seed       (kv_seed),
    .seed_valid (kv_seed_valid),
    .seed_error (kv_seed_error),
    .busy       (kv_busy)
  );

  // A KEYGEN needs a completed read since the last wipe (STATUS.VALID).
  always_ff @(posedge clk or negedge rst_b) begin
    if (!rst_b)                      seed_fresh <= 1'b0;
    else if (seed_wipe || kv_start)  seed_fresh <= 1'b0;
    else if (kv_seed_valid)          seed_fresh <= 1'b1;
  end

  always_comb begin
    hwif_in.FHE_KV_RD_SEED_CTRL.read_en.hwclr         = kv_start | zeroize;
    hwif_in.FHE_KV_RD_SEED_CTRL.read_en.swwe          = ready;
    hwif_in.FHE_KV_RD_SEED_CTRL.read_entry.swwe       = ready;
    hwif_in.FHE_KV_RD_SEED_CTRL.pcr_hash_extend.swwe  = ready;
    hwif_in.FHE_KV_RD_SEED_CTRL.rsvd.swwe             = ready;
    hwif_in.FHE_KV_RD_SEED_STATUS.READY.next = ~kv_busy;
    // Same priority as seed_fresh: a wipe or new read in the completion
    // clock leaves VALID clear (the generated field gives set priority).
    hwif_in.FHE_KV_RD_SEED_STATUS.VALID.hwset = kv_seed_valid & ~(seed_wipe | kv_start);
    hwif_in.FHE_KV_RD_SEED_STATUS.VALID.hwclr = seed_wipe | kv_start;
    hwif_in.FHE_KV_RD_SEED_STATUS.ERROR.next  = kv_seed_error ? 8'h01 : 8'h00;
  end

  //----------------------------------------------------------------
  // Command preconditions
  //----------------------------------------------------------------
  logic [3:0] cfg_l, cfg_logn;
  logic [11:0] cfg_scale;
  assign cfg_l     = hwif_out.FHE_CONFIG.L.value;
  assign cfg_logn  = hwif_out.FHE_CONFIG.LOGN.value;
  assign cfg_scale = hwif_out.FHE_CONFIG.SCALE.value;

  // The slots a command uses must be 16-byte aligned and must not run past the
  // DMA's address space: BASE + limbs*N*8 <= 2^DMA_AW.
  logic [63:0] slot_base [0:3];
  logic        slots_ok, dma_idle;
  function automatic logic slot_ok(input logic [63:0] base, input logic [3:0] limbs);
    logic [DMA_AW:0] slot_end;
    slot_end = (DMA_AW+1)'(base[DMA_AW-1:0]) + (DMA_AW+1)'(limbs) * (DMA_AW+1)'(FHE_N * 8);
    return (base[3:0] == 4'd0) && (base[63:DMA_AW] == '0) && (slot_end <= (DMA_AW+1)'(1) << DMA_AW);
  endfunction
  always_comb begin
    slots_ok = 1'b1;
    for (int s = 0; s < 4; s++) begin
      logic [3:0] limbs;
      limbs = fhe_slot_limbs(cmd_in, 3'(s), cfg_l);
      if (limbs != 0 && !slot_ok(slot_base[s], limbs))
        slots_ok = 1'b0;
    end
  end
  always_comb
    for (int s = 0; s < 4; s++)
      slot_base[s] = {hwif_out.FHE_SLOT[s].BASE_H.ADDR.value, hwif_out.FHE_SLOT[s].BASE_L.ADDR.value};

  logic [3:0] precheck;
  always_comb begin
    precheck = FHE_EC_NONE;
    if (!(cmd_in inside {FHE_ENCRYPT, FHE_KEYGEN, FHE_DECRYPT, FHE_REFRESH} ||
          (FHE_RECOVER_EN && cmd_in == FHE_RECOVER)))
      precheck = FHE_EC_BAD_OPCODE;  // RECOVER only in verification builds
    else if (cfg_logn != 4'(FHE_LOGN))
      precheck = FHE_EC_BAD_LOGN;
    else if (cmd_in == FHE_KEYGEN) begin
      if (!seed_fresh)     precheck = FHE_EC_NO_SEED;
      else if (kv_seed_error) precheck = FHE_EC_KV_READ;
    end else begin
      if (!key_valid) precheck = FHE_EC_NO_KEY;
      else if (cmd_in != FHE_DECRYPT && (cfg_l == 4'd0 || cfg_l > 4'(FHE_L)))
        precheck = FHE_EC_BAD_L;
      else if (!slots_ok)
        precheck = FHE_EC_BAD_ADDR;
      else if (!dma_idle)
        precheck = FHE_EC_DMA_BUSY;
    end
  end
  assign cmd_accept = cmd_write & (precheck == FHE_EC_NONE);
  assign cmd_reject = cmd_write & (precheck != FHE_EC_NONE);

  always_ff @(posedge clk or negedge rst_b) begin
    if (!rst_b) begin
      cmd_q          <= FHE_NONE;
      cmd_valid      <= 1'b0;
      reject_pending <= 1'b0;
      reject_cause   <= FHE_EC_NONE;
    end else if (zeroize) begin
      cmd_q          <= FHE_NONE;
      cmd_valid      <= 1'b0;
      reject_pending <= 1'b0;
      reject_cause   <= FHE_EC_NONE;
    end else begin
      if (cmd_write) cmd_q <= cmd_in;
      // An accepted command is held until the next logical engine edge.
      if (cmd_accept)     cmd_valid <= 1'b1;
      else if (core_step) cmd_valid <= 1'b0;
      // A rejected command completes on the next engine edge, without passes.
      if (cmd_reject) begin
        reject_pending <= 1'b1;
        reject_cause   <= precheck;
      end else if (core_step) reject_pending <= 1'b0;
    end
  end

  wire reject_done = reject_pending & core_step;

  assign done       = w_done | reject_done;
  assign done_error = reject_done | w_error | (w_done & (br_word_error | br_xfer_error));
  always_comb begin
    if (reject_done)                done_cause = reject_cause;
    else if (w_done & br_xfer_error) done_cause = FHE_EC_TRANSPORT;
    else if (w_done & br_word_error) done_cause = FHE_EC_BAD_WORD;
    else                            done_cause = FHE_EC_NONE;
  end

  // A ZEROIZE that interrupts a command reports it as an aborted completion,
  // once the DMA segment in flight (if any) has drained and the lease is back.
  wire abort_now  = zeroize & (w_busy | cmd_valid | reject_pending);
  assign abort_done = ~br_lease & (abort_now | (abort_wait & ~zeroize));

  //----------------------------------------------------------------
  // Completion status and resident-key state
  //----------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_b) begin
    if (!rst_b) begin
      status_valid <= 1'b0;
      status_error <= 1'b0;
      status_cause <= FHE_EC_NONE;
      abort_wait   <= 1'b0;
      key_valid    <= 1'b0;
    end else if (abort_done || zeroize) begin
      status_valid <= abort_done;
      status_error <= abort_done;
      status_cause <= abort_done ? FHE_EC_ABORTED : FHE_EC_NONE;
      abort_wait   <= ~abort_done & (abort_wait | abort_now);
      if (zeroize) key_valid <= 1'b0;
    end else begin
      if (cmd_write) begin
        status_valid <= 1'b0;
        status_error <= 1'b0;
        status_cause <= FHE_EC_NONE;
      end else if (done) begin
        status_valid <= 1'b1;
        status_error <= done_error;
        status_cause <= done_cause;
      end
      if (cmd_accept && cmd_in == FHE_KEYGEN) key_valid <= 1'b0;
      else if (w_done && cmd_q == FHE_KEYGEN) key_valid <= ~w_error;
    end
  end

  // Interrupts: 1-cycle pulses. notif = completion (including rejection and
  // abort) or entering COMMIT_WAIT; error = failed completion.
  logic commit_enter;
  assign notif_intr = done | abort_done | commit_enter;
  assign error_intr = (done & done_error) | abort_done;

  //----------------------------------------------------------------
  // Register block inputs
  //----------------------------------------------------------------
  logic [31:0] stream_status, stream_left;

  always_comb begin
    hwif_in.reset_b   = rst_b;
    hwif_in.fhe_ready = ready;
    hwif_in.FHE_NAME[0].NAME.next       = FHE_CORE_NAME[31:0];
    hwif_in.FHE_NAME[1].NAME.next       = FHE_CORE_NAME[63:32];
    hwif_in.FHE_VERSION[0].VERSION.next = VERSION_V2[31:0];
    hwif_in.FHE_VERSION[1].VERSION.next = VERSION_V2[63:32];

    hwif_in.FHE_STATUS.READY.next       = ready;
    hwif_in.FHE_STATUS.VALID.next       = status_valid;
    hwif_in.FHE_STATUS.ERROR.next       = status_error;
    hwif_in.FHE_STATUS.KEY_VALID.next   = key_valid;
    hwif_in.FHE_STATUS.ERR_CAUSE.next   = status_cause;
    hwif_in.FHE_STATUS.COMMIT_WAIT.next = commit_wait;
    hwif_in.FHE_STATUS.DMA_LEASED.next  = br_lease;
    hwif_in.FHE_STATUS.RSVD.next        = '0;

    hwif_in.FHE_CONFIG.L.hwclr     = zeroize;
    hwif_in.FHE_CONFIG.LOGN.hwclr  = zeroize;
    hwif_in.FHE_CONFIG.SCALE.hwclr = zeroize;

    hwif_in.FHE_CAP.N.next             = 16'(FHE_N);
    hwif_in.FHE_CAP.L.next             = 4'(FHE_L);
    hwif_in.FHE_CAP.FFT_GENERATED.next = 1'b1;  // twiddles are always generated
    hwif_in.FHE_CAP.RSVD0.next         = '0;
    hwif_in.FHE_CAP.DMA_STREAM.next    = 1'b1;
    hwif_in.FHE_CAP.RSVD1.next         = '0;
    hwif_in.FHE_CAP.MAP_VERSION.next   = MAP_VERSION;

    hwif_in.FHE_XFER_STATUS.ACTIVE.next    = stream_status[0];
    hwif_in.FHE_XFER_STATUS.DIR.next       = stream_status[1];
    hwif_in.FHE_XFER_STATUS.RSVD0.next     = '0;
    hwif_in.FHE_XFER_STATUS.SLOT.next      = stream_status[6:4];
    hwif_in.FHE_XFER_STATUS.RSVD1.next     = 1'b0;
    hwif_in.FHE_XFER_STATUS.LIMB.next      = stream_status[11:8];
    hwif_in.FHE_XFER_STATUS.RSVD2.next     = '0;
    hwif_in.FHE_XFER_LEFT.LEFT.next        = stream_left;

    for (int s = 0; s < 4; s++) begin
      hwif_in.FHE_SLOT[s].BASE_L.ADDR.hwclr = zeroize;
      hwif_in.FHE_SLOT[s].BASE_H.ADDR.hwclr = zeroize;
    end
  end

  //----------------------------------------------------------------
  // Walker and core
  //----------------------------------------------------------------
  // Per-modulus R mod q_i, R = 2^72: the one-limb key's ternary map unit.
  // R^2 mod q_i is only for the separate-storage KEYGEN, which this build lacks.
  logic [63:0] RMODQ [0:FHE_L-1];
  for (genvar i = 0; i < FHE_L; i++) begin : g_rmodq
    assign RMODQ[i] = fhe_rmodq(4'(i));
  end

  logic [31:0] w_cl, w_ch, w_dl, w_dh;
  logic [31:0] core_dout_lo, core_dout_hi, core_status;
  logic [39:0] core_cmd;     // walker -> ComputeCore command, held per pass
  // The sampler Trivium is reset only at power-on; its state otherwise
  // persists across passes and commands (one continuous stream per key).
  logic        fhe_prng_rst;
  assign       fhe_prng_rst = ~rst_b;
  logic        w_reseed_en;

  logic [2:0]   w_ext_sel;
  logic [FHE_LOGN:0] w_ext_idx;
  logic [63:0]  w_rd_data, w_wr_data;
  logic         w_wr_push;
  logic         w_desc_valid, w_desc_wr;
  logic [2:0]   w_desc_ptr;
  logic [3:0]   w_desc_limb;
  logic         w_dma_ready, w_rd_valid, w_rd_pop, w_wr_ready;
  logic         k_kg, k_kw;     // walker -> core: this pass's KEYGEN mode and K writes
  logic [53:0]  k_scale;
  logic         exe_hold, exe_held;

  fhe_microseq #(.SRAM_REUSE(1), .LOGN(FHE_LOGN), .N(FHE_N)) walker (
    .step(core_step),
    .k_kg(k_kg), .k_kw(k_kw), .k_scale(k_scale),
    .sk_en(fhe_aloha_mem.sk_en), .sk_we(fhe_aloha_mem.sk_we),
    .sk_addr(fhe_aloha_mem.sk_addr), .sk_wdata(fhe_aloha_mem.sk_wdata),
    .sk_rdata(fhe_aloha_mem.sk_rdata),
    .clk            (clk),
    .rst_b          (rst_b),
    .zeroize        (zeroize),
    .cmd_valid      (cmd_valid),
    .cmd            (cmd_q),
    .scale          (cfg_scale),
    .num_limbs      (cfg_l),
    .r2modq         ('{default: '0}),
    .rmodq          (RMODQ),
    .control_low_word  (w_cl),
    .control_high_word (w_ch),
    .dina_low          (w_dl),
    .dina_high         (w_dh),
    .dout_low          (core_dout_lo),
    .dout_high         (core_dout_hi),
    .status            (core_status),
    .core_cmd          (core_cmd),
    .ext_sel        (w_ext_sel),
    .ext_idx        (w_ext_idx),
    .ext_din        (w_rd_data),
    .ext_dout_we    (w_wr_push),
    .ext_dout       (w_wr_data),
    .dma_desc_valid (w_desc_valid),
    .dma_desc_wr    (w_desc_wr),
    .dma_desc_ptr   (w_desc_ptr),
    .dma_desc_limb  (w_desc_limb),
    .dma_ready      (w_dma_ready),
    .dma_rd_valid   (w_rd_valid),
    .dma_rd_pop     (w_rd_pop),
    .dma_wr_ready   (w_wr_ready),
    .exe_hold       (exe_hold),
    .exe_held       (exe_held),
    .reseed_en      (w_reseed_en),
    .busy           (w_busy),
    .done           (w_done),
    .error          (w_error)
  );

  ComputeCoreWrapper #(
    .SRAM_REUSE                (1),
    .FFT_ON_THE_FLY_GENERATION (1),
    .PROVIDE_DEBUG_IO          (1),
    .LOGN                      (FHE_LOGN),
    .N                         (FHE_N),
    .SCHEME                    (1),
    .SEED_SIDEBAND             (1),
    .EXT_COMMAND               (1)    // the walker loads each pass's command
  ) core (
    .k_kg(k_kg), .k_kw(k_kw), .k_scale(k_scale),
    .clk                (core_clk),
    .reseed_en          (w_reseed_en),
    .prng_rst_i         (fhe_prng_rst),
    .prng_seed          (kv_seed),
    .control_low_word   (w_cl),
    .control_high_word  (w_ch),
    .dina_ext_low_word  (w_dl),
    .dina_ext_high_word (w_dh),
    .dout_ext_low_word  (core_dout_lo),
    .dout_ext_high_word (core_dout_hi),
    .status             (core_status),
    .ext_command        (core_cmd),
    // The core's own DMA-into-BRAM port is unused: the walker moves data over
    // the debug-IO send64/receive64 path.
    .dma_bram_byte_wea  (8'd0),
    .dma_bram_abs_addr  (18'd0),
    .dma_bram_dina      (64'd0),
    .dma_bram_doutb     (),
    .dma_bram_en        (1'b0),
    .m_aloha_mem        (fhe_aloha_mem)
  );

  //----------------------------------------------------------------
  // Transports
  //----------------------------------------------------------------
  // Every segment goes through the DMA bridge.
  logic br_active;   // a segment is open (testbench probe)

  // Input commit barrier (ENCRYPT). The message arrives through AES-GCM
  // decrypt, so the walker stops before its first arithmetic pass. Once it is
  // parked there and the DMA is idle (every input segment done, AES quiet),
  // COMMIT_WAIT rises (with notif) and firmware checks the GCM tag, then
  // writes INPUT_COMMIT, or ZEROIZE to abort. The command waits for the
  // commit even when its input failed a check: the outcome is reported only
  // after the tag check, so it reveals nothing about unauthenticated plaintext.
  logic committed, commit_wait_q;
  assign exe_hold     = fhe_cmd_commits(cmd_q) && !committed;
  assign commit_wait  = exe_held && w_dma_ready;
  assign commit_enter = commit_wait && !commit_wait_q;
  always_ff @(posedge clk or negedge rst_b) begin
    if (!rst_b)                     {committed, commit_wait_q} <= 2'b00;
    else if (zeroize || cmd_accept) {committed, commit_wait_q} <= 2'b00;
    else begin
      commit_wait_q <= commit_wait;
      if (input_commit) committed <= 1'b1;
    end
  end

  // Every command that moves data takes the lease (all but KEYGEN).
  logic cmd_uses_dma;
  always_comb begin
    cmd_uses_dma = 1'b0;
    for (int s = 0; s < 4; s++)
      if (fhe_slot_used(cmd_in, 3'(s))) cmd_uses_dma = 1'b1;
  end
  fhe_dma_stream_bridge #(.N(FHE_N)) i_dma_bridge (
    .clk(clk), .rst_b(rst_b),
    .cmd_start  (cmd_accept),
    .lease_start(cmd_accept & cmd_uses_dma),
    .lease_end  (w_done),
    .abort      (zeroize),
    .lease      (br_lease),
    .word_error (br_word_error),
    .xfer_error (br_xfer_error),
    .desc_valid(w_desc_valid), .desc_wr(w_desc_wr),
    .desc_ptr(w_desc_ptr), .desc_limb(w_desc_limb),
    .desc_aes(fhe_slot_aes(cmd_q, w_desc_ptr)), .desc_msg(fhe_slot_msg(cmd_q, w_desc_ptr)),
    .dma_ready(w_dma_ready),
    .rd_valid(w_rd_valid), .rd_data(w_rd_data), .rd_ready(w_rd_pop),
    .wr_valid(w_wr_push), .wr_data(w_wr_data), .wr_ready(w_wr_ready),
    .slot_base(slot_base),
    .seg_active(br_active), .status(stream_status), .remaining(stream_left),
    .hw_req(fhe_dma_req), .hw_resp(fhe_dma_resp)
  );
  assign dma_idle = fhe_dma_resp.idle;

`else
  // No datapath in this build: complete every bus access OKAY with zero data.
  assign hresp_o     = 1'b0;
  assign hreadyout_o = 1'b1;
  assign hrdata_o    = '0;
  assign busy_o      = 1'b0;
  assign error_intr  = 1'b0;
  assign notif_intr  = 1'b0;
`endif

  //----------------------------------------------------------------
  // Legacy stage-0 banks: idle
  //----------------------------------------------------------------
  assign fhe_memory_export.poly_c0_we_i    = 1'b0;
  assign fhe_memory_export.poly_c0_waddr_i = '0;
  assign fhe_memory_export.poly_c0_wdata_i = '0;
  assign fhe_memory_export.poly_c0_re_i    = 1'b0;
  assign fhe_memory_export.poly_c0_raddr_i = '0;
  assign fhe_memory_export.poly_c1_we_i    = 1'b0;
  assign fhe_memory_export.poly_c1_waddr_i = '0;
  assign fhe_memory_export.poly_c1_wdata_i = '0;
  assign fhe_memory_export.poly_c1_re_i    = 1'b0;
  assign fhe_memory_export.poly_c1_raddr_i = '0;
  assign fhe_memory_export.scratch_we_i    = 1'b0;
  assign fhe_memory_export.scratch_waddr_i = '0;
  assign fhe_memory_export.scratch_wdata_i = '0;
  assign fhe_memory_export.scratch_re_i    = 1'b0;
  assign fhe_memory_export.scratch_raddr_i = '0;
  assign fhe_memory_export.key_we_i    = 1'b0;
  assign fhe_memory_export.key_waddr_i = '0;
  assign fhe_memory_export.key_wdata_i = '0;
  assign fhe_memory_export.key_re_i    = 1'b0;
  assign fhe_memory_export.key_raddr_i = '0;
  assign fhe_memory_export.encode_we_i    = 1'b0;
  assign fhe_memory_export.encode_waddr_i = '0;
  assign fhe_memory_export.encode_wdata_i = '0;
  assign fhe_memory_export.encode_re_i    = 1'b0;
  assign fhe_memory_export.encode_raddr_i = '0;
  assign fhe_memory_export.sk_we_i    = 1'b0;
  assign fhe_memory_export.sk_waddr_i = '0;
  assign fhe_memory_export.sk_wdata_i = '0;
  assign fhe_memory_export.sk_re_i    = 1'b0;
  assign fhe_memory_export.sk_raddr_i = '0;

endmodule
