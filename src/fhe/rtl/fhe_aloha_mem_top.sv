// SPDX-License-Identifier: Apache-2.0
// Behavioral model of the shared SRAM implementation. With ILV=1 each working
// array is fhe_ilv_bank over four 1RW sub-banks, exactly as Caliptra.scala
// builds it, and the arrays stall the engine through eng_stall. ILV=0 is an
// ideal one-read/one-write memory that never stalls, for the standalone core
// sims whose engine runs every clock. CROM_INIT preloads the CROM for those
// sims; integrated benches write the table through the CROM write port, as
// firmware does.
module fhe_aloha_mem_top #(parameter bit ILV = 0, SRAM_REUSE = 0, parameter CROM_INIT = "") (
  input logic clk_i, fhe_aloha_mem_if.resp m
);
  localparam int SDP_AW = $clog2(`FHE_N) - 1;

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
  fhe_shared_bank #(.W(54), .DEPTH(`FHE_N/2)) ntt_key0 (
    .clk(clk_i), .we(m.ntt_key0_wea), .wa(m.ntt_key0_addra), .wd(m.ntt_key0_dina), .mask(1'b1),
    .ra(m.ntt_key0_addrb), .q(m.ntt_key0_doutb));
  fhe_shared_bank #(.W(54), .DEPTH(`FHE_N/2)) ntt_key1 (
    .clk(clk_i), .we(m.ntt_key1_wea), .wa(m.ntt_key1_addra), .wd(m.ntt_key1_dina), .mask(1'b1),
    .ra(m.ntt_key1_addrb), .q(m.ntt_key1_doutb));
  fhe_shared_bank #(.W(54), .DEPTH(`FHE_N/2)) ntt_e1_0 (
    .clk(clk_i), .we(m.ntt_e1_0_wea), .wa(m.ntt_e1_0_addra), .wd(m.ntt_e1_0_dina), .mask(1'b1),
    .ra(m.ntt_e1_0_addrb), .q(m.ntt_e1_0_doutb));
  fhe_shared_bank #(.W(54), .DEPTH(`FHE_N/2)) ntt_e1_1 (
    .clk(clk_i), .we(m.ntt_e1_1_wea), .wa(m.ntt_e1_1_addra), .wd(m.ntt_e1_1_dina), .mask(1'b1),
    .ra(m.ntt_e1_1_addrb), .q(m.ntt_e1_1_doutb));
  fhe_shared_bank #(.W(6), .DEPTH(`FHE_N), .FORWARD_MASK('1)) e0 (
    .clk(clk_i), .we(m.e0_wea), .wa(m.e0_addra), .wd(m.e0_dina), .mask(1'b1),
    .ra(m.e0_addra), .q(m.e0_douta));
  fhe_shared_bank #(.W(6), .DEPTH(`FHE_N), .FORWARD_MASK('1)) e1 (
    .clk(clk_i), .we(m.e1_wea), .wa(m.e1_addra), .wd(m.e1_dina), .mask(1'b1),
    .ra(m.e1_addra), .q(m.e1_douta));
  fhe_shared_bank #(.W(2), .DEPTH(`FHE_N), .FORWARD_MASK('1)) vt (
    .clk(clk_i), .we(m.vt_wea), .wa(m.vt_addra), .wd(m.vt_dina), .mask(1'b1),
    .ra(m.vt_addra), .q(m.vt_douta));
  end

  // The eight working arrays: {M, K, A, R} x parity.
  logic [7:0] stall;
  assign m.eng_stall = |stall;
  `define FHE_WORKING_ARRAY(_i, _sig, _W, _AW, _GRAN, _FWD, _mask) \
    fhe_working_array #(.ILV(ILV), .W(_W), .AW(_AW), .GRAN(_GRAN), .FORWARD_MASK(_FWD)) _sig ( \
      .clk(clk_i), .step(m.eng_step), .stall(stall[_i]), \
      .we(m.``_sig``_wea), .wa(m.``_sig``_addra), .wd(m.``_sig``_dina), .mask(_mask), \
      .ra(m.``_sig``_addrb), .q(m.``_sig``_doutb));
  `FHE_WORKING_ARRAY(0, ntt_msg0,    64, SDP_AW, 8,  64'hff00000000000000, m.ntt_msg0_mask)
  `FHE_WORKING_ARRAY(1, ntt_msg1,    64, SDP_AW, 8,  64'hff00000000000000, m.ntt_msg1_mask)
  `FHE_WORKING_ARRAY(2, ntt_v0,      64, SDP_AW, 8,  64'hff00000000000000, m.ntt_v0_mask)
  `FHE_WORKING_ARRAY(3, ntt_v1,      64, SDP_AW, 8,  64'hff00000000000000, m.ntt_v1_mask)
  `FHE_WORKING_ARRAY(4, fft_lower0,  64, SDP_AW, 64, 64'd0,                1'b1)
  `FHE_WORKING_ARRAY(5, fft_lower1,  64, SDP_AW, 64, 64'd0,                1'b1)
  `FHE_WORKING_ARRAY(6, fft_higher0, 64, SDP_AW, 64, {64{1'b1}},           1'b1)
  `FHE_WORKING_ARRAY(7, fft_higher1, 64, SDP_AW, 64, {64{1'b1}},           1'b1)
  `undef FHE_WORKING_ARRAY

  fhe_table_bank #(.DEPTH(1 << `FHE_CROM_AW), .INIT_FILE(CROM_INIT)) crom (
    .clk(clk_i), .step(m.eng_step),
    .we(m.crom_wea), .wa(m.crom_wa), .wd(m.crom_wd), .ra(m.crom_addra), .q(m.crom_douta));
endmodule

// One working array: fhe_ilv_bank over four 1RW sub-banks (ILV), or the ideal
// one-read/one-write model.
module fhe_working_array #(
  parameter bit ILV = 1,
  parameter int W = 64, AW = 12, GRAN = W,
  parameter logic [W-1:0] FORWARD_MASK = '0
)(
  input logic clk, step,
  output logic stall,
  input logic we,
  input logic [AW-1:0] wa, ra,
  input logic [W-1:0] wd,
  input logic [W/GRAN-1:0] mask,
  output logic [W-1:0] q
);
  localparam int MW = W / GRAN, SAW = AW - 2;
  // Logical contents, for testbench peeks (u_aloha_mem.<array>.mem[row]).
  logic [W-1:0] mem [0:(1 << AW)-1];
  initial for (int i = 0; i < (1 << AW); i++) mem[i] = '0;
  always_ff @(posedge clk) if ((ILV ? step : 1'b1) && we)
    for (int b = 0; b < MW; b++) if (mask[b]) mem[wa][b*GRAN +: GRAN] <= wd[b*GRAN +: GRAN];
  if (ILV) begin : ilv
    logic [3:0] en, sbwe;
    logic [4*SAW-1:0] addr;
    logic [4*W-1:0] wdata, rdata;
    logic [4*MW-1:0] wmask;
    logic rst_n = 1'b0;
    logic [AW-1:0] chk = '0;               // row the consistency sweep checks
    logic [W-1:0] peek [4];
    always @(posedge clk) rst_n <= 1'b1;
    fhe_ilv_bank #(.W(W), .AW(AW), .GRAN(GRAN)) bank (
      .clk, .rst_n, .forward(FORWARD_MASK), .step, .stall, .we, .wa, .wd, .mask, .ra, .q,
      .sb_en(en), .sb_we(sbwe), .sb_addr(addr), .sb_wdata(wdata), .sb_mask(wmask), .sb_rdata(rdata));
    for (genvar s = 0; s < 4; s++) begin : sub
      logic [W-1:0] mem [0:(1 << SAW)-1];
      initial for (int i = 0; i < (1 << SAW); i++) mem[i] = '0;
      always_ff @(posedge clk) if (en[s]) begin
        if (sbwe[s]) begin
          for (int b = 0; b < MW; b++)
            if (wmask[s*MW + b]) mem[addr[s*SAW +: SAW]][b*GRAN +: GRAN] <= wdata[s*W + b*GRAN +: GRAN];
        end else rdata[s*W +: W] <= mem[addr[s*SAW +: SAW]];
      end
      assign peek[s] = mem[chk[AW-1:2]];
    end
    // Sweep one row per clock: sub-bank contents plus the write buffer must
    // equal the logical contents.
    logic [1:0] chk_sub;
    logic [W-1:0] chk_got;
    always_comb begin
      chk_sub = '0;
      for (int i = 0; i < AW; i += 2) chk_sub ^= 2'(chk >> i);
      chk_got = peek[chk_sub];
      if (bank.bv && bank.ba == chk)
        for (int b = 0; b < MW; b++) if (bank.bm[b]) chk_got[b*GRAN +: GRAN] = bank.bd[b*GRAN +: GRAN];
    end
    always @(posedge clk) begin
      if (rst_n) assert (chk_got == mem[chk])
        else $fatal(1, "%m: row %0d holds %h, expected %h", chk, chk_got, mem[chk]);
      chk <= chk + 1'b1;
    end
  end else begin : ideal
    assign stall = 1'b0;
    fhe_shared_bank #(.W(W), .DEPTH(1 << AW), .GRAN(GRAN), .FORWARD_MASK(FORWARD_MASK)) bank (
      .clk, .we, .wa, .wd, .mask, .ra, .q);
  end
endmodule

// Ideal one-read/one-write array with a two-clock read; FORWARD_MASK bits of a
// same-address write reach that clock's read.
module fhe_shared_bank #(
  parameter int W=64, DEPTH=4096, AW=$clog2(DEPTH), GRAN=W,
  parameter logic [W-1:0] FORWARD_MASK='0
)(
  input logic clk, we,
  input logic [AW-1:0] wa,ra,
  input logic [W-1:0] wd,
  input logic [W/GRAN-1:0] mask,
  output logic [W-1:0] q
);
  logic [W-1:0] mem [0:DEPTH-1];
  logic [W-1:0] stage0;
  always_ff @(posedge clk) begin
    for (int b=0;b<W;b++)
      stage0[b]<=we && wa==ra && mask[b/GRAN] && FORWARD_MASK[b] ? wd[b] : mem[ra][b];
    q<=stage0;
    if(we) for(int b=0;b<W/GRAN;b++)
      if(mask[b]) mem[wa][b*GRAN+:GRAN]<=wd[b*GRAN+:GRAN];
  end
endmodule

// CROM: one 1RW array, read every step. A table write (engine idle) takes the
// port on any edge; the read data reaches q on the next step, like the working
// arrays. Caliptra.scala builds the same pipeline.
module fhe_table_bank #(
  parameter int DEPTH = 256, AW = $clog2(DEPTH),
  parameter INIT_FILE = ""
)(
  input logic clk, step, we,
  input logic [AW-1:0] wa, ra,
  input logic [127:0] wd,
  output logic [127:0] q
);
  logic [127:0] mem [0:DEPTH-1];
  logic [127:0] raw, stage0;
  logic fresh = 1'b0;
  initial if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
  always_ff @(posedge clk) begin
    if (we) mem[wa] <= wd;
    if (step && !we) raw <= mem[ra];
    fresh <= step && !we;
    if (fresh) stage0 <= raw;
    if (step) q <= fresh ? raw : stage0;
  end
endmodule
