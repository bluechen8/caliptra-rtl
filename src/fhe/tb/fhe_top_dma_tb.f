// fhe_top (register map v2) unit TB. Build with +define+FHE_WALKER so fhe_top
// instantiates fhe_microseq + ComputeCoreWrapper and its transports.
+incdir+$ALOHA_PORT/../rtl
// Caliptra AES engine with the primitives and packages it needs, including
// caliptra_prim_trivium (the Aloha sampler PRNG) and kv_defines_pkg (fhe_top's
// KeyVault seed port).
-f $CALIPTRA_ROOT/src/aes/config/aes.vf
// axi_pkg: the DMA stream bridge's requester-port types (compiled in every build).
$CALIPTRA_ROOT/src/axi/rtl/axi_pkg.sv
// Caliptra axi_dma + AXI memory (with Caliptra AES from aes.vf).
-f $ALOHA_PORT/../tb/fhe_top_dma_tb_axi.f
// FHE block + Aloha core.
$ALOHA_PORT/../rtl/fhe_params_pkg.sv
$ALOHA_PORT/../rtl/fhe_reg_pkg.sv
-f $ALOHA_PORT/sim/aloha_core.f
$ALOHA_PORT/../rtl/fhe_microseq.sv
$ALOHA_PORT/../rtl/fhe_dma_stream_bridge.sv
$ALOHA_PORT/../rtl/fhe_kv_seed.sv
$ALOHA_PORT/../rtl/fhe_1r1w_ram.sv
$ALOHA_PORT/../rtl/fhe_mem_if.sv
$ALOHA_PORT/../rtl/fhe_mem_top.sv
$ALOHA_PORT/../rtl/fhe_ilv_bank.sv
$ALOHA_PORT/../rtl/fhe_aloha_mem_top.sv
$ALOHA_PORT/../rtl/fhe_ahb_slv_sif.sv
$ALOHA_PORT/../rtl/fhe_reg.sv
$ALOHA_PORT/../rtl/fhe_top.sv
$ALOHA_PORT/../tb/fhe_completion_checker.sv
$ALOHA_PORT/../tb/fhe_top_dma_tb.sv
