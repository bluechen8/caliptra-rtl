// SPDX-License-Identifier: Apache-2.0
//
// Sky130-specific single-port RAM primitive for Caliptra.
// Behavioral implementation (same as generic) — small RAMs synthesize to flip-flops.
// Simulation-only constructs ($readmemh, $display) are guarded by `ifndef SYNTHESIS`.

`include "caliptra_prim_assert.sv"

module caliptra_prim_sky130_ram_1p import caliptra_prim_ram_1p_pkg::*; #(
  parameter  int Width           = 32, // bit
  parameter  int Depth           = 128,
  parameter  int DataBitsPerMask = 1, // Number of data bits per bit of write mask
  parameter      MemInitFile     = "", // VMEM file to initialize the memory with

  localparam int Aw              = $clog2(Depth)  // derived parameter
) (
  input  logic             clk_i,

  input  logic             req_i,
  input  logic             write_i,
  input  logic [Aw-1:0]    addr_i,
  input  logic [Width-1:0] wdata_i,
  input  logic [Width-1:0] wmask_i,
  output logic [Width-1:0] rdata_o, // Read data. Data is returned one cycle after req_i is high.
  input ram_1p_cfg_t       cfg_i
);

  logic unused_cfg;
  assign unused_cfg = ^cfg_i;

  // Width of internal write mask.
  localparam int MaskWidth = Width / DataBitsPerMask;

  logic [Width-1:0]     mem [Depth];
  logic [MaskWidth-1:0] wmask;

  for (genvar k = 0; k < MaskWidth; k++) begin : gen_wmask
    assign wmask[k] = &wmask_i[k*DataBitsPerMask +: DataBitsPerMask];
  end

  // using always instead of always_ff to avoid 'ICPD  - illegal combination of drivers' error
  // thrown when using $readmemh system task to backdoor load an image
  always @(posedge clk_i) begin
    if (req_i) begin
      if (write_i) begin
        for (int i=0; i < MaskWidth; i = i + 1) begin
          if (wmask[i]) begin
            mem[addr_i][i*DataBitsPerMask +: DataBitsPerMask] <=
              wdata_i[i*DataBitsPerMask +: DataBitsPerMask];
          end
        end
      end else begin
        rdata_o <= mem[addr_i];
      end
    end
  end

`ifndef SYNTHESIS
  initial begin
    logic show_mem_paths;
    void'($value$plusargs("show_mem_paths=%0b", show_mem_paths));
    if (show_mem_paths) $display("%m");
    if (MemInitFile != "") begin : gen_meminit
        $display("Initializing memory %m from file '%s'.", MemInitFile);
        $readmemh(MemInitFile, mem);
    end
  end
`endif

endmodule
