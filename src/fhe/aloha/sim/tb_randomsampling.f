// Rung 2c file list: tb_RandomSampling (Trivium PRNG -> CBD errors e0/e1,
// ternary v, uniform pk1; vs tv/error_sampling.txt + key_sampling.txt).
// Needs the CBD/Ternary/NTT behavioral BRAMs; no FP, no DSP, no ROM.

+incdir+$ALOHA_SRC/Aloha-HE_Common
$ALOHA_SRC/Aloha-HE_Common/CommonDefinitions.vh

// C'-2: sampler PRNG = caliptra_prim_trivium (audited), replacing Trivium64.v.
-f $ALOHA_PORT/sim/aloha_prim_trivium.f

// --- our technology-generic memory models ---
$ALOHA_PORT/rtl/aloha_bram_behav.sv

// --- Utils ---
$ALOHA_SRC/Aloha-HE_Common/Utils/DelayRegister.sv
$ALOHA_SRC/Aloha-HE_Common/Utils/DelayRegisterReset.sv
$ALOHA_SRC/Aloha-HE_Common/Utils/HammingWeight.sv
$ALOHA_SRC/Aloha-HE_Common/Utils/Expand.sv

// --- random sampling datapath (Trivium64.v retired; PRNG via aloha_prim_trivium.f) ---
$ALOHA_SRC/Aloha-HE_Common/RandomSampling/TriviumAdapter.sv
$ALOHA_SRC/Aloha-HE_Common/RandomSampling/RandomSampling.sv

// --- self-checking testbench (top) ---
$ALOHA_SRC/Aloha-HE_Common/Testbench/tb_RandomSampling.sv
