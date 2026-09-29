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
//   C'-3 SRAM-macro routing. Instantiates the Aloha-HE ComputeCore storage
//   banks (the aloha_bram_behav.sv named wrappers) against a fhe_aloha_mem_if
//   that has been lifted out of ComputeCore. Mirrors abr_mem_top / fhe_mem_top.
//   Instantiated in the standalone Aloha TBs (so the original datapath keeps
//   its exact 2-cycle-latency / collision behavior) and in CaliptraCoreBlackbox
//   for the SoC. The Chisel SyncReadMem lift replaces THIS module's storage in
//   the synthesizable path; this behavioral version is the functional model.
//
//   This behavioral model instantiates ALL banks unconditionally. The SCHEME==1
//   storage drops (ntt_e1, e1_bram -- C'-3 Part 1) are FUNCTIONAL no-ops here
//   (ComputeCore ties their request side off), so the area win is realized only
//   in the synthesizable path -- the Chisel SyncReadMem omits those banks under
//   SCHEME==1. Modelling them here is harmless and keeps this module scheme-agnostic.

module fhe_aloha_mem_top #(parameter bit PHASED = 0) (
    input logic clk_i,
    fhe_aloha_mem_if.resp m
  );

  // Same one-cycle SRAM contract as the Chisel single-port memory.
  logic [53:0] sk_mem [0:`FHE_N*`FHE_L-1];
  always_ff @(posedge clk_i) begin
    if (m.sk_en) begin
      if (m.sk_we) sk_mem[m.sk_addr] <= m.sk_wdata;
      else m.sk_rdata <= sk_mem[m.sk_addr];
    end
  end

  if (!PHASED) begin : legacy
  // ---- 8x NTTPolyBank (54b x 4096, simple-dual-port, READ_FIRST) ----
  NTTPolyBank ntt_msg_bank0 (.clka(clk_i), .clkb(clk_i),
    .addra(m.ntt_msg0_addra), .addrb(m.ntt_msg0_addrb),
    .dina(m.ntt_msg0_dina), .doutb(m.ntt_msg0_doutb), .wea(m.ntt_msg0_wea));
  NTTPolyBank ntt_msg_bank1 (.clka(clk_i), .clkb(clk_i),
    .addra(m.ntt_msg1_addra), .addrb(m.ntt_msg1_addrb),
    .dina(m.ntt_msg1_dina), .doutb(m.ntt_msg1_doutb), .wea(m.ntt_msg1_wea));

  NTTPolyBank ntt_v_bank0 (.clka(clk_i), .clkb(clk_i),
    .addra(m.ntt_v0_addra), .addrb(m.ntt_v0_addrb),
    .dina(m.ntt_v0_dina), .doutb(m.ntt_v0_doutb), .wea(m.ntt_v0_wea));
  NTTPolyBank ntt_v_bank1 (.clka(clk_i), .clkb(clk_i),
    .addra(m.ntt_v1_addra), .addrb(m.ntt_v1_addrb),
    .dina(m.ntt_v1_dina), .doutb(m.ntt_v1_doutb), .wea(m.ntt_v1_wea));

  NTTPolyBank ntt_e1_bank0 (.clka(clk_i), .clkb(clk_i),
    .addra(m.ntt_e1_0_addra), .addrb(m.ntt_e1_0_addrb),
    .dina(m.ntt_e1_0_dina), .doutb(m.ntt_e1_0_doutb), .wea(m.ntt_e1_0_wea));
  NTTPolyBank ntt_e1_bank1 (.clka(clk_i), .clkb(clk_i),
    .addra(m.ntt_e1_1_addra), .addrb(m.ntt_e1_1_addrb),
    .dina(m.ntt_e1_1_dina), .doutb(m.ntt_e1_1_doutb), .wea(m.ntt_e1_1_wea));

  NTTPolyBank ntt_key_bank0 (.clka(clk_i), .clkb(clk_i),
    .addra(m.ntt_key0_addra), .addrb(m.ntt_key0_addrb),
    .dina(m.ntt_key0_dina), .doutb(m.ntt_key0_doutb), .wea(m.ntt_key0_wea));
  NTTPolyBank ntt_key_bank1 (.clka(clk_i), .clkb(clk_i),
    .addra(m.ntt_key1_addra), .addrb(m.ntt_key1_addrb),
    .dina(m.ntt_key1_dina), .doutb(m.ntt_key1_doutb), .wea(m.ntt_key1_wea));

  // ---- 4x SharedFFTBrams working banks (lifted from SharedFFTBrams.sv) ----
  //      2x lower (54b NTTPolyBank, READ_FIRST) + 2x higher (74b SharedFFTBramBank)
  NTTPolyBank fft_lower_bank0 (.clka(clk_i), .clkb(clk_i),
    .addra(m.fft_lower0_addra), .addrb(m.fft_lower0_addrb),
    .dina(m.fft_lower0_dina), .doutb(m.fft_lower0_doutb), .wea(m.fft_lower0_wea));
  NTTPolyBank fft_lower_bank1 (.clka(clk_i), .clkb(clk_i),
    .addra(m.fft_lower1_addra), .addrb(m.fft_lower1_addrb),
    .dina(m.fft_lower1_dina), .doutb(m.fft_lower1_doutb), .wea(m.fft_lower1_wea));
  SharedFFTBramBank fft_higher_bank0 (.clka(clk_i), .clkb(clk_i),
    .addra(m.fft_higher0_addra), .addrb(m.fft_higher0_addrb),
    .dina(m.fft_higher0_dina), .doutb(m.fft_higher0_doutb), .wea(m.fft_higher0_wea));
  SharedFFTBramBank fft_higher_bank1 (.clka(clk_i), .clkb(clk_i),
    .addra(m.fft_higher1_addra), .addrb(m.fft_higher1_addrb),
    .dina(m.fft_higher1_dina), .doutb(m.fft_higher1_doutb), .wea(m.fft_higher1_wea));

  // ---- 2x CBDPolyBRAM (6b) + 1x TernaryPolyBRAM (2b), single-port ----
  CBDPolyBRAM e0_bram (.clka(clk_i), .addra(m.e0_addra),
    .dina(m.e0_dina), .douta(m.e0_douta), .wea(m.e0_wea));
  CBDPolyBRAM e1_bram (.clka(clk_i), .addra(m.e1_addra),
    .dina(m.e1_dina), .douta(m.e1_douta), .wea(m.e1_wea));
  TernaryPolyBRAM v_bram (.clka(clk_i), .addra(m.vt_addra),
    .dina(m.vt_dina), .douta(m.vt_douta), .wea(m.vt_wea));

  // ---- FFTTw_RNS_ROM (128b x 512, read-only; $readmemh cwd-relative) ----
  FFTTw_RNS_ROM constants_rom (.clka(clk_i), .addra(m.crom_addra), .douta(m.crom_douta));

  // ---- FFTAllTwiddleROM (128b x 4096, read-only; stored FFT twiddles) ----
  FFTAllTwiddleROM all_twiddle_rom (.clka(clk_i), .addra(m.ftwrom_addra), .douta(m.ftwrom_douta));

  end else begin : phased
    fhe_phase_bank #(.W(54), .DEPTH(`FHE_N/2), .WRITE_FIRST(0)) ntt_msg0 (
      .clk(clk_i), .rd(m.phase_read), .exec(m.phase_execute), .wr(m.phase_write),
      .we(m.ntt_msg0_wea), .wa(m.ntt_msg0_addra), .wd(m.ntt_msg0_dina),
      .ra(m.ntt_msg0_addrb), .q(m.ntt_msg0_doutb));
    fhe_phase_bank #(.W(54), .DEPTH(`FHE_N/2), .WRITE_FIRST(0)) ntt_msg1 (
      .clk(clk_i), .rd(m.phase_read), .exec(m.phase_execute), .wr(m.phase_write),
      .we(m.ntt_msg1_wea), .wa(m.ntt_msg1_addra), .wd(m.ntt_msg1_dina),
      .ra(m.ntt_msg1_addrb), .q(m.ntt_msg1_doutb));
    fhe_phase_bank #(.W(54), .DEPTH(`FHE_N/2), .WRITE_FIRST(0)) ntt_v0 (
      .clk(clk_i), .rd(m.phase_read), .exec(m.phase_execute), .wr(m.phase_write),
      .we(m.ntt_v0_wea), .wa(m.ntt_v0_addra), .wd(m.ntt_v0_dina),
      .ra(m.ntt_v0_addrb), .q(m.ntt_v0_doutb));
    fhe_phase_bank #(.W(54), .DEPTH(`FHE_N/2), .WRITE_FIRST(0)) ntt_v1 (
      .clk(clk_i), .rd(m.phase_read), .exec(m.phase_execute), .wr(m.phase_write),
      .we(m.ntt_v1_wea), .wa(m.ntt_v1_addra), .wd(m.ntt_v1_dina),
      .ra(m.ntt_v1_addrb), .q(m.ntt_v1_doutb));
    fhe_phase_bank #(.W(54), .DEPTH(`FHE_N/2), .WRITE_FIRST(0)) ntt_key0 (
      .clk(clk_i), .rd(m.phase_read), .exec(m.phase_execute), .wr(m.phase_write),
      .we(m.ntt_key0_wea), .wa(m.ntt_key0_addra), .wd(m.ntt_key0_dina),
      .ra(m.ntt_key0_addrb), .q(m.ntt_key0_doutb));
    fhe_phase_bank #(.W(54), .DEPTH(`FHE_N/2), .WRITE_FIRST(0)) ntt_key1 (
      .clk(clk_i), .rd(m.phase_read), .exec(m.phase_execute), .wr(m.phase_write),
      .we(m.ntt_key1_wea), .wa(m.ntt_key1_addra), .wd(m.ntt_key1_dina),
      .ra(m.ntt_key1_addrb), .q(m.ntt_key1_doutb));
    fhe_phase_bank #(.W(54), .DEPTH(`FHE_N/2), .WRITE_FIRST(0)) ntt_e1_0 (
      .clk(clk_i), .rd(m.phase_read), .exec(m.phase_execute), .wr(m.phase_write),
      .we(m.ntt_e1_0_wea), .wa(m.ntt_e1_0_addra), .wd(m.ntt_e1_0_dina),
      .ra(m.ntt_e1_0_addrb), .q(m.ntt_e1_0_doutb));
    fhe_phase_bank #(.W(54), .DEPTH(`FHE_N/2), .WRITE_FIRST(0)) ntt_e1_1 (
      .clk(clk_i), .rd(m.phase_read), .exec(m.phase_execute), .wr(m.phase_write),
      .we(m.ntt_e1_1_wea), .wa(m.ntt_e1_1_addra), .wd(m.ntt_e1_1_dina),
      .ra(m.ntt_e1_1_addrb), .q(m.ntt_e1_1_doutb));
    fhe_phase_bank #(.W(54), .DEPTH(`FHE_N/2), .WRITE_FIRST(0)) fft_lower0 (
      .clk(clk_i), .rd(m.phase_read), .exec(m.phase_execute), .wr(m.phase_write),
      .we(m.fft_lower0_wea), .wa(m.fft_lower0_addra), .wd(m.fft_lower0_dina),
      .ra(m.fft_lower0_addrb), .q(m.fft_lower0_doutb));
    fhe_phase_bank #(.W(54), .DEPTH(`FHE_N/2), .WRITE_FIRST(0)) fft_lower1 (
      .clk(clk_i), .rd(m.phase_read), .exec(m.phase_execute), .wr(m.phase_write),
      .we(m.fft_lower1_wea), .wa(m.fft_lower1_addra), .wd(m.fft_lower1_dina),
      .ra(m.fft_lower1_addrb), .q(m.fft_lower1_doutb));
    fhe_phase_bank #(.W(74), .DEPTH(`FHE_N/2), .WRITE_FIRST(1)) fft_higher0 (
      .clk(clk_i), .rd(m.phase_read), .exec(m.phase_execute), .wr(m.phase_write),
      .we(m.fft_higher0_wea), .wa(m.fft_higher0_addra), .wd(m.fft_higher0_dina),
      .ra(m.fft_higher0_addrb), .q(m.fft_higher0_doutb));
    fhe_phase_bank #(.W(74), .DEPTH(`FHE_N/2), .WRITE_FIRST(1)) fft_higher1 (
      .clk(clk_i), .rd(m.phase_read), .exec(m.phase_execute), .wr(m.phase_write),
      .we(m.fft_higher1_wea), .wa(m.fft_higher1_addra), .wd(m.fft_higher1_dina),
      .ra(m.fft_higher1_addrb), .q(m.fft_higher1_doutb));
    fhe_phase_bank #(.W(6), .DEPTH(`FHE_N), .WRITE_FIRST(1)) e0 (
      .clk(clk_i), .rd(m.phase_read), .exec(m.phase_execute), .wr(m.phase_write),
      .we(m.e0_wea), .wa(m.e0_addra), .wd(m.e0_dina),
      .ra(m.e0_addra), .q(m.e0_douta));
    fhe_phase_bank #(.W(6), .DEPTH(`FHE_N), .WRITE_FIRST(1)) e1 (
      .clk(clk_i), .rd(m.phase_read), .exec(m.phase_execute), .wr(m.phase_write),
      .we(m.e1_wea), .wa(m.e1_addra), .wd(m.e1_dina),
      .ra(m.e1_addra), .q(m.e1_douta));
    fhe_phase_bank #(.W(2), .DEPTH(`FHE_N), .WRITE_FIRST(1)) vt (
      .clk(clk_i), .rd(m.phase_read), .exec(m.phase_execute), .wr(m.phase_write),
      .we(m.vt_wea), .wa(m.vt_addra), .wd(m.vt_dina),
      .ra(m.vt_addra), .q(m.vt_douta));
    fhe_phase_bank #(.W(128), .DEPTH(512), .INIT_FILE("fft_rns_rom.mem")) crom (
      .clk(clk_i), .rd(m.phase_read), .exec(m.phase_execute), .wr(m.phase_write),
      .we(1'b0), .wa('0), .wd('0), .ra(m.crom_addra), .q(m.crom_douta));
    fhe_phase_bank #(.W(128), .DEPTH(`FHE_N/2), .INIT_FILE("fft_all_twiddle_rom.mem")) ftwrom (
      .clk(clk_i), .rd(m.phase_read), .exec(m.phase_execute), .wr(m.phase_write),
      .we(1'b0), .wa('0), .wd('0), .ra(m.ftwrom_addra), .q(m.ftwrom_douta));
  end
endmodule

// Behavioral equivalent of the phased Chisel 1RW connection. The array has
// exactly one access per edge. READ_FIRST samples before the deferred write;
// WRITE_FIRST forwards the saved write for a matching read address.
module fhe_phase_bank #(
  parameter int W = 54, DEPTH = 4096, AW = $clog2(DEPTH),
  parameter bit WRITE_FIRST = 0,
  parameter INIT_FILE = ""
) (
  input logic clk, rd, exec, wr, we,
  input logic [AW-1:0] wa, ra,
  input logic [W-1:0] wd,
  output logic [W-1:0] q
);
  logic [W-1:0] mem [0:DEPTH-1];
  logic [W-1:0] raw, stage0, saved_data;
  logic [AW-1:0] saved_addr;
  logic saved_we, collide;
  initial if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
  always_ff @(posedge clk) begin
    assert ($onehot0({rd, exec, wr})) else $fatal(1, "overlapping SRAM phases");
    if (rd) begin
      raw <= mem[ra];
      saved_we <= we;
      saved_addr <= wa;
      saved_data <= wd;
      collide <= we && (ra == wa);
    end else if (wr && saved_we) mem[saved_addr] <= saved_data;
    if (exec) begin
      stage0 <= WRITE_FIRST && collide ? saved_data : raw;
      q <= stage0;
    end
  end
endmodule
