// Stage-B' 2c-step-2: fhe_top + dedicated FHE DMA (real AXI) round-trip TB.
// Build with +define+FHE_WALKER so fhe_top instantiates fhe_microseq +
// ComputeCoreWrapper + fhe_dma and exposes the AXI manager port.
+incdir+$ALOHA_PORT/../rtl
+incdir+$CALIPTRA_ROOT/src/caliptra_prim/rtl
+incdir+$CALIPTRA_ROOT/src/libs/rtl
// Reused Caliptra prim: hardened sync FIFO (Secure=0/Pass=0 -> minimal deps).
// In the SoC build these are already compiled; only the standalone TB lists them.
$CALIPTRA_ROOT/src/caliptra_prim/rtl/caliptra_prim_util_pkg.sv
$CALIPTRA_ROOT/src/caliptra_prim/rtl/caliptra_prim_mubi_pkg.sv
$CALIPTRA_ROOT/src/caliptra_prim/rtl/caliptra_prim_pkg.sv
$CALIPTRA_ROOT/src/caliptra_prim/rtl/caliptra_prim_count_pkg.sv
$CALIPTRA_ROOT/src/caliptra_prim/rtl/caliptra_prim_fifo_sync_cnt.sv
$CALIPTRA_ROOT/src/caliptra_prim/rtl/caliptra_prim_fifo_sync.sv
// caliptra_prim_count.sv / caliptra_prim_flop.sv (referenced by the cnt's unused
// Secure branch) are auto-resolved by Verilator from the +incdir above.
// Reused Caliptra AXI infrastructure (the fhe_dma engine instances axi_mgr_*).
$CALIPTRA_ROOT/src/axi/rtl/axi_pkg.sv
$CALIPTRA_ROOT/src/axi/rtl/axi_if.sv
$CALIPTRA_ROOT/src/axi/rtl/axi_dma_req_if.sv
$CALIPTRA_ROOT/src/libs/rtl/skidbuffer.v
$CALIPTRA_ROOT/src/axi/rtl/axi_mgr_rd.sv
$CALIPTRA_ROOT/src/axi/rtl/axi_mgr_wr.sv
// FHE block + Aloha core + the DMA engine.
$ALOHA_PORT/../rtl/fhe_params_pkg.sv
// C'-1b: KeyVault seed reader (fhe_top imports kv_defines_pkg under FHE_WALKER).
$CALIPTRA_ROOT/src/keyvault/rtl/kv_defines_pkg.sv
-f $ALOHA_PORT/sim/aloha_core.f
$ALOHA_PORT/../rtl/fhe_microseq.sv
$ALOHA_PORT/../rtl/fhe_dma.sv
$ALOHA_PORT/../rtl/fhe_kv_seed.sv
$ALOHA_PORT/../rtl/fhe_1r1w_ram.sv
$ALOHA_PORT/../rtl/fhe_mem_if.sv
$ALOHA_PORT/../rtl/fhe_mem_top.sv
$ALOHA_PORT/../rtl/fhe_ahb_slv_sif.sv
$ALOHA_PORT/../rtl/fhe_top.sv
$ALOHA_PORT/../tb/fhe_top_dma_tb.sv
