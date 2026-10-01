// SPDX-License-Identifier: Apache-2.0
// Private firmware/Aloha transport. No external AXI or address interpretation.
// DATA accesses are 32-bit, low word first. STATUS must be polled before DATA.
// The output descriptor completes only when firmware consumes its final word.
module fhe_local_stream #(parameter int N = 8192)(
  input logic clk, rst_n, clear,
  input logic desc_valid, desc_wr,
  input logic [2:0] desc_ptr,
  input logic [3:0] desc_limb,
  output logic dma_ready,
  output logic rd_valid,
  output logic [63:0] rd_data,
  input logic rd_ready,
  input logic wr_valid,
  input logic [63:0] wr_data,
  output logic wr_ready,
  input logic data_read, data_write,
  input logic [31:0] data_wdata,
  output logic [31:0] data_rdata, status, remaining,
  output logic access_error
);
  logic active, direction, full, half;
  logic [2:0] ptr;
  logic [3:0] limb;
  logic [63:0] payload;
  logic [$clog2(N+1)-1:0] left;
  wire input_ready = active && !direction && !full;
  wire output_valid = active && direction && full;
  assign dma_ready = !active;
  assign rd_valid = active && !direction && full;
  assign rd_data = payload;
  assign wr_ready = active && direction && !full;
  assign data_rdata = output_valid ? (half ? payload[63:32] : payload[31:0]) : 0;
  assign access_error = (data_write && !input_ready) || (data_read && !output_valid);
  assign remaining = 32'(left);
  // bit 0 active, 1 output direction, 2 input ready, 3 output valid,
  // [6:4] pointer selector, [11:8] limb, bit 12 next DATA access is high half.
  assign status = {19'b0, half, limb, 1'b0, ptr, output_valid, input_ready, direction, active};
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      active <= 0; direction <= 0; full <= 0; half <= 0;
      ptr <= 0; limb <= 0; payload <= 0; left <= 0;
    end else if (clear) begin
      active <= 0; direction <= 0; full <= 0; half <= 0;
      ptr <= 0; limb <= 0; payload <= 0; left <= 0;
    end else if (!active) begin
      if (desc_valid) begin
        active <= 1; direction <= desc_wr; ptr <= desc_ptr; limb <= desc_limb;
        full <= 0; half <= 0; payload <= 0; left <= $bits(left)'(N);
      end
    end else if (!direction) begin
      if (data_write && input_ready) begin
        if (!half) payload[31:0] <= data_wdata;
        else begin payload[63:32] <= data_wdata; full <= 1; end
        half <= !half;
      end
      if (rd_valid && rd_ready) begin
        full <= 0; payload <= 0; left <= left - 1'b1;
        if (left == 1) active <= 0;
      end
    end else begin
      if (wr_valid && wr_ready) begin payload <= wr_data; full <= 1; end
      if (data_read && output_valid) begin
        half <= !half;
        if (half) begin
          full <= 0; payload <= 0; left <= left - 1'b1;
          if (left == 1) active <= 0;
        end
      end
    end
  end
endmodule
