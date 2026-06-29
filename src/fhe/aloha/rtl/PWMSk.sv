`timescale 1ns / 1ps
`include "CommonDefinitions.vh"

// PWMSk -- secret-key-scheme specialization of Aloha-HE's PWM (Rung 6c).
//
// The generic vendor PWM computes BOTH ciphertext lanes every call (two NTT
// butterflies). The secret-key CKKS scheme needs ONE multiply lane plus a
// passthrough, with the resident secret as the multiplicand:
//   ENCRYPT:  c0 = -(s*a) + (m+e0) ,  c1 = a
//   DECRYPT:  m  =  c0 + (s*c1)
// Operand convention (sk RESIDENT in NTT_V; no internal data shuffles):
//   * a-operand (multiplicand) = NTT_V = sk            (resident, both ops)
//   * b-operand (multiplier)   = enc ? FFT_IM : NTT_KEY
//        encrypt: the fresh uniform a, read straight from FFT_IM where the
//                 sampler writes it (so NO FFT_IM->NTT_V driver move);
//        decrypt: the loaded ciphertext c1 in NTT_KEY.
//   * c-operand (addend)       = NTT_MSG = (m+e0) / c0
//   * result0 = c0 + MontMul(sk, b_eff)  -> NTT_MSG     (BF0 only; BF1 freed)
//        b_eff = negate ? (q - b) : b   -- the negate-b-operand fold; encrypt
//        sets negate to form -(s*a) (q-b == -b mod q; q-0 special-cased).
//   * result1 = b (raw, un-negated) -> NTT_KEY          (c1 = a passthrough)
// q is reconstructed from the Solinas q_m/current_k (== the positive modulus,
// bit-exact vs q0; see RandomSampling.sv:110). Pipeline latencies mirror PWM
// exactly, so it is a drop-in within ComputeCore's pwm_rst-gated datapath.
(* keep_hierarchy = `KEEP_HIERARCHY *)
module PWMSk #(
    parameter LOGQ = 54,
    parameter LOGN = 13,
    parameter W = 24,
    parameter M = 17
  )
  (
    input clk,
    input rst,

    input [M-1:0] q_m,
    input [3:0] current_k,

    // negate the b operand: result0 = c0 + MontMul(sk, q - b). Instruction flag,
    // static for the op.
    input negate,
    // encrypt: take the multiplier b from FFT_IM (the freshly-sampled uniform a);
    // decrypt: take b from NTT_KEY (the loaded c1).
    input enc,

    // a bram read port (NTT_V): resident sk (multiplicand), both encrypt+decrypt:
    output [LOGN-1:0] a_bram_rd_addr,
    input  [LOGQ-1:0] a_bram_rd_data,

    // b bram read port: b0 = NTT_KEY (c1 on decrypt), b1 = FFT_IM (uniform a on
    // encrypt). Both are addressed by b_bram_rd_addr (ComputeCore routes that to
    // the FFT_IM "Imag BRAM" read port during PWM, as the pk PWM did for b1).
    output [LOGN-1:0] b_bram_rd_addr,
    input  [LOGQ-1:0] b0_bram_rd_data, // NTT_KEY  (c1)
    input  [LOGQ-1:0] b1_bram_rd_data, // FFT_IM   (uniform a)

    // c bram read port (NTT_MSG: m+e0 on encrypt / c0 on decrypt):
    output [LOGN-1:0] c_bram_rd_addr,
    input  [LOGQ-1:0] c0_bram_rd_data,

    // result bram write port:
    output [LOGN-1:0] result_bram_wr_addr,
    output [LOGQ-1:0] result0_bram_wr_data, // C0 / m
    output [LOGQ-1:0] result1_bram_wr_data, // C1 = a (passthrough)
    output result_bram_wea,

    // connect to NTT BF 0 (the single multiply lane):
    output [LOGQ-1:0] pwm_bf0_ina,
    output [LOGQ-1:0] pwm_bf0_inb,
    output [LOGQ-1:0] pwm_bf0_tw,
    input  [LOGQ-1:0] pwm_bf0_result,

    output done
  );

  localparam MODMUL_LAT = 15;
  localparam MODADD_LAT = 2;
  localparam BRAM_RD_LAT = 2;

  //////////// address generation (identical to PWM) //////////
  logic [LOGN-1:0] read_addr_DP;
  logic done_internal;
  always_ff @(posedge clk) begin
    if(rst)
      read_addr_DP <= 0;
    else if(~done_internal)
      read_addr_DP <= read_addr_DP + 1;
  end
  assign a_bram_rd_addr = read_addr_DP;
  assign b_bram_rd_addr = read_addr_DP;
  assign done_internal = read_addr_DP == {LOGN{1'b1}}; // last coefficient = N-1
  DelayRegister #(.CYCLE_COUNT(MODMUL_LAT), .BITWIDTH(LOGN)) c_rd_addr_delay (.clk(clk), .in(read_addr_DP), .out(c_bram_rd_addr));
  DelayRegister #(.CYCLE_COUNT(MODMUL_LAT+BRAM_RD_LAT+MODADD_LAT), .BITWIDTH(LOGN)) result_wr_addr_delay (.clk(clk), .in(read_addr_DP), .out(result_bram_wr_addr));
  DelayRegisterReset #(.CYCLE_COUNT(MODMUL_LAT+BRAM_RD_LAT+MODADD_LAT), .BITWIDTH(1)) wea_delay (.clk(clk), .rst(rst), .in(~rst), .out(result_bram_wea));
  DelayRegisterReset #(.CYCLE_COUNT(MODMUL_LAT+BRAM_RD_LAT+MODADD_LAT), .BITWIDTH(1)) done_delay (.clk(clk), .rst(rst), .in(done_internal), .out(done));

  //////////// b-operand select + negate fold //////////
  // b = enc ? FFT_IM(a) : NTT_KEY(c1).  b_eff = negate ? (q - b) : b.
  // q reconstructed from the Solinas fields (== positive modulus, q-0 == 0).
  logic [LOGQ-1:0] q_recon, b_sel, b_eff;
  assign q_recon = {(13'h1fff >> (8-current_k)), q_m, {(W-1){1'b0}}, 1'b1};
  assign b_sel   = enc ? b1_bram_rd_data : b0_bram_rd_data;
  assign b_eff   = ~negate ? b_sel
                           : (b_sel == {LOGQ{1'b0}} ? {LOGQ{1'b0}} : (q_recon - b_sel));

  //////////// single multiply-add lane (BF0): result0 = c0 + sk*b_eff //////////
  assign pwm_bf0_ina = c0_bram_rd_data;
  assign pwm_bf0_inb = a_bram_rd_data;   // sk (resident multiplicand)
  assign pwm_bf0_tw  = b_eff;            // a (encrypt) / c1 (decrypt), negate-folded
  assign result0_bram_wr_data = pwm_bf0_result;

  //////////// c1 = b passthrough (the un-negated multiplier = a on encrypt) //////
  // Align with the result write address: BF0 result lags read_addr by
  // MODMUL+BRAM_RD+MODADD; b_sel already lags by BRAM_RD, so delay it by the
  // remaining MODMUL+MODADD to land on the same write slot.
  DelayRegister #(.CYCLE_COUNT(MODMUL_LAT+MODADD_LAT), .BITWIDTH(LOGQ))
    b_passthrough_delay (.clk(clk), .in(b_sel), .out(result1_bram_wr_data));

endmodule
