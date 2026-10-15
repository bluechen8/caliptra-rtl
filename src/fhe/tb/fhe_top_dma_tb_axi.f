// fhe_top_dma_tb: Caliptra's axi_dma and an AXI memory (axi_sub) over the
// testbench memory; the TB instantiates them in DMA_STREAM builds. Included
// from fhe_top_dma_tb.f after the primitive packages and axi_pkg.
+incdir+$CALIPTRA_ROOT/src/integration/rtl
+incdir+$CALIPTRA_ROOT/src/integration/rtl/caliptra_reg
+incdir+$CALIPTRA_ROOT/src/soc_ifc/rtl
+incdir+$CALIPTRA_ROOT/src/keyvault/rtl
+incdir+$CALIPTRA_ROOT/src/axi/rtl
$CALIPTRA_ROOT/src/integration/rtl/config_defines.svh
$CALIPTRA_ROOT/src/libs/rtl/caliptra_sva.svh
$CALIPTRA_ROOT/src/libs/rtl/caliptra_macros.svh
$CALIPTRA_ROOT/src/libs/rtl/skidbuffer.v
$CALIPTRA_ROOT/src/caliptra_prim/rtl/caliptra_prim_count_pkg.sv
$CALIPTRA_ROOT/src/caliptra_prim/rtl/caliptra_prim_fifo_sync_cnt.sv
$CALIPTRA_ROOT/src/caliptra_prim/rtl/caliptra_prim_fifo_sync.sv
$CALIPTRA_ROOT/src/axi/rtl/axi_if.sv
$CALIPTRA_ROOT/src/axi/rtl/axi_addr.v
$CALIPTRA_ROOT/src/axi/rtl/axi_sub_rd.sv
$CALIPTRA_ROOT/src/axi/rtl/axi_sub_wr.sv
$CALIPTRA_ROOT/src/axi/rtl/axi_sub_arb.sv
$CALIPTRA_ROOT/src/axi/rtl/axi_sub.sv
$CALIPTRA_ROOT/src/soc_ifc/rtl/soc_ifc_pkg.sv
$CALIPTRA_ROOT/src/keyvault/rtl/kv_read_client.sv
$CALIPTRA_ROOT/src/axi/rtl/axi_dma_req_if.sv
$CALIPTRA_ROOT/src/axi/rtl/axi_dma_reg_pkg.sv
$CALIPTRA_ROOT/src/axi/rtl/axi_dma_reg.sv
$CALIPTRA_ROOT/src/axi/rtl/axi_mgr_rd.sv
$CALIPTRA_ROOT/src/axi/rtl/axi_mgr_wr.sv
$CALIPTRA_ROOT/src/axi/rtl/axi_dma_ctrl.sv
$CALIPTRA_ROOT/src/axi/rtl/axi_dma_top.sv
