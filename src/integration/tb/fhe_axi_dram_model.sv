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
//   Behavioral AXI4-subordinate DRAM model + FHE round-trip checker (B' 2c-step-3).
//
//   Backs the dedicated FHE DMA manager port of caliptra_top with a TB-only
//   memory (distinct from VeeR's address space -- VeeR never touches it; the
//   host/Rocket would, in the real SoC). It:
//     * responds to the manager's read/write bursts (single outstanding -- the
//       FHE DMA serializes one <=256-beat burst at a time),
//     * backdoor-preloads the golden plaintext at the P buffer (word 0..N-1),
//     * after the last DMA_OUT burst (recovered slots), checks recovered ~= input.
//
//   VeeR firmware (smoke_test_fhe) only drives the FHE registers + polls STATUS;
//   this model owns the data check, since VeeR cannot reach the DMA's DRAM.
//
//   Buffer layout is a fixed contract shared with the firmware (libs/fhe_ckks):
//     STRIDE = max(N*8, 2KB);  P=0, C0=STRIDE, C1=2*STRIDE, OUT=3*STRIDE.
//   Completion: KEYGEN writes nothing, ENCRYPT writes c0+c1, DECRYPT writes the
//   recovered slots last -> the check fires after 3*CHUNKS write bursts.
//
//   Golden plaintext is read via $readmemh from "<+PLUSARG>/input.txt"
//   (default plusarg name FHE_TVDIR, default dir ".").
//
module fhe_axi_dram_model
  import axi_pkg::*;
