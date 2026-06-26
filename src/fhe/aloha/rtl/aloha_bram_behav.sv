// aloha_bram_behav.sv
// -----------------------------------------------------------------------------
// Technology-generic behavioral replacements for the Xilinx blk_mem_gen BRAM/ROM
// IP instances used by Aloha-HE. These are the ASIC-port memory primitives
// (Stage A'); on Sky130 they map to SyncReadMem / compiled SRAM macros, exactly
// like the rest of the Caliptra SRAMs are lifted in CaliptraCoreBlackbox.sv.
//
// Geometry, operating mode, and READ LATENCY were taken from the Kintex .xci
// configs (Write_Width/Depth, Memory_Type, Operating_Mode, and the
// Register_Port*_Output_of_Memory_Primitives flag). Every bank here has exactly
// ONE output register on its read port -> read latency = 2 cycles (1 synchronous
// array read + 1 output register). This is corroborated by SharedFFTBrams.sv,
// which carries `parameter BRAM_RD_LAT = 2` and delays its read-select by that.
//
//   IP name           | type            | W  | depth | read port | mode (read)
//   ------------------|-----------------|----|-------|-----------|------------
//   NTTPolyBank       | simple-dual-port| 54 | 4096  | B (doutb) | READ_FIRST
//   SharedFFTBramBank | simple-dual-port| 74 | 4096  | B (doutb) | WRITE_FIRST
//   CBDPolyBRAM       | single-port     |  6 | 8192  | A (douta) | WRITE_FIRST
//   TernaryPolyBRAM   | single-port     |  2 | 8192  | A (douta) | WRITE_FIRST
//   ModRingPolyBRAM   | simple-dual-port| 54 | 8192  | B (doutb) | (Rung 3)
// (ROMs FFTTw_RNS_ROM / FFTAllTwiddleROM are added with the Rung-3 work.)
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

// Generic simple-dual-port RAM: write on port A (clka/addra/dina/wea), read on
// port B (clkb/addrb -> doutb). Read latency = RD_LAT cycles.
// WRITE_FIRST=1 forwards a same-cycle, same-address write to the read output;
// WRITE_FIRST=0 is read-first (read returns the OLD contents on collision).
module aloha_bram_sdp #(
    parameter int W          = 54,
    parameter int DEPTH      = 4096,
    parameter int RD_LAT     = 2,
    parameter bit WRITE_FIRST = 1'b0,
    parameter int AW         = $clog2(DEPTH)
  )(
    input               clka,
    input               clkb,
    input  [AW-1:0]     addra,
    input  [AW-1:0]     addrb,
    input  [W-1:0]      dina,
    input               wea,
    output [W-1:0]      doutb
  );
  logic [W-1:0] mem [0:DEPTH-1];
  always_ff @(posedge clka)
    if (wea) mem[addra] <= dina;

  logic [W-1:0] rd_pipe [0:RD_LAT-1];
  logic         collide;
  assign collide = WRITE_FIRST && wea && (addra == addrb);
  integer s;
  always_ff @(posedge clkb) begin
    rd_pipe[0] <= collide ? dina : mem[addrb];
    for (s = 1; s < RD_LAT; s = s + 1)
      rd_pipe[s] <= rd_pipe[s-1];
  end
  assign doutb = rd_pipe[RD_LAT-1];
endmodule


// Generic single-port RAM: one address; write when wea, read always (douta).
// WRITE_FIRST: on a write, douta shows the freshly written data. Latency RD_LAT.
module aloha_bram_sp #(
    parameter int W      = 6,
    parameter int DEPTH  = 8192,
    parameter int RD_LAT = 2,
    parameter int AW     = $clog2(DEPTH)
  )(
    input               clka,
    input  [AW-1:0]     addra,
    input  [W-1:0]      dina,
    input               wea,
    output [W-1:0]      douta
  );
  logic [W-1:0] mem [0:DEPTH-1];
  logic [W-1:0] rd_pipe [0:RD_LAT-1];
  integer s;
  always_ff @(posedge clka) begin
    if (wea) mem[addra] <= dina;
    rd_pipe[0] <= wea ? dina : mem[addra];   // WRITE_FIRST
    for (s = 1; s < RD_LAT; s = s + 1)
      rd_pipe[s] <= rd_pipe[s-1];
  end
  assign douta = rd_pipe[RD_LAT-1];
endmodule


// ---- named wrappers matching the upstream blk_mem_gen instance names ----

module NTTPolyBank (
    input         clka, clkb,
    input  [11:0] addra, addrb,
    input  [53:0] dina,
    output [53:0] doutb,
    input         wea
  );
  aloha_bram_sdp #(.W(54), .DEPTH(4096), .RD_LAT(2), .WRITE_FIRST(1'b0)) u (
    .clka(clka), .clkb(clkb), .addra(addra), .addrb(addrb),
    .dina(dina), .wea(wea), .doutb(doutb));
