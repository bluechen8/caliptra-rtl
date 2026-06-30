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
//   Stage-B' 2c-step-2: dedicated FHE DMA engine.
//
//   Moves CKKS ciphertext/plaintext polynomials between the FHE accelerator and
//   Rocket DRAM, driven by the microsequencer (fhe_microseq). REUSES Caliptra's
//   proven AXI burst engines `axi_mgr_rd`/`axi_mgr_wr` (module-level reuse) and
//   adds only the thin FHE-specific shim that replaces `axi_dma_ctrl`'s role:
//     * a per-poly chunk sequencer (one AXI burst per <=256-beat / <4KB chunk),
//     * small read/write FIFOs that bridge the walker's word-at-a-time stream to
//       the AXI bursts (and break the manager<->walker valid/ready comb loop),
//     * ptr-index -> base-address resolution from the fhe_top pointer registers.
//
//   AXI contract (from axi_mgr_rd/axi_dma_ctrl): the manager derives
//   arlen = byte_len[BW +: AXI_LEN_WIDTH], and the byte_len passed in must be
//   (transfer_bytes - BC) so arlen = nbeats-1. A request must be <=256 beats AND
//   must not cross a 4KB page. At DW=64 -> 256-beat (2KB) chunks from a >=2KB-
//   aligned poly base are always legal (N=256 = 1 chunk, N=8192 = 32).
//
//   Walker interface: a descriptor pulse {wr, ptr, limb} starts a transfer; the
//   poly then streams word-by-word over rd_* (DMA_IN) / wr_* (DMA_OUT) with
//   valid/ready backpressure. `dma_ready` is high only when idle.
//
module fhe_dma
  import axi_pkg::*;