#(
  parameter int    N             = 256,          // ring dimension (poly length in words)
  parameter string TVDIR_PLUSARG = "FHE_TVDIR",  // +<name>=<dir> holding input.txt
  parameter real   REL_EPS       = 1.0e-3,       // recovered-vs-input relative tolerance
  parameter real   ABS_FLOOR     = 1.0e-4        // absolute floor for near-zero slots
)(
  input  logic clk,
  input  logic rst_n,
  axi_if       axi                               // driven as the AXI subordinate
);

  // Buffer layout + sizing (derived from N).
  localparam int STRIDE     = (N*8 > 2048) ? N*8 : 2048;   // >=2KB-aligned per AXI chunking
  localparam int CHUNKS     = (N*8 + 2047) / 2048;         // AXI bursts per poly
  localparam int WR_EXP     = 3 * CHUNKS;                  // c0 + c1 + recovered
  localparam int DRAM_BYTES = 4 * STRIDE;                  // P, C0, C1, OUT
  localparam int DEPTH      = DRAM_BYTES / 8;              // 64-bit words
  localparam int IDXW       = $clog2(DEPTH);

  // Single-driver discipline (VCS): dram is written ONLY by the always_ff below
  // (AXI writes + a one-shot reset-branch preload from the read-only gold array);
  // counters carry no initializers (2-state types default to 0).
  logic [63:0] dram [0:DEPTH-1];
  longint      gold  [0:N];        // golden plaintext ($readmemh, read-only)
  string       tvdir;
  int          wr_bursts;
  int          errors;
  bit          checked;
  bit          preloaded;

  // ---- read channel ----
  typedef enum logic {R_IDLE, R_DATA} r_st_e;
  r_st_e            r_q;
  logic [IDXW-1:0]  r_word;
  logic [8:0]       r_rem;
  // ---- write channel ----
  typedef enum logic [1:0] {W_IDLE, W_DATA, W_RESP} w_st_e;
  w_st_e            w_q;
  logic [IDXW-1:0]  w_word;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      r_q <= R_IDLE; r_word <= '0; r_rem <= '0;
      axi.arready <= 1'b0; axi.rvalid <= 1'b0; axi.rlast <= 1'b0;
      axi.rdata <= '0; axi.rresp <= '0; axi.rid <= '0; axi.ruser <= '0;
      w_q <= W_IDLE; w_word <= '0;
      axi.awready <= 1'b0; axi.wready <= 1'b0;
      axi.bvalid <= 1'b0; axi.bresp <= '0; axi.bid <= '0; axi.buser <= '0;
      wr_bursts <= 0;
      // One-shot backdoor preload: plaintext (gold) at the P buffer, zero elsewhere.
      if (!preloaded) begin
        for (int i = 0; i < DEPTH; i++)
          dram[i] <= (i < N) ? gold[i] : 64'd0;
        preloaded <= 1'b1;
      end
    end else begin
      // -------- read --------
      unique case (r_q)
        R_IDLE: begin
          axi.rvalid <= 1'b0; axi.rlast <= 1'b0;
          axi.arready <= 1'b1;
          if (axi.arvalid && axi.arready) begin
            axi.arready <= 1'b0;
            r_word <= axi.araddr[IDXW+2:3];
            r_rem  <= {1'b0, axi.arlen} + 9'd1;
            r_q    <= R_DATA;
          end
        end
        R_DATA: begin
          axi.rvalid <= 1'b1;
          axi.rdata  <= dram[r_word];
          axi.rresp  <= '0;
          axi.rlast  <= (r_rem == 9'd1);
          if (axi.rvalid && axi.rready) begin
            if (r_rem == 9'd1) begin
              axi.rvalid <= 1'b0;
              axi.rlast  <= 1'b0;
              r_q <= R_IDLE;
            end else begin
              r_word <= r_word + 1'b1;
              r_rem  <= r_rem - 1'b1;
              axi.rdata <= dram[r_word + 1'b1];
              axi.rlast <= (r_rem == 9'd2);
            end
          end
        end
        default: r_q <= R_IDLE;
      endcase
      // -------- write --------
      unique case (w_q)
        W_IDLE: begin
          axi.bvalid <= 1'b0; axi.wready <= 1'b0;
          axi.awready <= 1'b1;
          if (axi.awvalid && axi.awready) begin
            axi.awready <= 1'b0;
            w_word <= axi.awaddr[IDXW+2:3];
            w_q    <= W_DATA;
          end
        end
        W_DATA: begin
          axi.wready <= 1'b1;
          if (axi.wvalid && axi.wready) begin
            dram[w_word] <= axi.wdata;
            w_word <= w_word + 1'b1;
            if (axi.wlast) begin
              axi.wready <= 1'b0;
              w_q <= W_RESP;
            end
          end
        end
        W_RESP: begin
          axi.bvalid <= 1'b1; axi.bresp <= '0;
          if (axi.bvalid && axi.bready) begin
            axi.bvalid <= 1'b0;
            wr_bursts <= wr_bursts + 1;
            w_q <= W_IDLE;
          end
        end
        default: w_q <= W_IDLE;
      endcase
    end
  end

  function automatic bit close(input longint ab, input longint bb);
    real a = $bitstoreal(ab);
    real b = $bitstoreal(bb);
    real t, d;
    d = a - b; if (d < 0.0) d = -d;
    if (d < ABS_FLOOR)             close = 1;
    else if (a == 0.0 || b == 0.0) close = (d < REL_EPS);
    else begin t = b/a - 1.0; if (t < 0.0) t = -t; close = (t < REL_EPS); end
  endfunction

  // Load the golden plaintext (read-only). The reset branch copies it into the
  // P buffer (kept the sole dram driver for VCS single-driver discipline).
  initial begin
    if (!$value$plusargs({TVDIR_PLUSARG, "=%s"}, tvdir)) tvdir = ".";
    $readmemh({tvdir, "/input.txt"}, gold);
    $display("[FHE-DRAM] ready (N=%0d, STRIDE=%0d B, expect %0d wr bursts)", N, STRIDE, WR_EXP);
  end

  // After the final DMA_OUT (recovered slots) burst, check recovered ~= input.
  always @(posedge clk) begin
    if (rst_n && !checked && (wr_bursts >= WR_EXP)) begin
      int nerr = 0;
      longint got, exp;
      checked <= 1'b1;
      for (int i = 0; i < N; i++) begin
        got = dram[(3*STRIDE/8) + i];
        exp = gold[i];
        if (!close(got, exp)) begin
          if (nerr < 8)
            $display("[FHE-DRAM] recovered[%0d]: got %h (%g) exp %h (%g)", i,
                     got, $bitstoreal(got), exp, $bitstoreal(exp));
          nerr++;
        end
      end
      errors = nerr;
      if (nerr) $error("[FHE-DRAM] FHE DMA round-trip: FAIL (%0d/%0d slots)", nerr, N);
      else      $display("[FHE-DRAM] FHE DMA round-trip: PASS (%0d slots, rel<%g)", N, REL_EPS);
    end
  end

endmodule
