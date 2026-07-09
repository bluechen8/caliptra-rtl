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
//   Top wrapper for the CKKS FHE accelerator: an AHB-Lite responder modeled
//   on abr_top.sv.
//
//   STAGE-0 INTEGRATION STUB. Implements the register block by hand (CMD /
//   STATUS / DRAM pointers / config) instead of the peakrdl-generated
//   fhe_reg.sv, so the SoC + firmware path can be built and smoke-tested
//   without the RDL generator. The CKKS datapath (Stages A-E) replaces the
//   behavioral fhe_ctrl and drives the fhe_memory_export banks + KeyVault
//   ports (KeyVault ports are added in Stage C/D). Register offsets here
//   match fhe_reg.rdl.
//
module fhe_top
  import fhe_params_pkg::*;
`ifdef FHE_WALKER
  import kv_defines_pkg::*;   // C'-1b: KeyVault seed read (kv_read_t/kv_rd_resp_t)
`endif
#(
  parameter AHB_DATA_WIDTH = 64,
  parameter AHB_ADDR_WIDTH = 32,
  // FHE DMA AXI manager geometry (B' 2c-step-2). AW is overridable so a unit TB
  // can back the manager with a small caliptra_axi_sram DRAM model.
  parameter FHE_AXI_AW     = 32,
  parameter FHE_AXI_UW     = 32,
  parameter FHE_AXI_IW     = 1
)(
  input  logic clk,
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

  // SRAM banks (storage instantiated in fhe_mem_top / CaliptraCoreBlackbox)
  fhe_mem_if.req fhe_memory_export
`ifdef FHE_WALKER
  // ---- Stage-B' 2c-step-2: dedicated FHE DMA AXI4 manager port ----
  //   fhe_dma resolves the walker's ptr-indexed poly stream to DRAM bursts on
  //   this manager. Wired to FBUS by the (deferred) Chisel TLClientNode; a unit
  //   TB backs it with caliptra_axi_sram. Only present in the FHE_WALKER build.
  ,
  axi_if.r_mgr fhe_axi_r_if,
  axi_if.w_mgr fhe_axi_w_if,
  // ---- Stage-C' 1b: KeyVault seed read port ----
  //   The persistent CKKS keygen root secret lives in a firmware-provisioned
  //   KeyVault entry (never on the AHB bus). fhe_kv_seed reads it out here on a
  //   single KV client slot (kv_read[6], free when ABR is compiled out).
  output kv_read_t    fhe_kv_read,
  input  kv_rd_resp_t fhe_kv_rd_resp,
  // ---- Stage-C' 3: Aloha ComputeCore storage banks lifted to the top ----
  //   The ComputeCore BRAMs are no longer instantiated inside the vendored
  //   RTL; their ports come out here so real SRAM (Chisel SyncReadMem) can be
  //   attached at caliptra_top / CaliptraCoreBlackbox. A unit TB backs them
  //   with the behavioral fhe_aloha_mem_top.
  fhe_aloha_mem_if.req fhe_aloha_mem
`else
  // ---- Stage-0/SoC stub: transitional ptr-indexed word-stream, tied idle ----
  ,
  output logic [2:0]          fhe_dma_sel,
  output logic [FHE_LOGN:0]   fhe_dma_idx,
  input  logic [63:0]         fhe_dma_din,
  output logic                fhe_dma_dout_we,
  output logic [63:0]         fhe_dma_dout
`endif
);

  //----------------------------------------------------------------
  // AHB-Lite slave interface -> simple client bus
  //----------------------------------------------------------------
  logic                  dv;
  logic                  cif_write;
  logic [31:0]           cif_wdata;
  logic [AHB_ADDR_WIDTH-1:0] cif_addr;
  logic [31:0]           cif_rdata;
  logic                  cif_hld;
  logic                  cif_err;

  assign cif_hld = 1'b0;
  assign cif_err = 1'b0;

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
    .hld         (cif_hld),
    .err         (cif_err),
    .write       (cif_write),
    .wdata       (cif_wdata),
    .addr        (cif_addr),
    .rdata       (cif_rdata)
  );

  //----------------------------------------------------------------
  // Register offsets (word index = byte_offset >> 2), see fhe_reg.rdl
  //----------------------------------------------------------------
  localparam logic [5:0] OFF_NAME0    = 6'd0;  // 0x00
  localparam logic [5:0] OFF_NAME1    = 6'd1;  // 0x04
  localparam logic [5:0] OFF_VER0     = 6'd2;  // 0x08
  localparam logic [5:0] OFF_VER1     = 6'd3;  // 0x0C
  localparam logic [5:0] OFF_CTRL     = 6'd4;  // 0x10
  localparam logic [5:0] OFF_STATUS   = 6'd5;  // 0x14
  localparam logic [5:0] OFF_SRC0     = 6'd6;  // 0x18
  localparam logic [5:0] OFF_SRC1     = 6'd7;  // 0x1C
  localparam logic [5:0] OFF_DST0     = 6'd8;  // 0x20
  localparam logic [5:0] OFF_DST1     = 6'd9;  // 0x24
  localparam logic [5:0] OFF_KEYDST0  = 6'd10; // 0x28
  localparam logic [5:0] OFF_KEYDST1  = 6'd11; // 0x2C
  localparam logic [5:0] OFF_CONFIG   = 6'd12; // 0x30
  // Stage-B' 2c: microsequencer runtime inputs. Seeds are program-level entropy
  // (CSRNG/Trivium in C'); scales are firmware-computed (it knows Delta / level /
  // whether the ct is fresh, a product, or rescaled -- see microseq doc 5.1).
  localparam logic [5:0] OFF_KGSEED0  = 6'd13; // 0x34  keygen seed [31:0]
  localparam logic [5:0] OFF_KGSEED1  = 6'd14; // 0x38  keygen seed [63:32]
  localparam logic [5:0] OFF_ASEED0   = 6'd15; // 0x3C  a (uniform) seed [31:0]
  localparam logic [5:0] OFF_ASEED1   = 6'd16; // 0x40  a seed [63:32]
  localparam logic [5:0] OFF_ESEED0   = 6'd17; // 0x44  e0 (CBD) seed [31:0]
  localparam logic [5:0] OFF_ESEED1   = 6'd18; // 0x48  e0 seed [63:32]
  localparam logic [5:0] OFF_KGSCALE  = 6'd19; // 0x4C  keygen RNS scale (internal)
  localparam logic [5:0] OFF_ENCSCALE = 6'd20; // 0x50  encode RNS scale (ENCRYPT)
  localparam logic [5:0] OFF_I2FSCALE = 6'd21; // 0x54  signed decode I2F scale (DECRYPT)
  // B' 2c-step-2: four DMA base-pointer registers, indexed by the walker's PTR
  // index (0..3). Firmware writes the DRAM byte addresses of the poly buffers
  // (plaintext / ciphertext c0,c1 / output) per command.
  localparam logic [5:0] OFF_PTR0_LO  = 6'd22; // 0x58
  localparam logic [5:0] OFF_PTR0_HI  = 6'd23; // 0x5C
  localparam logic [5:0] OFF_PTR1_LO  = 6'd24; // 0x60
  localparam logic [5:0] OFF_PTR1_HI  = 6'd25; // 0x64
  localparam logic [5:0] OFF_PTR2_LO  = 6'd26; // 0x68
  localparam logic [5:0] OFF_PTR2_HI  = 6'd27; // 0x6C
  localparam logic [5:0] OFF_PTR3_LO  = 6'd28; // 0x70
  localparam logic [5:0] OFF_PTR3_HI  = 6'd29; // 0x74
  // C'-1b: KeyVault keygen-seed control. bit[0]=KV_EN (source the keygen root
  // seed from KeyVault instead of the KGSEED regs); bits[8:4]=READ_ENTRY (KV
  // entry index holding the 64-bit ternary seed, provisioned by firmware).
  localparam logic [5:0] OFF_KGKV_CTRL = 6'd30; // 0x78
  // C'-2 free-run PRNG. ENTSEED = CSRNG-sourced 64-bit seed for the a/e0 stream
  // (firmware reads CSRNG and writes it, mirroring the Caliptra self-serve
  // ENTROPY_IF_SEED pattern). RNG_CTRL bit[0]=FREERUN_EN (encrypt a/e0 free-run),
  // bit[1]=RESEED_REQ (doorbell: write 1 to (re)seed the a/e0 stream from ENTSEED
  // at the next encrypt pass; HW-cleared once the walker consumes it).
  localparam logic [5:0] OFF_ENTSEED0  = 6'd31; // 0x7C  a/e0 stream seed [31:0]
  localparam logic [5:0] OFF_ENTSEED1  = 6'd32; // 0x80  a/e0 stream seed [63:32]
  localparam logic [5:0] OFF_RNG_CTRL  = 6'd33; // 0x84  bit0=FREERUN_EN, bit1=RESEED_REQ

  logic [5:0] word_sel;
  assign word_sel = cif_addr[7:2];

  logic wr_en, rd_en;
  assign wr_en = dv &  cif_write;
  assign rd_en = dv & ~cif_write;

  //----------------------------------------------------------------
  // Architectural registers
  //----------------------------------------------------------------
  logic [63:0] src_addr, dst_addr, key_dst_addr;
  logic [3:0]  target_level;
  logic [7:0]  param_set_id;

  // Stage-B' 2c microsequencer inputs (see OFF_* above)
  logic [63:0] a_seed, err_seed;
  logic [31:0] kg_scale, enc_scale, i2f_scale;
  logic [63:0] dma_ptr [0:3];   // DMA base pointers, indexed by walker PTR index

  // C'-2 free-run PRNG registers (see OFF_ENTSEED*/OFF_RNG_CTRL).
  logic [63:0] entseed;         // CSRNG-sourced a/e0 stream seed (firmware-written)
  logic        freerun_en;      // RNG_CTRL[0]
  logic        reseed_req;      // RNG_CTRL[1] doorbell (SW-set, HW-cleared)
  logic        reseed_ack_hw;   // walker consumed the doorbell (0 in the no-walker build)
`ifndef FHE_KV_SEED_ONLY
  // Plaintext AHB keygen-seed path. Present for bring-up (the DPI cosim + unit
  // TBs have no KeyVault); COMPILED OUT by FHE_KV_SEED_ONLY so the final secure
  // build has no way to inject a keygen seed in the clear over the bus.
  logic [63:0] kg_seed;
`endif

  // C'-1b KeyVault keygen-seed control register (KGKV_CTRL).
  logic        kgkv_en;
  logic [4:0]  kgkv_entry;

  // In the KV-only (secure) build KeyVault is the sole keygen-seed source, so
  // the KV read is always taken on KEYGEN regardless of the KV_EN bit.
`ifdef FHE_KV_SEED_ONLY
  wire kgkv_en_eff = 1'b1;
`else
  wire kgkv_en_eff = kgkv_en;
`endif

  fhe_cmd_e cmd_q;
  logic     cmd_valid;
  logic     status_valid;
  logic     status_error;

  logic     ctrl_busy, ctrl_done, ctrl_error;
  logic     ctrl_wait_entropy;   // C'-2: walker stalled awaiting a firmware reseed (RESEED_REQ)
  logic     wait_entropy_q;      // for a 1-cycle notif pulse on entering the wait
  logic     ready;
  logic     zeroize;

  assign ready  = ~ctrl_busy;
  assign busy_o = ctrl_busy;

  logic ctrl_wr;
  assign ctrl_wr = wr_en & (word_sel == OFF_CTRL);
  assign zeroize = ctrl_wr & cif_wdata[3];               // ZEROIZE bit

  // Command accept: CTRL written with a non-NONE opcode while ready.
  logic cmd_accept;
  assign cmd_accept = ctrl_wr & ready & (cif_wdata[2:0] != 3'b000);

  always_ff @(posedge clk or negedge rst_b) begin
    if (!rst_b) begin
      src_addr     <= '0;
      dst_addr     <= '0;
      key_dst_addr <= '0;
      target_level <= '0;
      param_set_id <= '0;
`ifndef FHE_KV_SEED_ONLY
      kg_seed      <= '0;
`endif
      a_seed       <= '0;
      err_seed     <= '0;
      kg_scale     <= '0;
      enc_scale    <= '0;
      i2f_scale    <= '0;
      for (int p = 0; p < 4; p++) dma_ptr[p] <= '0;
      kgkv_en      <= 1'b0;
      kgkv_entry   <= '0;
      cmd_q        <= FHE_NONE;
      cmd_valid    <= 1'b0;
    end else if (zeroize) begin
      src_addr     <= '0;
      dst_addr     <= '0;
      key_dst_addr <= '0;
      target_level <= '0;
      param_set_id <= '0;
`ifndef FHE_KV_SEED_ONLY
      kg_seed      <= '0;
`endif
      a_seed       <= '0;
      err_seed     <= '0;
      kg_scale     <= '0;
      enc_scale    <= '0;
      i2f_scale    <= '0;
      for (int p = 0; p < 4; p++) dma_ptr[p] <= '0;
      kgkv_en      <= 1'b0;
      kgkv_entry   <= '0;
      cmd_q        <= FHE_NONE;
      cmd_valid    <= 1'b0;
    end else begin
      cmd_valid <= cmd_accept;
      if (cmd_accept) cmd_q <= fhe_cmd_e'(cif_wdata[2:0]);
      if (wr_en && ready) begin
        unique case (word_sel)
          OFF_SRC0:    src_addr[31:0]      <= cif_wdata;
          OFF_SRC1:    src_addr[63:32]     <= cif_wdata;
          OFF_DST0:    dst_addr[31:0]      <= cif_wdata;
          OFF_DST1:    dst_addr[63:32]     <= cif_wdata;
          OFF_KEYDST0: key_dst_addr[31:0]  <= cif_wdata;
          OFF_KEYDST1: key_dst_addr[63:32] <= cif_wdata;
          OFF_CONFIG: begin
            target_level <= cif_wdata[3:0];
            param_set_id <= cif_wdata[11:4];
          end
`ifndef FHE_KV_SEED_ONLY
          OFF_KGSEED0:  kg_seed[31:0]   <= cif_wdata;
          OFF_KGSEED1:  kg_seed[63:32]  <= cif_wdata;
`endif
          OFF_ASEED0:   a_seed[31:0]    <= cif_wdata;
          OFF_ASEED1:   a_seed[63:32]   <= cif_wdata;
          OFF_ESEED0:   err_seed[31:0]  <= cif_wdata;
          OFF_ESEED1:   err_seed[63:32] <= cif_wdata;
          OFF_KGSCALE:  kg_scale        <= cif_wdata;
          OFF_ENCSCALE: enc_scale       <= cif_wdata;
          OFF_I2FSCALE: i2f_scale       <= cif_wdata;
          OFF_PTR0_LO:  dma_ptr[0][31:0]  <= cif_wdata;
          OFF_PTR0_HI:  dma_ptr[0][63:32] <= cif_wdata;
          OFF_PTR1_LO:  dma_ptr[1][31:0]  <= cif_wdata;
          OFF_PTR1_HI:  dma_ptr[1][63:32] <= cif_wdata;
          OFF_PTR2_LO:  dma_ptr[2][31:0]  <= cif_wdata;
          OFF_PTR2_HI:  dma_ptr[2][63:32] <= cif_wdata;
          OFF_PTR3_LO:  dma_ptr[3][31:0]  <= cif_wdata;
          OFF_PTR3_HI:  dma_ptr[3][63:32] <= cif_wdata;
          OFF_KGKV_CTRL: begin
            kgkv_en    <= cif_wdata[0];
            kgkv_entry <= cif_wdata[8:4];
          end
          // C'-2 ENTSEED/RNG_CTRL are in a separate UNGATED block below (writable
          // while busy so a stalled first-encrypt can be released by the doorbell).
          default: ;
        endcase
      end
    end
  end

  // C'-2 free-run entropy path (ENTSEED / FREERUN_EN / RESEED_REQ). Deliberately
  // NOT gated by `ready`: these must be writable even while a command is BUSY, so
  // firmware can deliver the RESEED_REQ doorbell that RELEASES a first-encrypt which
  // is stalled waiting for fresh entropy after keygen / cold reset. The AHB slave
  // never back-pressures (cif_hld=0), so wr_en pulses regardless of ctrl_busy.
  always_ff @(posedge clk or negedge rst_b) begin
    if (!rst_b || zeroize) begin
      entseed <= '0; freerun_en <= 1'b0; reseed_req <= 1'b0;
    end else begin
      if (wr_en) begin
        unique case (word_sel)
          OFF_ENTSEED0: entseed[31:0]  <= cif_wdata;
          OFF_ENTSEED1: entseed[63:32] <= cif_wdata;
          OFF_RNG_CTRL: freerun_en     <= cif_wdata[0];
          default: ;
        endcase
      end
      // RESEED_REQ doorbell: SW-set (bit1) wins a same-cycle collision; else the
      // walker's ack clears it once the a/e0 stream is (re)seeded.
      if (wr_en && (word_sel == OFF_RNG_CTRL) && cif_wdata[1]) reseed_req <= 1'b1;
      else if (reseed_ack_hw)                                  reseed_req <= 1'b0;
    end
  end

  // VALID: set on completion, cleared when a new command is accepted.
  always_ff @(posedge clk or negedge rst_b) begin
    if (!rst_b) begin
      status_valid <= 1'b0;
      status_error <= 1'b0;
    end else if (zeroize) begin
      status_valid <= 1'b0;
      status_error <= 1'b0;
    end else begin
      if (cmd_accept) begin
        status_valid <= 1'b0;
        status_error <= 1'b0;
      end else if (ctrl_done) begin
        status_valid <= 1'b1;
        status_error <= ctrl_error;
      end
    end
  end

  //----------------------------------------------------------------
  // Command engine
  //----------------------------------------------------------------
`ifdef FHE_WALKER
  //--------------------------------------------------------------------------
  // Stage-B' 2c: the REAL datapath -- the ROM-microcoded walker (fhe_microseq)
  // driving the Aloha-HE ComputeCore over its native debug-IO pins. This is the
  // green Stage-B' 2b wiring lifted out of the TB into fhe_top proper: the
  // register block plays "firmware" (CMD selects the program entry; the seed/scale
  // registers feed the EXE seeds + INS scale-field patches), and the walker's
  // ptr-indexed poly stream is moved to/from Rocket DRAM by the dedicated fhe_dma
  // engine (2c-step-2) over the AXI4 manager port. Gated by `FHE_WALKER` because
  // the SoC build does not yet compile the Aloha sources; the stub path below keeps
  // that build (and the firmware smoke test) green until the SoC-build flip lands
  // the Aloha filelist + FBUS glue. SCHEME=1 selects the secret-key PWMSk lane.
  //--------------------------------------------------------------------------
  // Per-modulus R^2 mod q_i for keygen's Montgomery-convert (CONST R2MODQ; R=2^72).
  // Frozen 2-prime Rung-7 chain: q0 = 2^46-9*2^24+1, q1 = 2^47-2^24+1. (microseq
  // doc 5.2/8.2 -- the tiny per-modulus ROM that sits beside the limb-param table.)
  localparam logic [63:0] R2MODQ [0:FHE_L-1] =
      '{0: 64'h00000f47_3d9a6eb2, 1: 64'h00007fff_f7000009, default: 64'd0};

  // ---- C'-1b: KeyVault keygen-seed read ----
  // On a KEYGEN command with KV_EN set, pulse the KV reader to fetch the 64-bit
  // ternary root seed from the firmware-provisioned entry. The walker latches
  // keygen_seed lazily at its EXE step -- hundreds of cycles after cmd_valid (a
  // full N-word CONST runs first) -- so the ~3-cycle KV read always resolves in
  // time; no cmd_valid stall is needed. Authorization/lock failures set
  // kv_err_q, folded into ctrl_error so firmware refuses the resulting key.
  logic        kv_start;
  logic [63:0] kv_seed;
  logic        kv_seed_valid, kv_seed_error;
  logic        kv_err_q;

  assign kv_start = cmd_accept & (cif_wdata[2:0] == FHE_KEYGEN) & kgkv_en_eff;

  // fhe_kv_seed holds the assembled seed stable on its `seed` output from the
  // read's completion until the next command -- hundreds of cycles before the
  // walker samples it -- so no extra latch is needed here (kg_seed_eff taps it
  // directly). zeroize wipes the seed inside the module.
  fhe_kv_seed #(.SEED_DWORDS(2)) i_fhe_kv_seed (
    .clk        (clk),
    .rst_b      (rst_b),
    .zeroize    (zeroize),
    .start      (kv_start),
    .read_entry (kgkv_entry),
    .kv_read    (fhe_kv_read),
    .kv_rd_resp (fhe_kv_rd_resp),
    .seed       (kv_seed),
    .seed_valid (kv_seed_valid),
    .seed_error (kv_seed_error),
    .busy       (/* unused */)
  );

  // The module's seed_error only updates at read completion; kv_err_q adds the
  // early clear at command start so a stale auth/lock error can't taint a new
  // KEYGEN before the fresh read resolves.
  always_ff @(posedge clk or negedge rst_b) begin
    if (!rst_b) begin
      kv_err_q  <= 1'b0;
    end else if (zeroize) begin
      kv_err_q  <= 1'b0;
    end else begin
      if (kv_start) kv_err_q <= 1'b0;  // clear stale error at command start
      if (kv_seed_valid) kv_err_q <= kv_seed_error;
    end
  end

  // Effective keygen seed. In the secure KV-only build KeyVault is the sole
  // source (the KGSEED register path is compiled out); otherwise KV when
  // enabled, else the AHB KGSEED register (DPI cosim / unit-TB paths).
  logic [63:0] kg_seed_eff;
`ifdef FHE_KV_SEED_ONLY
  assign kg_seed_eff = kv_seed;
`else
  assign kg_seed_eff = kgkv_en_eff ? kv_seed : kg_seed;
`endif

  // walker <-> core debug-IO
  logic [31:0] w_cl, w_ch, w_dl, w_dh;
  logic [31:0] core_dout_lo, core_dout_hi, core_status;
  logic        w_busy, w_done, w_error;

  // C'-2 free-run PRNG controls. `fhe_prng_rst` resets the sampler Trivium ONLY at
  // FHE power-on -- DECOUPLED from the per-EXE core reset the walker pulses
  // (control_high_word[0]); tying the Trivium to that would wipe its state before
  // every pass and defeat free-run. It is driven from the async reset `~rst_b` ONLY
  // (the adapter consumes it as an async reset): `zeroize` is a synchronous control
  // everywhere in this block, so it is NOT OR'd onto this async net -- instead the
  // walker sets ae_needs_seed on zeroize, forcing a firmware reseed before the next
  // encryption (the stale keystream is never used). `w_reseed_en` is the walker's
  // per-pass reseed gate (1 = reload from seed; 0 = free-run continue).
  logic        fhe_prng_rst;
  assign       fhe_prng_rst = ~rst_b;
  logic        w_reseed_en;

  // walker <-> fhe_dma (descriptor + word stream). ext_sel/ext_idx are unused by
  // the streaming DMA (fhe_dma resolves base from the descriptor + PTR regs).
  logic [2:0]   w_ext_sel;
  logic [FHE_LOGN:0] w_ext_idx;
  logic [63:0]  w_rd_data, w_wr_data;
  logic         w_wr_push;
  logic         w_desc_valid, w_desc_wr;
  logic [2:0]   w_desc_ptr;
  logic [3:0]   w_desc_limb;
  logic         w_dma_ready, w_rd_valid, w_rd_pop, w_wr_ready;

  fhe_microseq #(.LOGN(FHE_LOGN), .N(FHE_N)) walker (
    .clk            (clk),
    .rst_b          (rst_b),
    .zeroize        (zeroize),
    .cmd_valid      (cmd_valid),
    .cmd            (cmd_q),
    .keygen_seed    (kg_seed_eff),
    .a_seed         (a_seed),
    .err_seed       (err_seed),
    .freerun_en     (freerun_en),
    .entseed        (entseed),
    .reseed_req     (reseed_req),
    .reseed_en      (w_reseed_en),
    .reseed_ack     (reseed_ack_hw),
    .reseed_wait    (ctrl_wait_entropy),
    .rns_scale_kg   (kg_scale),
    .rns_scale_enc  (enc_scale),
    .i2f_scale_dec  (i2f_scale),
    .num_limbs      (target_level),    // CONFIG.L (encrypt); walker forces 1 for decrypt
    .r2modq         (R2MODQ),
    // ComputeCore debug-IO master
    .control_low_word  (w_cl),
    .control_high_word (w_ch),
    .dina_low          (w_dl),
    .dina_high         (w_dh),
    .dout_low          (core_dout_lo),
    .dout_high         (core_dout_hi),
    .status            (core_status),
    // poly word-stream + DMA descriptor/handshake -> fhe_dma
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
    .busy           (w_busy),
    .done           (w_done),
    .error          (w_error)
  );

  ComputeCoreWrapper #(
    .FFT_ON_THE_FLY_GENERATION (0),
    .PROVIDE_DEBUG_IO          (1),
    .LOGN                      (FHE_LOGN),
    .N                         (FHE_N),
    .SCHEME                    (1)
  ) core (
    .clk                (clk),
    .reseed_en          (w_reseed_en),
    .prng_rst_i         (fhe_prng_rst),
    .control_low_word   (w_cl),
    .control_high_word  (w_ch),
    .dina_ext_low_word  (w_dl),
    .dina_ext_high_word (w_dh),
    .dout_ext_low_word  (core_dout_lo),
    .dout_ext_high_word (core_dout_hi),
    .status             (core_status),
    // ComputeCore's own DMA-into-BRAM port is unused here (the walker moves poly
    // data over the debug-IO send64/receive64 path, exactly as in 2b).
    .dma_bram_byte_wea  (8'd0),
    .dma_bram_abs_addr  (18'd0),
    .dma_bram_dina      (64'd0),
    .dma_bram_doutb     (),
    .dma_bram_en        (1'b0),
    // C'-3: storage banks lifted to the top (real SRAM at CaliptraCoreBlackbox)
    .m_aloha_mem        (fhe_aloha_mem)
  );

  // Dedicated FHE DMA: reuses Caliptra's axi_mgr_rd/axi_mgr_wr; resolves the
  // walker descriptor + PTR regs to chunked AXI bursts on the manager port.
  fhe_dma #(
    .AW   (FHE_AXI_AW),
    .DW   (64),
    .UW   (FHE_AXI_UW),
    .IW   (FHE_AXI_IW),
    .LOGN (FHE_LOGN),
    .N    (FHE_N)
  ) i_fhe_dma (
    .clk        (clk),
    .rst_n      (rst_b),
    .desc_valid (w_desc_valid),
    .desc_wr    (w_desc_wr),
    .desc_ptr   (w_desc_ptr),
    .desc_limb  (w_desc_limb),
    .dma_ready  (w_dma_ready),
    .rd_valid   (w_rd_valid),
    .rd_data    (w_rd_data),
    .rd_ready   (w_rd_pop),
    .wr_valid   (w_wr_push),
    .wr_data    (w_wr_data),
    .wr_ready   (w_wr_ready),
    .ptr_base   (dma_ptr),
    .axuser     ((FHE_AXI_UW)'(1)),       // Caliptra PAUSER (canonical 0x1)
    .m_axi_r_if (fhe_axi_r_if),
    .m_axi_w_if (fhe_axi_w_if)
  );

  assign ctrl_busy  = w_busy;
  assign ctrl_done  = w_done;
  assign ctrl_error = w_error | kv_err_q;   // KV auth/lock failure taints keygen

`else
  //--------------------------------------------------------------------------
  // STAGE-0 behavioral stub (the SoC-build default): fixed-latency completion,
  // no datapath. Keeps the firmware smoke path green before the Aloha sources +
  // FBUS DMA are wired into the SoC build (2c-step-2).
  //--------------------------------------------------------------------------
  fhe_ctrl #(.STUB_LATENCY(16)) ctrl_inst (
    .clk       (clk),
    .rst_b     (rst_b),
    .zeroize   (zeroize),
    .cmd_valid (cmd_valid),
    .cmd       (cmd_q),
    .busy      (ctrl_busy),
    .done      (ctrl_done),
    .error     (ctrl_error)
  );

  // No datapath -> the DMA word-stream is idle.
  assign fhe_dma_sel     = 3'd0;
  assign fhe_dma_idx     = '0;
  assign fhe_dma_dout_we = 1'b0;
  assign fhe_dma_dout    = 64'd0;
  // No walker -> the RESEED_REQ doorbell is never consumed, and no reseed stall.
  assign reseed_ack_hw     = 1'b0;
  assign ctrl_wait_entropy = 1'b0;
`endif

  // Interrupt outputs (1-cycle pulses; PIC programmed edge-sensitive).
  // C'-2: also raise a NOTIF on ENTERING the reseed-wait, so firmware that forgot
  // to reseed is alerted (poll STATUS.RESEED_REQ_PENDING, then write the doorbell)
  // instead of the command silently hanging. busy stays asserted throughout.
  // NOTIF CONTRACT: notif means "state changed -> read STATUS." It fires for BOTH
  // completion (VALID) and this reseed-wait (RESEED_REQ_PENDING); the consumer must
  // read STATUS to tell them apart (there is no fhe ISR today -- all paths poll).
  always_ff @(posedge clk or negedge rst_b) begin
    if (!rst_b)       wait_entropy_q <= 1'b0;
    else if (zeroize) wait_entropy_q <= 1'b0;
    else              wait_entropy_q <= ctrl_wait_entropy;
  end
  assign notif_intr = ctrl_done | (ctrl_wait_entropy & ~wait_entropy_q);
  assign error_intr = ctrl_done & ctrl_error;

  //----------------------------------------------------------------
  // Read mux
  //----------------------------------------------------------------
  always_comb begin
    unique case (word_sel)
      OFF_NAME0:   cif_rdata = FHE_CORE_NAME[31:0];
      OFF_NAME1:   cif_rdata = FHE_CORE_NAME[63:32];
      OFF_VER0:    cif_rdata = FHE_CORE_VERSION[31:0];
      OFF_VER1:    cif_rdata = FHE_CORE_VERSION[63:32];
      OFF_CTRL:    cif_rdata = 32'b0; // self-clearing, reads 0
      // bit4 = RESEED_REQ_PENDING (C'-2: encrypt stalled awaiting a firmware reseed)
      OFF_STATUS:  cif_rdata = {27'b0, ctrl_wait_entropy, status_error, 1'b0 /*DMA_REQ*/, status_valid, ready};
      OFF_SRC0:    cif_rdata = src_addr[31:0];
      OFF_SRC1:    cif_rdata = src_addr[63:32];
      OFF_DST0:    cif_rdata = dst_addr[31:0];
      OFF_DST1:    cif_rdata = dst_addr[63:32];
      OFF_KEYDST0: cif_rdata = key_dst_addr[31:0];
      OFF_KEYDST1: cif_rdata = key_dst_addr[63:32];
      OFF_CONFIG:  cif_rdata = {20'b0, param_set_id, target_level};
`ifndef FHE_KV_SEED_ONLY
      OFF_KGSEED0: cif_rdata = kg_seed[31:0];
      OFF_KGSEED1: cif_rdata = kg_seed[63:32];
`endif
      OFF_ASEED0:  cif_rdata = a_seed[31:0];
      OFF_ASEED1:  cif_rdata = a_seed[63:32];
      OFF_ESEED0:  cif_rdata = err_seed[31:0];
      OFF_ESEED1:  cif_rdata = err_seed[63:32];
      OFF_KGSCALE: cif_rdata = kg_scale;
      OFF_ENCSCALE:cif_rdata = enc_scale;
      OFF_I2FSCALE:cif_rdata = i2f_scale;
      OFF_PTR0_LO: cif_rdata = dma_ptr[0][31:0];
      OFF_PTR0_HI: cif_rdata = dma_ptr[0][63:32];
      OFF_PTR1_LO: cif_rdata = dma_ptr[1][31:0];
      OFF_PTR1_HI: cif_rdata = dma_ptr[1][63:32];
      OFF_PTR2_LO: cif_rdata = dma_ptr[2][31:0];
      OFF_PTR2_HI: cif_rdata = dma_ptr[2][63:32];
      OFF_PTR3_LO: cif_rdata = dma_ptr[3][31:0];
      OFF_PTR3_HI: cif_rdata = dma_ptr[3][63:32];
      OFF_KGKV_CTRL: cif_rdata = {23'b0, kgkv_entry, 3'b0, kgkv_en_eff};
      default:     cif_rdata = 32'b0;
    endcase
  end

  //----------------------------------------------------------------
  // SRAM banks: idle in the stub (driven by the datapath in Stages A-E)
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