endmodule

module SharedFFTBramBank (
    input         clka, clkb,
    input  [11:0] addra, addrb,
    input  [73:0] dina,
    output [73:0] doutb,
    input         wea
  );
  aloha_bram_sdp #(.W(74), .DEPTH(4096), .RD_LAT(2), .WRITE_FIRST(1'b1)) u (
    .clka(clka), .clkb(clkb), .addra(addra), .addrb(addrb),
    .dina(dina), .wea(wea), .doutb(doutb));
endmodule

module CBDPolyBRAM (
    input         clka,
    input  [12:0] addra,
    input  [5:0]  dina,
    output [5:0]  douta,
    input         wea
  );
  aloha_bram_sp #(.W(6), .DEPTH(8192), .RD_LAT(2)) u (
    .clka(clka), .addra(addra), .dina(dina), .wea(wea), .douta(douta));
endmodule

module TernaryPolyBRAM (
    input         clka,
    input  [12:0] addra,
    input  [1:0]  dina,
    output [1:0]  douta,
    input         wea
  );
  aloha_bram_sp #(.W(2), .DEPTH(8192), .RD_LAT(2)) u (
    .clka(clka), .addra(addra), .dina(dina), .wea(wea), .douta(douta));
endmodule

module ModRingPolyBRAM (
    input         clka, clkb,
    input  [12:0] addra, addrb,
    input  [53:0] dina,
    output [53:0] doutb,
    input         wea
  );
  aloha_bram_sdp #(.W(54), .DEPTH(8192), .RD_LAT(2), .WRITE_FIRST(1'b0)) u (
    .clka(clka), .clkb(clkb), .addra(addra), .addrb(addrb),
    .dina(dina), .wea(wea), .doutb(doutb));
endmodule


// ---- single-port ROM (.coe-initialized blk_mem_gen Single_Port_ROM) ----
// INIT_FILE is a $readmemh hex file (one word/line), produced from the upstream
// .coe by the harness (coe2mem). Resolved relative to the sim cwd. Read latency
// RD_LAT (2 for these, = one memory-primitive output register).
module aloha_rom_sp #(
    parameter int    W         = 128,
    parameter int    DEPTH     = 512,
    parameter int    RD_LAT    = 2,
    parameter        INIT_FILE = "",
    parameter int    AW        = $clog2(DEPTH)
  )(
    input               clka,
    input  [AW-1:0]     addra,
    output [W-1:0]      douta
  );
  logic [W-1:0] mem [0:DEPTH-1];
  initial if (INIT_FILE != "") $readmemh(INIT_FILE, mem);

  logic [W-1:0] rd_pipe [0:RD_LAT-1];
  integer s;
  always_ff @(posedge clka) begin
    rd_pipe[0] <= mem[addra];
    for (s = 1; s < RD_LAT; s = s + 1)
      rd_pipe[s] <= rd_pipe[s-1];
  end
  assign douta = rd_pipe[RD_LAT-1];
endmodule

// 128b x 512 RNS-constants / cached-twiddle ROM (TwFctrCache_RNSConsts.coe).
module FFTTw_RNS_ROM (
    input          clka,
    input  [8:0]   addra,
    output [127:0] douta
  );
  aloha_rom_sp #(.W(128), .DEPTH(512), .RD_LAT(2),
                 .INIT_FILE("fft_rns_rom.mem")) u (
    .clka(clka), .addra(addra), .douta(douta));
endmodule

// 128b x 4096 stored-FFT-twiddle ROM (FFTStoredTwiddleFactors.coe).
module FFTAllTwiddleROM (
    input          clka,
    input  [11:0]  addra,
    output [127:0] douta
  );
  aloha_rom_sp #(.W(128), .DEPTH(4096), .RD_LAT(2),
                 .INIT_FILE("fft_all_twiddle_rom.mem")) u (
    .clka(clka), .addra(addra), .douta(douta));
endmodule


// ---- instruction RAM (dist_mem_gen Simple_Dual_Port, 42b x 16) ----
// Write port: a/d/we (clk). Read port: dpra -> qdpo, registered once by
// qdpo_clk (C_HAS_QDPO=1, C_REG_DPRA_INPUT=0) => read latency 1 (the
// distributed-RAM read is asynchronous from dpra; qdpo adds one register).
module INS_RAM (
    input         clk,
    input  [3:0]  a,
    input  [41:0] d,
    input         we,
    input  [3:0]  dpra,
    input         qdpo_clk,
    output [41:0] qdpo
  );
  logic [41:0] mem [0:15];
  always_ff @(posedge clk)
    if (we) mem[a] <= d;
  logic [41:0] qdpo_q;
  always_ff @(posedge qdpo_clk)
    qdpo_q <= mem[dpra];   // async DPRA read + qdpo output register => latency 1
  assign qdpo = qdpo_q;
endmodule
