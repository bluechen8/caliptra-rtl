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
//   FHE command FSM. STAGE-0 BEHAVIORAL STUB: it accepts a command, stays
//   busy for a fixed number of cycles, then pulses `done`. No CKKS datapath
//   runs yet -- this exists so the SoC + firmware integration path (mailbox
//   -> runtime -> driver -> AHB regs -> interrupt) can be brought up and
//   smoke-tested before the real engines (Stages A-E) replace it.
//
module fhe_ctrl
  import fhe_params_pkg::*;
#(
  parameter int unsigned STUB_LATENCY = 16
)(
  input  logic     clk,
  input  logic     rst_b,
  input  logic     zeroize,

  input  logic     cmd_valid,   // 1-cycle pulse: a new command was accepted
  input  fhe_cmd_e cmd,

  output logic     busy,
  output logic     done,        // 1-cycle pulse on completion
  output logic     error
);

  localparam int unsigned CNT_W = (STUB_LATENCY <= 1) ? 1 : $clog2(STUB_LATENCY);

  logic [CNT_W-1:0] count;
  logic             running;

  always_ff @(posedge clk or negedge rst_b) begin
    if (!rst_b) begin
      running <= 1'b0;
      count   <= '0;
      done    <= 1'b0;
      error   <= 1'b0;
    end else if (zeroize) begin
      running <= 1'b0;
      count   <= '0;
      done    <= 1'b0;
      error   <= 1'b0;
    end else begin
      done <= 1'b0;
      if (!running) begin
        if (cmd_valid && (cmd != FHE_NONE)) begin
          running <= 1'b1;
          count   <= CNT_W'(STUB_LATENCY - 1);
          error   <= 1'b0;
        end
      end else begin
        if (count == '0) begin
          running <= 1'b0;
          done    <= 1'b1;   // completion pulse
        end else begin
          count <= count - 1'b1;
        end
      end
    end
  end

  assign busy = running;

endmodule
