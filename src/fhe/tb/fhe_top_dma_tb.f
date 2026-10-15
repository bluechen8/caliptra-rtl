// fhe_top (register map v2) round-trip TB with the firmware-forward stream.
// Build with +define+FHE_WALKER so fhe_top instantiates fhe_microseq +
// ComputeCoreWrapper + fhe_local_stream.
+incdir+$ALOHA_PORT/../rtl
+incdir+$CALIPTRA_ROOT/src/caliptra_prim/rtl
+incdir+$CALIPTRA_ROOT/src/libs/rtl
$CALIPTRA_ROOT/src/caliptra_prim/rtl/caliptra_prim_util_pkg.sv
// C'-2: Aloha sampler PRNG = caliptra_prim_trivium (via TriviumAdapter).
$CALIPTRA_ROOT/src/caliptra_prim/rtl/caliptra_prim_trivium_pkg.sv
$CALIPTRA_ROOT/src/caliptra_prim/rtl/caliptra_prim_trivium.sv
$CALIPTRA_ROOT/src/caliptra_prim/rtl/caliptra_prim_mubi_pkg.sv
$CALIPTRA_ROOT/src/caliptra_prim/rtl/caliptra_prim_pkg.sv
// FHE block + Aloha core.
$ALOHA_PORT/../rtl/fhe_params_pkg.sv
$ALOHA_PORT/../rtl/fhe_reg_pkg.sv
// C'-1b: KeyVault seed reader (fhe_top imports kv_defines_pkg under FHE_WALKER).
$CALIPTRA_ROOT/src/keyvault/rtl/kv_defines_pkg.sv
-f $ALOHA_PORT/sim/aloha_core.f
$ALOHA_PORT/../rtl/fhe_microseq.sv
$ALOHA_PORT/../rtl/fhe_local_stream.sv
$ALOHA_PORT/../rtl/fhe_kv_seed.sv
$ALOHA_PORT/../rtl/fhe_1r1w_ram.sv
$ALOHA_PORT/../rtl/fhe_mem_if.sv
$ALOHA_PORT/../rtl/fhe_mem_top.sv
$ALOHA_PORT/../rtl/fhe_aloha_mem_top.sv
$ALOHA_PORT/../rtl/fhe_ahb_slv_sif.sv
$ALOHA_PORT/../rtl/fhe_reg.sv
$ALOHA_PORT/../rtl/fhe_top.sv
$ALOHA_PORT/../tb/fhe_completion_checker.sv
$ALOHA_PORT/../tb/fhe_top_dma_tb.sv
