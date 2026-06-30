// Rung 5: composed-core CKKS round-trip TB (drives ComputeCoreWrapper via the
// SDK send64/receive64/exeIns protocol).
-f $ALOHA_PORT/sim/aloha_core.f
$ALOHA_PORT/../rtl/fhe_params_pkg.sv
$ALOHA_PORT/../rtl/fhe_microseq.sv
$ALOHA_PORT/sim/tb_ckks_roundtrip.sv
