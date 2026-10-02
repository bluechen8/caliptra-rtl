// SPDX-License-Identifier: Apache-2.0
// Behavioral model of the ten-array shared SRAM implementation. Keep masks,
// forwarding and logical read latency identical to Caliptra.scala.
module fhe_aloha_mem_top #(parameter bit PHASED = 0, SRAM_REUSE = 0) (
  input logic clk_i, fhe_aloha_mem_if.resp m
);
  // Retired logical ports have no backing storage.
  assign m.sk_rdata = '0;
  if (SRAM_REUSE) begin : retired
  assign m.ntt_key0_doutb = '0;
  assign m.ntt_key1_doutb = '0;
  assign m.ntt_e1_0_doutb = '0;
  assign m.ntt_e1_1_doutb = '0;
  assign m.e0_douta = '0;
  assign m.e1_douta = '0;
  assign m.vt_douta = '0;
  end else begin : reference_storage
  fhe_shared_bank #(.W(54), .DEPTH(`FHE_N/2), .PHASED(PHASED),
    .FORWARD_MASK('0)) ntt_key0 (
    .clk(clk_i), .rd(m.phase_read), .exec(m.phase_execute), .wr(m.phase_write),
    .we(m.ntt_key0_wea), .wa(m.ntt_key0_addra), .wd(m.ntt_key0_dina), .mask(1'b1),
    .ra(m.ntt_key0_addrb), .q(m.ntt_key0_doutb));
  fhe_shared_bank #(.W(54), .DEPTH(`FHE_N/2), .PHASED(PHASED),
    .FORWARD_MASK('0)) ntt_key1 (
    .clk(clk_i), .rd(m.phase_read), .exec(m.phase_execute), .wr(m.phase_write),
    .we(m.ntt_key1_wea), .wa(m.ntt_key1_addra), .wd(m.ntt_key1_dina), .mask(1'b1),
    .ra(m.ntt_key1_addrb), .q(m.ntt_key1_doutb));
  fhe_shared_bank #(.W(54), .DEPTH(`FHE_N/2), .PHASED(PHASED),
    .FORWARD_MASK('0)) ntt_e1_0 (
    .clk(clk_i), .rd(m.phase_read), .exec(m.phase_execute), .wr(m.phase_write),
    .we(m.ntt_e1_0_wea), .wa(m.ntt_e1_0_addra), .wd(m.ntt_e1_0_dina), .mask(1'b1),
    .ra(m.ntt_e1_0_addrb), .q(m.ntt_e1_0_doutb));
  fhe_shared_bank #(.W(54), .DEPTH(`FHE_N/2), .PHASED(PHASED),
    .FORWARD_MASK('0)) ntt_e1_1 (
    .clk(clk_i), .rd(m.phase_read), .exec(m.phase_execute), .wr(m.phase_write),
    .we(m.ntt_e1_1_wea), .wa(m.ntt_e1_1_addra), .wd(m.ntt_e1_1_dina), .mask(1'b1),
    .ra(m.ntt_e1_1_addrb), .q(m.ntt_e1_1_doutb));
  fhe_shared_bank #(.W(6), .DEPTH(`FHE_N), .PHASED(PHASED),
    .FORWARD_MASK('1)) e0 (
    .clk(clk_i), .rd(m.phase_read), .exec(m.phase_execute), .wr(m.phase_write),
    .we(m.e0_wea), .wa(m.e0_addra), .wd(m.e0_dina), .mask(1'b1),
    .ra(m.e0_addra), .q(m.e0_douta));
  fhe_shared_bank #(.W(6), .DEPTH(`FHE_N), .PHASED(PHASED),
    .FORWARD_MASK('1)) e1 (
    .clk(clk_i), .rd(m.phase_read), .exec(m.phase_execute), .wr(m.phase_write),
    .we(m.e1_wea), .wa(m.e1_addra), .wd(m.e1_dina), .mask(1'b1),
    .ra(m.e1_addra), .q(m.e1_douta));
  fhe_shared_bank #(.W(2), .DEPTH(`FHE_N), .PHASED(PHASED),
    .FORWARD_MASK('1)) vt (
    .clk(clk_i), .rd(m.phase_read), .exec(m.phase_execute), .wr(m.phase_write),
    .we(m.vt_wea), .wa(m.vt_addra), .wd(m.vt_dina), .mask(1'b1),
    .ra(m.vt_addra), .q(m.vt_douta));
  end
  fhe_shared_bank #(.W(64), .DEPTH(`FHE_N/2), .GRAN(8),
    .FORWARD_MASK(64'hff00000000000000), .PHASED(PHASED)) ntt_msg0 (
    .clk(clk_i), .rd(m.phase_read), .exec(m.phase_execute), .wr(m.phase_write),
    .we(m.ntt_msg0_wea), .wa(m.ntt_msg0_addra), .wd(m.ntt_msg0_dina), .mask(m.ntt_msg0_mask),
    .ra(m.ntt_msg0_addrb), .q(m.ntt_msg0_doutb));
  fhe_shared_bank #(.W(64), .DEPTH(`FHE_N/2), .GRAN(8),
    .FORWARD_MASK(64'hff00000000000000), .PHASED(PHASED)) ntt_msg1 (
    .clk(clk_i), .rd(m.phase_read), .exec(m.phase_execute), .wr(m.phase_write),
    .we(m.ntt_msg1_wea), .wa(m.ntt_msg1_addra), .wd(m.ntt_msg1_dina), .mask(m.ntt_msg1_mask),
    .ra(m.ntt_msg1_addrb), .q(m.ntt_msg1_doutb));
  fhe_shared_bank #(.W(54), .DEPTH(`FHE_N*`FHE_L/2), .GRAN(54),
    .FORWARD_MASK(54'd0), .PHASED(PHASED)) ntt_v0 (
    .clk(clk_i), .rd(m.phase_read), .exec(m.phase_execute), .wr(m.phase_write),
    .we(m.ntt_v0_wea), .wa(m.ntt_v0_addra), .wd(m.ntt_v0_dina), .mask(1'b1),
    .ra(m.ntt_v0_addrb), .q(m.ntt_v0_doutb));
  fhe_shared_bank #(.W(54), .DEPTH(`FHE_N*`FHE_L/2), .GRAN(54),
    .FORWARD_MASK(54'd0), .PHASED(PHASED)) ntt_v1 (
    .clk(clk_i), .rd(m.phase_read), .exec(m.phase_execute), .wr(m.phase_write),
    .we(m.ntt_v1_wea), .wa(m.ntt_v1_addra), .wd(m.ntt_v1_dina), .mask(1'b1),
    .ra(m.ntt_v1_addrb), .q(m.ntt_v1_doutb));
  fhe_shared_bank #(.W(64), .DEPTH(`FHE_N/2), .GRAN(64),
    .FORWARD_MASK(64'd0), .PHASED(PHASED)) fft_lower0 (
    .clk(clk_i), .rd(m.phase_read), .exec(m.phase_execute), .wr(m.phase_write),
    .we(m.fft_lower0_wea), .wa(m.fft_lower0_addra), .wd(m.fft_lower0_dina), .mask(1'b1),
    .ra(m.fft_lower0_addrb), .q(m.fft_lower0_doutb));
  fhe_shared_bank #(.W(64), .DEPTH(`FHE_N/2), .GRAN(64),
    .FORWARD_MASK(64'd0), .PHASED(PHASED)) fft_lower1 (
    .clk(clk_i), .rd(m.phase_read), .exec(m.phase_execute), .wr(m.phase_write),
    .we(m.fft_lower1_wea), .wa(m.fft_lower1_addra), .wd(m.fft_lower1_dina), .mask(1'b1),
    .ra(m.fft_lower1_addrb), .q(m.fft_lower1_doutb));
  fhe_shared_bank #(.W(64), .DEPTH(`FHE_N/2), .GRAN(64),
    .FORWARD_MASK({64{1'b1}}), .PHASED(PHASED)) fft_higher0 (
    .clk(clk_i), .rd(m.phase_read), .exec(m.phase_execute), .wr(m.phase_write),
    .we(m.fft_higher0_wea), .wa(m.fft_higher0_addra), .wd(m.fft_higher0_dina), .mask(1'b1),
    .ra(m.fft_higher0_addrb), .q(m.fft_higher0_doutb));
  fhe_shared_bank #(.W(64), .DEPTH(`FHE_N/2), .GRAN(64),
    .FORWARD_MASK({64{1'b1}}), .PHASED(PHASED)) fft_higher1 (
    .clk(clk_i), .rd(m.phase_read), .exec(m.phase_execute), .wr(m.phase_write),
    .we(m.fft_higher1_wea), .wa(m.fft_higher1_addra), .wd(m.fft_higher1_dina), .mask(1'b1),
    .ra(m.fft_higher1_addrb), .q(m.fft_higher1_doutb));
  fhe_shared_bank #(.W(128), .DEPTH(512), .PHASED(PHASED), .INIT_FILE("fft_rns_rom.mem")) crom (
    .clk(clk_i), .rd(m.phase_read), .exec(m.phase_execute), .wr(m.phase_write),
    .we(1'b0), .wa('0), .wd('0), .mask(1'b1), .ra(m.crom_addra), .q(m.crom_douta));
  fhe_shared_bank #(.W(128), .DEPTH(`FHE_N/2), .PHASED(PHASED), .INIT_FILE("fft_all_twiddle_rom.mem")) ftwrom (
    .clk(clk_i), .rd(m.phase_read), .exec(m.phase_execute), .wr(m.phase_write),
    .we(1'b0), .wa('0), .wd('0), .mask(1'b1), .ra(m.ftwrom_addra), .q(m.ftwrom_douta));
endmodule

module fhe_shared_bank #(
  parameter int W=64, DEPTH=4096, AW=$clog2(DEPTH), GRAN=W,
  parameter bit PHASED=1,
  parameter logic [W-1:0] FORWARD_MASK='0,
  parameter INIT_FILE=""
)(
  input logic clk,rd,exec,wr,we,
  input logic [AW-1:0] wa,ra,
  input logic [W-1:0] wd,
  input logic [W/GRAN-1:0] mask,
  output logic [W-1:0] q
);
  logic [W-1:0] mem [0:DEPTH-1];
  logic [W-1:0] raw,stage0,saved_data,forwarded;
  logic [W/GRAN-1:0] saved_mask;
  logic [AW-1:0] saved_addr;
  logic saved_we,collide;
  initial if (INIT_FILE != "") $readmemh(INIT_FILE,mem);
  always_comb begin
    forwarded=raw;
    for (int b=0;b<W;b++)
      if (collide && saved_mask[b/GRAN] && FORWARD_MASK[b]) forwarded[b]=saved_data[b];
  end
  if (PHASED) begin : phased
    always_ff @(posedge clk) begin
      assert ($onehot0({rd,exec,wr})) else $fatal(1,"overlapping SRAM phases");
      if (rd) begin
        raw<=mem[ra]; saved_we<=we; saved_addr<=wa;
        saved_data<=wd; saved_mask<=mask; collide<=we && ra==wa;
      end else if (wr && saved_we) begin
        for (int b=0;b<W/GRAN;b++)
          if(saved_mask[b]) mem[saved_addr][b*GRAN+:GRAN]<=saved_data[b*GRAN+:GRAN];
      end
      if (exec) begin stage0<=forwarded; q<=stage0; end
    end
  end else begin : logical_clock
    always_ff @(posedge clk) begin
      for (int b=0;b<W;b++)
        stage0[b]<=we && wa==ra && mask[b/GRAN] && FORWARD_MASK[b] ? wd[b] : mem[ra][b];
      q<=stage0;
      if(we) for(int b=0;b<W/GRAN;b++)
        if(mask[b]) mem[wa][b*GRAN+:GRAN]<=wd[b*GRAN+:GRAN];
    end
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
