// aloha_dsp_behav.sv
// -----------------------------------------------------------------------------
// Latency-accurate, technology-generic behavioral replacements for the five
// Xilinx xbip_dsp48_macro instances used by Aloha-HE's modular-multiply
// datapath. These also serve as the ASIC-port generic multipliers (Stage A',
// Aloha-HE adoption -- see design-review/aloha-he-adoption-audit.md).
//
// The Xilinx IP black boxes these replace (drop-in, identical port names/widths):
//   DSP_A_x_B, DSP_A_x_B_p_C, DSP_A_x_B_doublebuffer,
//   MontRed_DSP_Mult, MontRed_DSP_MultAdd
//
// Latency and the C-input injection stage were taken from the Kintex .xci
// register-enable settings (areg_*/breg_*/creg_*/mreg_*/preg_*) and
// cross-checked against (a) the pipeline-alignment constraints in the
// surrounding RTL and (b) the latency arithmetic in the module comments
// (ModMul = 15cc; MontRed = "2*3 + 1*4 + 1 = 11cc"; IntMultiplier_54x54 = 5cc):
//
//   module                  | lat | function              | .xci reg stages          | C / CARRYIN
//   ------------------------|-----|-----------------------|--------------------------|-------------
//   DSP_A_x_B               | 2cc | P = A*B               | areg_3, preg_6           | -
//   DSP_A_x_B_p_C           | 3cc | P = A*B + C           | areg_3, mreg_5, preg_6   | C sampled +2cc (added at P stage)
//   DSP_A_x_B_doublebuffer  | 3cc | P = A*B               | areg_3+areg_4, preg_6    | -
//   MontRed_DSP_Mult        | 2cc | P = A*B               | areg_4, preg_6           | -
//   MontRed_DSP_MultAdd     | 3cc | P = A*B + C + CARRYIN | areg_3,creg_3+creg_5,    | C,CARRYIN sampled +0cc
//                           |     |                       |   mreg_5, preg_6         |
//
// All A/B/C ports are interpreted as two's-complement SIGNED, matching the
// DSP48 A/B ports. The callers prepend explicit sign bits to control the sign,
// e.g. MontRed feeds B = {1'b1, q_m} which as an 18-bit signed value equals
// -(2^17 - q_m) = -q_m_pos, injecting the modular subtraction. Consumers use
// only the low P-width bits of the (signed) result, so width-truncation here is
// the correct two's-complement low-word in every case.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

// P = A*B, latency 2cc (input reg -> output/product reg; no M reg).
module DSP_A_x_B (
    input               CLK,
    input        [24:0] A,
    input        [17:0] B,
    output       [42:0] P
  );
  logic signed [24:0] a_q;
  logic signed [17:0] b_q;
  logic signed [42:0] p_q;
  always_ff @(posedge CLK) begin
    a_q <= A;          // cycle 1
    b_q <= B;
    p_q <= a_q * b_q;  // cycle 2 (= A*B of the batch applied at cycle 0)
  end
  assign P = p_q;
endmodule


// P = A*B + C, latency 3cc. C is consumed 2 cycles after A,B (added at the
// P-stage, after the A-reg and M-reg), exactly aligning the IntMultiplier_24x34
// carry chain (its C input = the low DSP_A_x_B product, valid at +2cc).
module DSP_A_x_B_p_C (
    input               CLK,
    input        [24:0] A,
    input        [17:0] B,
    input        [24:0] C,
    output       [43:0] P
  );
  logic signed [24:0] a_q;   // cycle 1
  logic signed [17:0] b_q;   // cycle 1
  logic signed [42:0] m_q;   // cycle 2 = A*B
  logic signed [43:0] p_q;   // cycle 3 = m_q + C(sampled at cycle 2)
  always_ff @(posedge CLK) begin
    a_q <= A;
    b_q <= B;
    m_q <= a_q * b_q;
    p_q <= m_q + $signed(C);
  end
  assign P = p_q;
endmodule


// P = A*B, latency 3cc. Two cascaded input registers ("double buffer", areg_3
// + areg_4) and no M reg.
module DSP_A_x_B_doublebuffer (
    input               CLK,
    input        [20:0] A,
    input        [ 6:0] B,
    output       [27:0] P
  );
  logic signed [20:0] a1, a2;  // cycle 1, cycle 2
  logic signed [ 6:0] b1, b2;
  logic signed [27:0] p_q;     // cycle 3 = A*B
  always_ff @(posedge CLK) begin
    a1 <= A;   b1 <= B;
    a2 <= a1;  b2 <= b1;
    p_q <= a2 * b2;
  end
  assign P = p_q;
endmodule


// P = A*B, latency 2cc (areg_4 + preg_6, no M reg). Functionally identical to
// DSP_A_x_B; kept as a distinct module to mirror the upstream IP instance name,
// but delegates to DSP_A_x_B so the multiply logic lives in exactly one place.
module MontRed_DSP_Mult (
    input               CLK,
    input        [24:0] A,
    input        [17:0] B,
    output       [42:0] P
  );
  DSP_A_x_B u (.CLK(CLK), .A(A), .B(B), .P(P));
endmodule


// P = A*B + C + CARRYIN, latency 3cc. C and CARRYIN are sampled together with
// A,B (offset 0): the C path has two registers (creg_3 + creg_5) that balance
// the A-reg + M-reg before the add at the P-stage.
module MontRed_DSP_MultAdd (
    input               CLK,
    input               CARRYIN,
    input        [24:0] A,
    input        [17:0] B,
    input        [47:0] C,
    output       [47:0] P
  );
  logic signed [24:0] a_q;          // cycle 1
  logic signed [17:0] b_q;          // cycle 1
  logic signed [47:0] c1, c2;       // cycle 1, cycle 2  (creg_3, creg_5)
  logic               ci1, ci2;     // cycle 1, cycle 2
  logic signed [42:0] m_q;          // cycle 2 = A*B
  logic signed [47:0] p_q;          // cycle 3
  always_ff @(posedge CLK) begin
    a_q <= A;            b_q <= B;
    c1  <= $signed(C);   ci1 <= CARRYIN;
    m_q <= a_q * b_q;    c2  <= c1;        ci2 <= ci1;
    p_q <= m_q + c2 + $signed({1'b0, ci2});
  end
  assign P = p_q;
endmodule