#(
  parameter int AW   = 32,        // DRAM byte-address width on the manager port
  parameter int DW   = 64,        // data width (one poly coefficient pair / 64b word)
  parameter int UW   = 32,        // AXI USER width
  parameter int IW   = 1,         // AXI ID width
  parameter int LOGN = 13,
  parameter int N    = 1 << LOGN,
  parameter int FIFO_DEPTH = 8,   // beat-stream elasticity (link-bound -> shallow)
  // Don't override:
  parameter int BC          = DW/8,                 // bytes per beat (8 @ DW=64)
  parameter int CHUNK_BEATS = (N < 256) ? N : 256,  // <=256 beats, <=2KB @ DW=64
  parameter int CHUNK_BYTES = CHUNK_BEATS * BC,
  parameter int N_CHUNKS    = N / CHUNK_BEATS
)(
  input  logic clk,
  input  logic rst_n,

  // ---- microsequencer descriptor + word stream ----
  input  logic        desc_valid,     // 1-cycle pulse: start a poly transfer (only when dma_ready)
  input  logic        desc_wr,        // 1 = DMA_OUT (write to DRAM); 0 = DMA_IN (read from DRAM)
  input  logic [2:0]  desc_ptr,       // pointer-register select (0..3)
  input  logic [3:0]  desc_limb,      // limb index (DRAM stride = limb*N*BC)
  output logic        dma_ready,      // idle: can accept a descriptor / transfer complete

  // read stream to walker (DMA_IN): DRAM -> FIFO -> walker
  output logic        rd_valid,
  output logic [63:0] rd_data,
  input  logic        rd_ready,       // walker pop

  // write stream from walker (DMA_OUT): walker -> FIFO -> DRAM
  input  logic        wr_valid,       // walker push
  input  logic [63:0] wr_data,
  output logic        wr_ready,

  // base pointers (fhe_top DMA pointer registers), indexed by desc_ptr
  input  logic [63:0] ptr_base [0:3],
  input  logic [UW-1:0] axuser,

  // ---- AXI4 manager ----
  axi_if.r_mgr m_axi_r_if,
  axi_if.w_mgr m_axi_w_if
);

  localparam int CW = (N_CHUNKS <= 1) ? 1 : $clog2(N_CHUNKS);

  // Chunking assumptions (B' staging): each poly is exactly N_CHUNKS full chunks,
  // and firmware must place poly bases >=CHUNK_BYTES-aligned (so no chunk crosses a
  // 4KB AXI page). Guard the divisibility one here -- otherwise N/CHUNK_BEATS would
  // truncate and the last partial chunk would be silently dropped.
  initial if ((N % CHUNK_BEATS) != 0)
    $fatal(1, "fhe_dma: N (%0d) must be a multiple of CHUNK_BEATS (%0d)", N, CHUNK_BEATS);

  // ------------------------------------------------------------------
  // Internal request interfaces to the reused AXI managers
  // ------------------------------------------------------------------
  axi_dma_req_if #(.AW(AW)) r_req (.clk(clk), .rst_n(rst_n));
  axi_dma_req_if #(.AW(AW)) w_req (.clk(clk), .rst_n(rst_n));

  // ------------------------------------------------------------------
  // Read path: axi_mgr_rd -> read FIFO -> walker
  // ------------------------------------------------------------------
  logic          rfifo_wready;
  logic          rbeat_valid;
  logic [DW-1:0]  rbeat_data;

  // Read FIFO (manager beats -> walker word stream). Reuses the hardened,
  // PDK-mappable caliptra_prim_fifo_sync (the same prim the Caliptra DMA's ctrl
  // uses). Pass=0 => registered (1-cycle push->pop), which also breaks the
  // manager<->walker valid/ready comb loop; Secure=0 => plain pointers.
  caliptra_prim_fifo_sync #(
    .Width(DW), .Pass(1'b0), .Depth(FIFO_DEPTH), .OutputZeroIfEmpty(1'b0)
  ) i_rfifo (
    .clk_i(clk), .rst_ni(rst_n), .clr_i(1'b0),
    .wvalid_i(rbeat_valid), .wready_o(rfifo_wready), .wdata_i(rbeat_data),
    .rvalid_o(rd_valid),    .rready_i(rd_ready),     .rdata_o(rd_data),
    .full_o(), .depth_o(), .err_o()
  );

  axi_mgr_rd #(.AW(AW), .DW(DW), .UW(UW), .IW(IW)) i_axi_mgr_rd (
    .clk(clk), .rst_n(rst_n),
    .m_axi_if(m_axi_r_if),
    .req_if  (r_req.snk),
    .axuser  (axuser),
    .ready_i (rfifo_wready),
    .valid_o (rbeat_valid),
    .data_o  (rbeat_data)
  );

  // ------------------------------------------------------------------
  // Write path: walker -> write FIFO -> axi_mgr_wr
  // ------------------------------------------------------------------
  logic          wfifo_rvalid;
  logic          wbeat_ready;
  logic [DW-1:0]  wbeat_data;

  // Write FIFO (walker word stream -> manager beats), same prim as the read side.
  caliptra_prim_fifo_sync #(
    .Width(DW), .Pass(1'b0), .Depth(FIFO_DEPTH), .OutputZeroIfEmpty(1'b0)
  ) i_wfifo (
    .clk_i(clk), .rst_ni(rst_n), .clr_i(1'b0),
    .wvalid_i(wr_valid),     .wready_o(wr_ready),    .wdata_i(wr_data),
    .rvalid_o(wfifo_rvalid), .rready_i(wbeat_ready), .rdata_o(wbeat_data),
    .full_o(), .depth_o(), .err_o()
  );

  axi_mgr_wr #(.AW(AW), .DW(DW), .UW(UW), .IW(IW)) i_axi_mgr_wr (
    .clk(clk), .rst_n(rst_n),
    .m_axi_if(m_axi_w_if),
    .req_if  (w_req.snk),
    .axuser  (axuser),
    .valid_i (wfifo_rvalid),
    .data_i  (wbeat_data),
    .ready_o (wbeat_ready)
  );

  // ------------------------------------------------------------------
  // Chunk sequencer: issue one legal AXI burst per CHUNK_BEATS, serialized
  // (wait each chunk's resp before the next -- simple + correct; bubbles only).
  // ------------------------------------------------------------------
  typedef enum logic [1:0] { S_IDLE, S_REQ, S_WAIT } seq_e;
  seq_e          st;
  logic          dir;               // 1 = write
  logic [AW-1:0] cur_addr;          // running per-chunk address (increment, no multiply)
  logic [CW-1:0] chunk;

  assign dma_ready = (st == S_IDLE);

  // request drive (combinational). All fields are defaulted so always_comb infers
  // no latch; only the active channel asserts valid + the running address.
  always_comb begin
    r_req.valid    = 1'b0;
    r_req.addr     = '0;
    r_req.byte_len = '0;
    r_req.fixed    = 1'b0;
    r_req.lock     = 1'b0;
    w_req.valid    = 1'b0;
    w_req.addr     = '0;
    w_req.byte_len = '0;
    w_req.fixed    = 1'b0;
    w_req.lock     = 1'b0;
    if (st == S_REQ) begin
      if (dir) begin
        w_req.valid    = 1'b1;
        w_req.addr     = cur_addr;
        w_req.byte_len = (AXI_LEN_BC_WIDTH)'(CHUNK_BYTES - BC);
      end else begin
        r_req.valid    = 1'b1;
        r_req.addr     = cur_addr;
        r_req.byte_len = (AXI_LEN_BC_WIDTH)'(CHUNK_BYTES - BC);
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st       <= S_IDLE;
      dir      <= 1'b0;
      cur_addr <= '0;
      chunk    <= '0;
    end else begin
      unique case (st)
        S_IDLE: begin
          if (desc_valid) begin
            dir      <= desc_wr;
            cur_addr <= ptr_base[desc_ptr][AW-1:0] + AW'(desc_limb) * AW'(N) * AW'(BC);
            chunk    <= '0;
            st       <= S_REQ;
          end
        end
        S_REQ: begin
          if (dir ? (w_req.valid && w_req.ready) : (r_req.valid && r_req.ready))
            st <= S_WAIT;
        end
        S_WAIT: begin
          if (dir ? w_req.resp_valid : r_req.resp_valid) begin
            if (chunk == CW'(N_CHUNKS-1)) st <= S_IDLE;
            else begin
              chunk    <= chunk + 1'b1;
              cur_addr <= cur_addr + AW'(CHUNK_BYTES);  // next chunk: increment, not multiply
              st       <= S_REQ;
            end
          end
        end
        default: st <= S_IDLE;
      endcase
    end
  end

endmodule
