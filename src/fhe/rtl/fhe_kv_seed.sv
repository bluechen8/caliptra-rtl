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
//   Stage-C' KeyVault seed reader for the FHE accelerator.
//
//   The CKKS secret key (sk) is derived on-chip from a small persistent root
//   seed (the 64-bit ternary keygen seed). For C' that root is stored in the
//   KeyVault -- a protected, per-client key store whose contents NEVER cross
//   the AHB bus -- rather than written in the clear to the AHB KGSEED
//   registers. This module reads the seed out of a firmware-provisioned KV
//   entry over a single kv_read/kv_rd_resp port and assembles it into the
//   64-bit value the microsequencer's keygen EXE step consumes.
//
//   The KV read datapath is combinational (kv_rd_resp.read_data is valid the
//   same cycle read_entry/read_offset are presented -- see kv.sv keyvault_read
//   mux), so the FSM simply walks read_offset 0..SEED_DWORDS-1, latching one
//   dword per cycle. kv_rd_resp.error asserts if the entry is locked-for-use
//   or the FHE client is not in the entry's dest_valid set (authorization);
//   any errored dword makes the whole read fail (seed_error) so the caller can
//   refuse to launch keygen with an unauthorized/garbage key.
//
module fhe_kv_seed
  import kv_defines_pkg::*;
#(
  // 64-bit keygen seed = 2 dwords. Parameterizable in case a wider root seed
  // is adopted later (a KV entry holds up to KV_NUM_DWORDS=16 dwords).
  parameter int SEED_DWORDS = 2
)(
  input  logic clk,
  input  logic rst_b,
  input  logic zeroize,

  // Request: pulse `start` with the KV entry index to read.
  input  logic                        start,
  input  logic [KV_ENTRY_ADDR_W-1:0]  read_entry,

  // KeyVault read port (one client slot in caliptra_top's kv_read[] array).
  output kv_read_t                    kv_read,
  input  kv_rd_resp_t                 kv_rd_resp,

  // Result.
  output logic [SEED_DWORDS*32-1:0]   seed,
  output logic                        seed_valid,   // 1-cycle pulse: seed ready
  output logic                        seed_error,   // held with seed_valid on fail
  output logic                        busy
);

  localparam int CNT_W = (SEED_DWORDS <= 1) ? 1 : $clog2(SEED_DWORDS);

  typedef enum logic [1:0] { S_IDLE, S_READ, S_DONE } state_e;
  state_e state;

  logic [CNT_W-1:0]                 off;        // dword offset being read
  logic [KV_ENTRY_ADDR_W-1:0]       entry_q;    // latched entry index
  logic [SEED_DWORDS*32-1:0]        seed_q;
  logic                             err_q;

  // Combinational KV read address: valid only while walking (S_READ).
  always_comb begin
    kv_read.read_entry  = entry_q;
    kv_read.read_offset = '0;
    if (state == S_READ)
      kv_read.read_offset = KV_ENTRY_SIZE_W'(off);
  end

  always_ff @(posedge clk or negedge rst_b) begin
    if (!rst_b) begin
      state      <= S_IDLE;
      off        <= '0;
      entry_q    <= '0;
      seed_q     <= '0;
      err_q      <= 1'b0;
      seed_valid <= 1'b0;
      seed_error <= 1'b0;
    end else if (zeroize) begin
      state      <= S_IDLE;
      off        <= '0;
      entry_q    <= '0;
      seed_q     <= '0;            // wipe any latched key material
      err_q      <= 1'b0;
      seed_valid <= 1'b0;
      seed_error <= 1'b0;
    end else begin
      seed_valid <= 1'b0;          // default: pulse only in S_DONE entry
      case (state)
        S_IDLE: begin
          if (start) begin
            entry_q <= read_entry;
            off     <= '0;
            seed_q  <= '0;
            err_q   <= 1'b0;
            state   <= S_READ;
          end
        end
        S_READ: begin
          // Latch this cycle's combinational dword (read_data for `off`).
          seed_q[off*32 +: 32] <= kv_rd_resp.read_data;
          err_q                <= err_q | kv_rd_resp.error;
          if (off == CNT_W'(SEED_DWORDS-1)) begin
            state <= S_DONE;
          end else begin
            off <= off + CNT_W'(1);
          end
        end
        S_DONE: begin
          seed_valid <= 1'b1;
          seed_error <= err_q;
          state      <= S_IDLE;
        end
        default: state <= S_IDLE;
      endcase
    end
  end

  assign seed = seed_q;
  assign busy = (state != S_IDLE);

endmodule
