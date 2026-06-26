// Rung 2a file list: tb_FFTButterfly (self-checking double-precision FP
// complex-butterfly TB, vs tv/double_{gs,ct}_nosub_testvec.txt).
//
// Double-precision only -> the LShift22/RShift23 shifter black boxes are NOT
// instantiated (they are `ifdef SINGLE_PRECISION); no BRAM is used. The only
// non-RTL primitives are the DSP multipliers, supplied by aloha_dsp_behav.sv.

+incdir+$ALOHA_SRC/Aloha-HE_Common
$ALOHA_SRC/Aloha-HE_Common/CommonDefinitions.vh

// --- our technology-generic DSP replacements ---
$ALOHA_PORT/rtl/aloha_dsp_behav.sv

// --- Utils ---
$ALOHA_SRC/Aloha-HE_Common/Utils/DelayRegister.sv
$ALOHA_SRC/Aloha-HE_Common/Utils/CarrySaveAdder.sv
$ALOHA_SRC/Aloha-HE_Common/Utils/LeadingZeroCount.sv

// --- shared integer multiplier pool (54x54) ---
$ALOHA_SRC/Aloha-HE_Common/SharedArithmetics/IntMultiplier_24x34.sv
$ALOHA_SRC/Aloha-HE_Common/SharedArithmetics/IntMultiplier_54x54.sv
$ALOHA_SRC/Aloha-HE_Common/SharedArithmetics/IntMultPool.sv

// --- floating-point datapath ---
$ALOHA_SRC/Aloha-HE_Common/FloatingPoint/FLPMultiplier.sv
$ALOHA_SRC/Aloha-HE_Common/FloatingPoint/FLPAdderDenormalization.sv
$ALOHA_SRC/Aloha-HE_Common/FloatingPoint/FLPAdderSigAddNormalize.sv
$ALOHA_SRC/Aloha-HE_Common/FloatingPoint/FLPAdder.sv
$ALOHA_SRC/Aloha-HE_Common/FloatingPoint/ComplexMultiplier.sv
$ALOHA_SRC/Aloha-HE_Common/FloatingPoint/FFTButterflyAddStage.sv
$ALOHA_SRC/Aloha-HE_Common/FloatingPoint/FFTButterfly.sv

// --- self-checking testbench (top; vendored) ---
$ALOHA_SRC/Aloha-HE_Common/Testbench/tb_FFTButterfly.sv
