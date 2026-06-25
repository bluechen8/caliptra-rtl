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
#(
  parameter AHB_DATA_WIDTH = 64,
  parameter AHB_ADDR_WIDTH = 32
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

  fhe_cmd_e cmd_q;
  logic     cmd_valid;
  logic     status_valid;
  logic     status_error;

  logic     ctrl_busy, ctrl_done, ctrl_error;
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
      cmd_q        <= FHE_NONE;
      cmd_valid    <= 1'b0;
    end else if (zeroize) begin
      src_addr     <= '0;
      dst_addr     <= '0;
      key_dst_addr <= '0;
      target_level <= '0;
      param_set_id <= '0;
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
          default: ;
        endcase
      end
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
  // Behavioral command FSM (replaced by real datapath in Stages A-E)
  //----------------------------------------------------------------
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

  // Interrupt outputs (1-cycle pulses; PIC programmed edge-sensitive).
  assign notif_intr = ctrl_done;
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
      OFF_STATUS:  cif_rdata = {28'b0, status_error, 1'b0 /*DMA_REQ*/, status_valid, ready};
      OFF_SRC0:    cif_rdata = src_addr[31:0];
      OFF_SRC1:    cif_rdata = src_addr[63:32];
      OFF_DST0:    cif_rdata = dst_addr[31:0];
      OFF_DST1:    cif_rdata = dst_addr[63:32];
      OFF_KEYDST0: cif_rdata = key_dst_addr[31:0];
      OFF_KEYDST1: cif_rdata = key_dst_addr[63:32];
      OFF_CONFIG:  cif_rdata = {20'b0, param_set_id, target_level};
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
