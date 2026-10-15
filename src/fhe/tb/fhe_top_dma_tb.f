// fhe_top (register map v2) unit TB. Build with +define+FHE_WALKER so fhe_top
// instantiates fhe_microseq + ComputeCoreWrapper and its transports.
+incdir+$ALOHA_PORT/../rtl
+incdir+$CALIPTRA_ROOT/src/caliptra_prim/rtl
+incdir+$CALIPTRA_ROOT/src/libs/rtl
$CALIPTRA_ROOT/src/caliptra_prim/rtl/caliptra_prim_util_pkg.sv
// C'-2: Aloha sampler PRNG = caliptra_prim_trivium (via TriviumAdapter).
$CALIPTRA_ROOT/src/caliptra_prim/rtl/caliptra_prim_trivium_pkg.sv
$CALIPTRA_ROOT/src/caliptra_prim/rtl/caliptra_prim_trivium.sv
$CALIPTRA_ROOT/src/caliptra_prim/rtl/caliptra_prim_mubi_pkg.sv
$CALIPTRA_ROOT/src/caliptra_prim/rtl/caliptra_prim_pkg.sv
// axi_pkg: the DMA stream bridge's requester-port types (compiled in every build).
$CALIPTRA_ROOT/src/axi/rtl/axi_pkg.sv
// KeyVault types (fhe_top's seed port; the DMA's KeyVault client).
$CALIPTRA_ROOT/src/keyvault/rtl/kv_defines_pkg.sv
// Caliptra axi_dma + AXI memory (instantiated only in DMA_STREAM builds).
-f $ALOHA_PORT/../tb/fhe_top_dma_tb_axi.f
// FHE block + Aloha core.
$ALOHA_PORT/../rtl/fhe_params_pkg.sv
$ALOHA_PORT/../rtl/fhe_reg_pkg.sv
-f $ALOHA_PORT/sim/aloha_core.f
$ALOHA_PORT/../rtl/fhe_microseq.sv
$ALOHA_PORT/../rtl/fhe_local_stream.sv
$ALOHA_PORT/../rtl/fhe_dma_stream_bridge.sv
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
