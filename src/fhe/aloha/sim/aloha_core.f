// Rung 5: full composed CKKS core (ComputeCoreWrapper -> ComputeCore -> all
// engines + INS_RAM microcode sequencer). Builds on the Rung-3 engine filelist
// and adds the three composition-layer files (vendored .v).
-f $ALOHA_PORT/sim/aloha_engine.f
$ALOHA_SRC/Aloha-HE_Common/ISA_control.v
$ALOHA_SRC/Aloha-HE_Common/ComputeCore.v
$ALOHA_SRC/Aloha-HE_Common/ComputeCoreWrapper.v
