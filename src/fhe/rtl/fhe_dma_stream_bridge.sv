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
//   FHE DMA stream bridge (register map v2, docs/fhe/16 "How the stream works").
//
//   Answers each walker descriptor {direction, slot, limb} with one segment on
//   the hardware requester port of Caliptra's axi_dma: address
//   SLOT_BASE[slot] + limb*N*8, length N*8 bytes, through AES-GCM for the AES
//   routes (`desc_aes`). The bridge packs the DMA's 32-bit beats into the
//   walker's 64-bit words (low word first) and back.
//
//   The bridge holds the DMA lease from command acceptance (`lease_start`) to
//   completion (`lease_end`), or until an abort has drained the segment in
//   flight. Inbound words are checked: message words (`desc_msg`) must be
//   finite binary64; other words are residues and must be below the limb's
//   prime. A failure taints the command (word_error) without stopping the
//   segment. A DMA error at the end of a segment taints it too (xfer_error)
//   and the bridge flushes the DMA. Once tainted, the remaining segments run
//   without traffic (zeros in, outputs dropped) so the walker still runs to
//   completion and nothing more is written.
//
module fhe_dma_stream_bridge
  import axi_pkg::*;
  import fhe_params_pkg::*;
#(
  parameter int N = FHE_N
)(
  input  logic clk,
  input  logic rst_b,

  // Command context (fhe_top)
  input  logic        cmd_start,    // any command was accepted
  input  logic        lease_start,  // a command with DMA segments was accepted
  input  logic        lease_end,    // the walker completed the command
  input  logic        abort,        // ZEROIZE: drain the segment in flight, then release
  output logic        lease,        // DMA leased (STATUS.DMA_LEASED)
  // Per command: cleared at every acceptance, so a command without segments
  // (KEYGEN) never reports the previous command's failure.
  output logic        word_error,   // an inbound word was not below its prime
  output logic        xfer_error,   // a DMA segment failed

  // Walker descriptor and word stream (DMA-routed segments only)
  input  logic        desc_valid,
  input  logic        desc_wr,      // 1: walker -> memory
  input  logic [2:0]  desc_ptr,
  input  logic [3:0]  desc_limb,
  input  logic        desc_aes,     // AES route (message in, decoded slots out)
  input  logic        desc_msg,     // binary64 message words (else residues)
  output logic        dma_ready,    // no segment active and the DMA is idle
  output logic        rd_valid,
  output logic [63:0] rd_data,
  input  logic        rd_ready,
  input  logic        wr_valid,
  input  logic [63:0] wr_data,
  output logic        wr_ready,

  input  logic [63:0] slot_base [0:3],

  // XFER_STATUS / XFER_LEFT view of the active segment
  output logic        seg_active,
  output logic [31:0] status,
  output logic [31:0] remaining,

  // axi_dma hardware requester port
  output axi_dma_hw_req_t  hw_req,
  input  axi_dma_hw_resp_t hw_resp
);

  localparam int SEG_BYTES = N * 8;
  localparam int CW = $clog2(N + 1);

  typedef enum logic [1:0] { B_IDLE, B_START, B_XFER, B_FLUSH } state_e;
  state_e state;

  logic        dir_out, aes_q, msg_q, half_in, dma_fin, faked, abort_q;
  logic [2:0]  ptr_q;
  logic [3:0]  limb_q;
  logic [63:0] addr_q;
  logic [CW-1:0] left;        // walker words still to move in this segment
  logic [CW:0]   beats_out;   // 32-bit beats still to push to the DMA (outbound);
  wire           half_out = beats_out[0];  // odd count: the high half is next
  logic        ibuf_full, obuf_full;
  logic [63:0] ibuf, obuf;

  assign seg_active = (state != B_IDLE);
  assign dma_ready  = (state == B_IDLE) && !hw_resp.busy;
  assign remaining  = 32'(left);
  assign status = fhe_xfer_status(seg_active, dir_out, ptr_q, limb_q);

  // Segment end: the DMA finished (all writes acknowledged) and, unless
  // aborting, the walker has moved every word. A failed segment flushes first.
  wire xfer_end  = (state == B_XFER) && (dma_fin || hw_resp.done || hw_resp.error) && (abort_q || left == 0);

  wire tainted = word_error || xfer_error;

  // Walker side. A faked segment (of a tainted command) supplies zeros and
  // drops outputs; an abort drain has no walker.
  wire xfer_live = (state == B_XFER) && !abort_q;
  assign rd_valid = xfer_live && !dir_out && (faked || ibuf_full);
  assign rd_data  = faked ? 64'd0 : ibuf;
  assign wr_ready = xfer_live && dir_out && (faked || !obuf_full);

  // DMA side
  wire dma_seg   = (state == B_XFER) && !faked;
  wire in_pop    = dma_seg && !dir_out && hw_resp.rd_valid && (!ibuf_full || abort_q);
  wire out_push  = dma_seg && dir_out && hw_resp.wr_ready && (beats_out != 0) && (obuf_full || abort_q);

  always_comb begin
    hw_req            = '0;
    hw_req.lease      = lease;
    hw_req.go         = (state == B_START);
    hw_req.to_axi     = dir_out;
    hw_req.aes        = aes_q;
    hw_req.addr       = addr_q;
    hw_req.byte_count = 32'(SEG_BYTES);
    hw_req.flush      = (state == B_FLUSH);
    hw_req.rd_ready   = in_pop;
    hw_req.wr_valid   = out_push;
    hw_req.wr_data    = abort_q ? 32'd0 : (half_out ? obuf[63:32] : obuf[31:0]);
  end

  always_ff @(posedge clk or negedge rst_b) begin
    if (!rst_b) begin
      state <= B_IDLE; lease <= 1'b0; abort_q <= 1'b0;
      word_error <= 1'b0; xfer_error <= 1'b0;
      dir_out <= 1'b0; aes_q <= 1'b0; msg_q <= 1'b0; ptr_q <= '0; limb_q <= '0; addr_q <= '0;
      left <= '0; beats_out <= '0; half_in <= 1'b0;
      ibuf_full <= 1'b0; obuf_full <= 1'b0; ibuf <= '0; obuf <= '0;
      dma_fin <= 1'b0; faked <= 1'b0;
    end else begin
      // ---- lease ----
      if (cmd_start) begin
        word_error <= 1'b0; xfer_error <= 1'b0;
      end
      if (lease_start) begin
        lease <= 1'b1;
      end else if (lease_end) begin
        lease <= 1'b0;
      end
      if (abort && lease) begin
        if (state == B_IDLE && !hw_resp.busy) lease <= 1'b0;
        else abort_q <= 1'b1;
      end

      case (state)
        B_IDLE: begin
          if (abort_q && !hw_resp.busy) begin
            abort_q <= 1'b0; lease <= 1'b0;
          end else if (desc_valid && !abort) begin
            dir_out   <= desc_wr; aes_q <= desc_aes; msg_q <= desc_msg; ptr_q <= desc_ptr; limb_q <= desc_limb;
            addr_q    <= slot_base[desc_ptr] + 64'(desc_limb) * 64'(SEG_BYTES);
            left      <= CW'(N);
            beats_out <= (CW+1)'(2 * N);
            half_in <= 1'b0;
            ibuf_full <= 1'b0; obuf_full <= 1'b0;
            // A tainted command runs the rest without memory traffic: the
            // segment counts as already finished on the DMA.
            dma_fin   <= tainted;
            faked     <= tainted;
            state     <= tainted ? B_XFER : B_START;
          end
        end
        B_START: begin
          if (hw_resp.busy) state <= B_XFER;
        end
        B_XFER: begin
          // inbound: pack two beats, check, hand to the walker
          if (in_pop) begin
            if (!half_in) ibuf[31:0] <= hw_resp.rd_data;
            else begin
              ibuf[63:32] <= hw_resp.rd_data;
              if (!abort_q) begin
                ibuf_full <= 1'b1;
                if (msg_q ? (hw_resp.rd_data[30:20] == 11'h7FF)     // NaN or infinity
                          : ({hw_resp.rd_data, ibuf[31:0]} >= FHE_Q[limb_q]))
                  word_error <= 1'b1;
              end
            end
            half_in <= !half_in;
          end
          if (rd_valid && rd_ready) begin
            ibuf_full <= 1'b0;
            left <= left - 1'b1;
          end
          // outbound: take a walker word, split into two beats
          if (wr_valid && wr_ready) begin
            if (!faked) begin obuf <= wr_data; obuf_full <= 1'b1; end
            left <= left - 1'b1;
          end
          if (out_push) begin
            beats_out <= beats_out - 1'b1;
            if (half_out) obuf_full <= 1'b0;
          end
          if (hw_resp.done || hw_resp.error) dma_fin <= 1'b1;
          if (hw_resp.error) xfer_error <= 1'b1;
          if (xfer_end) state <= (hw_resp.error || xfer_error) ? B_FLUSH : B_IDLE;
        end
        B_FLUSH: begin
          if (!hw_resp.error) state <= B_IDLE;
        end
        default: state <= B_IDLE;
      endcase
    end
  end

endmodule
