// Rung 5: full composed CKKS core (ComputeCoreWrapper -> ComputeCore -> all
// engines + INS_RAM microcode sequencer). Builds on the Rung-3 engine filelist
// and adds the three composition-layer files (vendored .v).
//
// C'-2: the sampler (RandomSampling -> TriviumAdapter, via aloha_engine.f) needs
// caliptra_prim_trivium. Standalone tops that -f THIS file must also
// `-f $ALOHA_PORT/sim/aloha_prim_trivium.f`; the full-SoC build gets the prim
// from its base caliptra_top_tb.vf, so that .vf must NOT -f aloha_prim_trivium.f.
-f $ALOHA_PORT/sim/aloha_engine.f
// C'-3: interface bundling the ComputeCore storage banks lifted to the top.
$ALOHA_PORT/../rtl/fhe_aloha_mem_if.sv
$ALOHA_SRC/Aloha-HE_Common/ISA_control.v
$ALOHA_SRC/Aloha-HE_Common/ComputeCore.v
$ALOHA_SRC/Aloha-HE_Common/ComputeCoreWrapper.v
