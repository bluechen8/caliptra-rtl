// Rung 2b file list: tb_IntToFlpWrapper (integer -> IEEE-754 double mapping
// used in decrypt/decode; vs tv/int_to_double_wrap_testvec.txt).
// Needs SharedFFTBrams (-> NTTPolyBank + SharedFFTBramBank) + standalone
// NTTPolyBank; no DSP, no ROM. Double-precision -> no shifter black boxes.

+incdir+$ALOHA_SRC/Aloha-HE_Common
$ALOHA_SRC/Aloha-HE_Common/CommonDefinitions.vh

// --- our technology-generic memory models ---
$ALOHA_PORT/rtl/aloha_bram_behav.sv

// --- Utils ---
$ALOHA_SRC/Aloha-HE_Common/Utils/DelayRegister.sv
$ALOHA_SRC/Aloha-HE_Common/Utils/DelayRegisterReset.sv
$ALOHA_SRC/Aloha-HE_Common/Utils/LeadingZeroCount.sv

// --- shared FFT/key BRAM wrapper ---
$ALOHA_SRC/Aloha-HE_Common/SharedArithmetics/SharedFFTBrams.sv

// --- int -> double datapath ---
$ALOHA_SRC/Aloha-HE_Common/FloatingPoint/IntToFlP.sv
$ALOHA_SRC/Aloha-HE_Common/FloatingPoint/IntToFlPWrapper.sv

// --- self-checking testbench (top) ---
$ALOHA_SRC/Aloha-HE_Common/Testbench/tb_IntToFlpWrapper.sv
