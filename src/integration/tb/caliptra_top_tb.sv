// SPDX-License-Identifier: Apache-2.0
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
`default_nettype none

`include "common_defines.sv"
`include "config_defines.svh"
`include "caliptra_reg_defines.svh"
`include "caliptra_reg_field_defines.svh"
`include "caliptra_macros.svh"

`ifndef VERILATOR
module caliptra_top_tb;
`else
module caliptra_top_tb (
    input bit core_clk,
    input bit rst_l
    );
`endif

    import axi_pkg::*;
    import kv_defines_pkg::*;
    import soc_ifc_pkg::*;
    import caliptra_top_tb_pkg::*;

`ifndef VERILATOR
    // Time formatting for %t in display tasks
    // -9 = ns units
    // 3  = 3 bits of precision (to the ps)
    // "ns" = nanosecond suffix for output time values
    // 15 = 15 bits minimum field width
    initial $timeformat(-9, 3, " ns", 15); // up to 99ms representable in this width
`endif

`ifndef VERILATOR
    bit                         core_clk;
`endif

    int                         cycleCnt;


    logic [15:0] strap_ss_key_release_key_size;
    logic [63:0] strap_ss_key_release_base_addr;

    logic                       cptra_pwrgood;
    logic                       cptra_rst_b;
    logic                       BootFSM_BrkPoint;
    logic                       scan_mode;

    logic                       recovery_data_avail;

    logic [`CLP_OBF_KEY_DWORDS-1:0][31:0]          cptra_obf_key;
    
    logic [`CLP_CSR_HMAC_KEY_DWORDS-1:0][31:0]     cptra_csr_hmac_key;

    logic [0:`CLP_OBF_UDS_DWORDS-1][31:0]          cptra_uds_rand;
    logic [0:`CLP_OBF_FE_DWORDS-1][31:0]           cptra_fe_rand;
    logic [0:OCP_LOCK_HEK_NUM_DWORDS-1][31:0]      cptra_hek_rand;
    logic [0:`CLP_OBF_KEY_DWORDS-1][31:0]          cptra_obf_key_tb;

    //jtag interface
    logic                       jtag_tck;    // JTAG clk
    logic                       jtag_tms;    // JTAG TMS
    logic                       jtag_tdi;    // JTAG tdi
    logic                       jtag_trst_n; // JTAG Reset
    logic                       jtag_tdo;    // JTAG TDO
    logic                       jtag_tdoEn;  // JTAG TDO enable

    logic                       axi_error_inj_en;

    // AXI Interface
    axi_if #(
        .AW(`CALIPTRA_SLAVE_ADDR_WIDTH(`CALIPTRA_SLAVE_SEL_SOC_IFC)),
        .DW(`CALIPTRA_AXI_DATA_WIDTH),
        .IW(`CALIPTRA_AXI_ID_WIDTH),
        .UW(`CALIPTRA_AXI_USER_WIDTH)
    ) m_axi_bfm_if (.clk(core_clk), .rst_n(cptra_rst_b));
    axi_if #(
        .AW(`CALIPTRA_AXI_DMA_ADDR_WIDTH),
        .DW(CPTRA_AXI_DMA_DATA_WIDTH),
        .IW(CPTRA_AXI_DMA_ID_WIDTH),
        .UW(CPTRA_AXI_DMA_USER_WIDTH)
    ) m_axi_if (.clk(core_clk), .rst_n(cptra_rst_b));

`ifdef FHE_WALKER
    // Stage-B' 2c-step-3: dedicated FHE DMA AXI manager (64-bit data). Backed by
    // a behavioral AXI subordinate DRAM model below (TB-only memory, separate from
    // VeeR's address space). Geometry matches caliptra_top's fhe_m_axi_* port.
    localparam int FHE_DMA_DW = 64;
    axi_if #(
        .AW(`CALIPTRA_AXI_DMA_ADDR_WIDTH),
        .DW(FHE_DMA_DW),
        .IW(CPTRA_AXI_DMA_ID_WIDTH),
        .UW(CPTRA_AXI_DMA_USER_WIDTH)
    ) fhe_m_axi_if (.clk(core_clk), .rst_n(cptra_rst_b));
`endif

    logic ready_for_fuses;
    logic ready_for_mb_processing;
    logic mailbox_data_avail;
    logic mbox_sram_cs;
    logic mbox_sram_we;
    logic [CPTRA_MBOX_ADDR_W-1:0] mbox_sram_addr;
    logic [CPTRA_MBOX_DATA_AND_ECC_W-1:0] mbox_sram_wdata;
    logic [CPTRA_MBOX_DATA_AND_ECC_W-1:0] mbox_sram_rdata;

    logic imem_cs;
    logic [`CALIPTRA_IMEM_ADDR_WIDTH-1:0] imem_addr;
    logic [`CALIPTRA_IMEM_DATA_WIDTH-1:0] imem_rdata;

    //device lifecycle
    security_state_t security_state;

    logic ss_ocp_lock_en;

    ras_test_ctrl_t ras_test_ctrl;
    axi_complex_ctrl_t axi_complex_ctrl;
    logic [63:0] generic_input_wires;
    logic        etrng_req;
    logic  [3:0] itrng_data;
    logic        itrng_valid;

    logic cptra_error_fatal;
    logic cptra_error_non_fatal;

    //Interrupt flags
    logic int_flag;
    logic cycleCnt_smpl_en;

    //Reset flags
    logic assert_hard_rst_flag;
    logic deassert_hard_rst_flag;
    logic assert_rst_flag_from_service;
    logic deassert_rst_flag_from_service;

    el2_mem_if el2_mem_export ();
    abr_mem_if abr_memory_export();
    fhe_mem_if fhe_memory_export();
    fhe_mem_top fhe_mem_top_inst (.clk_i(core_clk), .fhe_memory_export(fhe_memory_export));
`ifdef FHE_WALKER
    // C'-3: the Aloha ComputeCore storage banks are lifted out of the vendored
    // RTL to the caliptra_top boundary; back them with the behavioral bank model
    // here (real SRAM lives on the Chisel side in the Chipyard wrapper).
    fhe_aloha_mem_if fhe_aloha_memory_export();
    // C'-3: the ROM address is registered in the DUT (clk_cg) before it crosses
    // the interface, so the behavioral memory here samples a STABLE registered
    // value. On core_clk (a delta after the DUT's clk_cg) the DUT register and
    // this memory's first read stage collapse, so RD_LAT=2 nets to 2-cycle read.
    fhe_aloha_mem_top fhe_aloha_mem_top_inst (.clk_i(core_clk), .m(fhe_aloha_memory_export.resp));
`endif

`ifndef VERILATOR
    always
    begin : clk_gen
      core_clk = #5ns ~core_clk;
    end // clk_gen
`endif


caliptra_top_tb_soc_bfm soc_bfm_inst (
    .core_clk        (core_clk        ),

    .cptra_pwrgood   (cptra_pwrgood   ),
    .cptra_rst_b     (cptra_rst_b     ),

    .BootFSM_BrkPoint(BootFSM_BrkPoint),
    .cycleCnt        (cycleCnt        ),

    .cptra_obf_key      (cptra_obf_key   ),
    .cptra_csr_hmac_key (cptra_csr_hmac_key),

    .strap_ss_key_release_key_size,
    .strap_ss_key_release_base_addr,
    .ss_ocp_lock_en,

    .cptra_uds_rand  (cptra_uds_rand  ),
    .cptra_fe_rand   (cptra_fe_rand   ),
    .cptra_hek_rand  (cptra_hek_rand  ),
    .cptra_obf_key_tb(cptra_obf_key_tb),

    .m_axi_bfm_if(m_axi_bfm_if),

    .ready_for_fuses         (ready_for_fuses         ),
    .ready_for_mb_processing (ready_for_mb_processing ),
    .mailbox_data_avail(mailbox_data_avail),

    .ras_test_ctrl(ras_test_ctrl),

    .generic_input_wires(generic_input_wires),

    .cptra_error_fatal(cptra_error_fatal),
    .cptra_error_non_fatal(cptra_error_non_fatal),
    
    //Interrupt flags
    .int_flag(int_flag),
    .cycleCnt_smpl_en(cycleCnt_smpl_en),

    .assert_hard_rst_flag(assert_hard_rst_flag),
    .deassert_hard_rst_flag(deassert_hard_rst_flag),
    .assert_rst_flag_from_service(assert_rst_flag_from_service),
    .deassert_rst_flag_from_service(deassert_rst_flag_from_service)

);
    
// JTAG DPI
jtagdpi #(
    .Name           ("jtag0"),
    .ListenPort     (63224)
) jtagdpi (
    .clk_i          (core_clk),
    .rst_ni         (cptra_rst_b),
    .jtag_tck       (jtag_tck),
    .jtag_tms       (jtag_tms),
    .jtag_tdi       (jtag_tdi),
    .jtag_tdo       (jtag_tdo),
    .jtag_trst_n    (jtag_trst_n),
    .jtag_srst_n    ()
);

   //=========================================================================-
   // DUT instance
   //=========================================================================-
caliptra_top caliptra_top_dut (
    .cptra_pwrgood              (cptra_pwrgood),
    .cptra_rst_b                (cptra_rst_b),
    .clk                        (core_clk),

    .cptra_obf_key              (cptra_obf_key),
    .cptra_obf_uds_seed_vld     ('0), //validated at caliptra-ss
    .cptra_obf_uds_seed         ('0), //validated at caliptra-ss
    .cptra_obf_field_entropy_vld('0), //validated at caliptra-ss
    .cptra_obf_field_entropy    ('0), //validated at caliptra-ss
    .cptra_csr_hmac_key         (cptra_csr_hmac_key),

    .jtag_tck(jtag_tck),
    .jtag_tdi(jtag_tdi),
    .jtag_tms(jtag_tms),
    .jtag_trst_n(jtag_trst_n),
    .jtag_tdo(jtag_tdo),
    .jtag_tdoEn(jtag_tdoEn),
    
    //SoC AXI Interface
    .s_axi_w_if(m_axi_bfm_if.w_sub),
    .s_axi_r_if(m_axi_bfm_if.r_sub),

    //AXI DMA Interface
    .m_axi_w_if(m_axi_if.w_mgr),
    .m_axi_r_if(m_axi_if.r_mgr),

`ifdef FHE_WALKER
    // Dedicated FHE DMA manager -> behavioral DRAM model (B' 2c-step-3a/3b).
    .fhe_m_axi_w_if(fhe_m_axi_if.w_mgr),
    .fhe_m_axi_r_if(fhe_m_axi_if.r_mgr),
`endif

    .el2_mem_export(el2_mem_export.veer_sram_src),
`ifndef CALIPTRA_NO_ADAMS_BRIDGE
    // caliptra_top drops the abr_memory_export port when ABR is compiled out
    // (C'-1c NoABR+FHE build); the TB's abr_mem_top model then just sits idle.
    .abr_memory_export(abr_memory_export.req),
`endif
    .fhe_memory_export(fhe_memory_export.req),
`ifdef FHE_WALKER
    .fhe_aloha_memory_export(fhe_aloha_memory_export.req),
`endif

    .ready_for_fuses(ready_for_fuses),
    .ready_for_mb_processing(ready_for_mb_processing),
    .ready_for_runtime(),

    .mbox_sram_cs(mbox_sram_cs),
    .mbox_sram_we(mbox_sram_we),
    .mbox_sram_addr(mbox_sram_addr),
    .mbox_sram_wdata(mbox_sram_wdata),
    .mbox_sram_rdata(mbox_sram_rdata),
        
    .imem_cs(imem_cs),
    .imem_addr(imem_addr),
    .imem_rdata(imem_rdata),

    .mailbox_data_avail(mailbox_data_avail),
    .mailbox_flow_done(),
    .BootFSM_BrkPoint(BootFSM_BrkPoint),

    .recovery_data_avail(recovery_data_avail),
    .recovery_image_activated(1'b0),

    //SoC Interrupts
    .cptra_error_fatal    (cptra_error_fatal    ),
    .cptra_error_non_fatal(cptra_error_non_fatal),

`ifdef CALIPTRA_INTERNAL_TRNG
    .etrng_req             (etrng_req),
    .itrng_data            (itrng_data),
    .itrng_valid           (itrng_valid),
`else
    .etrng_req             (),
    .itrng_data            (4'b0),
    .itrng_valid           (1'b0),
`endif

    // Subsystem mode straps, tested in subsystem bench
    .strap_ss_caliptra_base_addr                            (64'hba5e_ba11),
    .strap_ss_mci_base_addr                                 (64'h0),
    .strap_ss_recovery_ifc_base_addr                        (64'h0),
    .strap_ss_external_staging_area_base_addr               (64'h0),
    .strap_ss_otp_fc_base_addr                              (64'h0),
    .strap_ss_uds_seed_base_addr                            (64'h0),
    .strap_ss_key_release_base_addr                         ,
    .strap_ss_key_release_key_size                          ,
    .strap_ss_prod_debug_unlock_auth_pk_hash_reg_bank_offset(32'h0),
    .strap_ss_num_of_prod_debug_unlock_auth_pk_hashes       (32'h0),
    .strap_ss_caliptra_dma_axi_user                         (32'h0),
    .strap_ss_strap_generic_0                               (32'h0),
    .strap_ss_strap_generic_1                               (32'h0),
    .strap_ss_strap_generic_2                               (32'h0),
    .strap_ss_strap_generic_3                               (32'h0),
    .ss_debug_intent                                        ( 1'b0),

    // Subsystem mode constant strap input indicating OCP LOCK configuration is enabled
    .ss_ocp_lock_en                                         (ss_ocp_lock_en),

    // Subsystem mode debug outputs
    .ss_dbg_manuf_enable    (),
    .ss_soc_dbg_unlock_level(),

    // Subsystem mode firmware execution control
    .ss_generic_fw_exec_ctrl(),

    .generic_input_wires (generic_input_wires ),
    .generic_output_wires(                    ),

    // RISC-V Trace Ports
    .trace_rv_i_insn_ip     (),
    .trace_rv_i_address_ip  (),
    .trace_rv_i_valid_ip    (),
    .trace_rv_i_exception_ip(),
    .trace_rv_i_ecause_ip   (),
    .trace_rv_i_interrupt_ip(),
    .trace_rv_i_tval_ip     (),

    .security_state(security_state),
    .scan_mode     (scan_mode)
);


`ifdef CALIPTRA_INTERNAL_TRNG
    //=========================================================================-
    // Physical RNG used for Internal TRNG
    //=========================================================================-
physical_rng physical_rng (
    .clk    (core_clk),
    .enable (etrng_req),
    .data   (itrng_data),
    .valid  (itrng_valid)
);
`endif

   //=========================================================================-
   // Services for SRAM exports, STDOUT, etc
   //=========================================================================-
caliptra_top_tb_services #(
    .UVM_TB(0)
) tb_services_i (
    .clk(core_clk),

    .cptra_rst_b(cptra_rst_b),

    // Caliptra Memory Export Interface
    .el2_mem_export (el2_mem_export.veer_sram_sink),
    .abr_memory_export (abr_memory_export.resp),

    //SRAM interface for mbox
    .mbox_sram_cs   (mbox_sram_cs   ),
    .mbox_sram_we   (mbox_sram_we   ),
    .mbox_sram_addr (mbox_sram_addr ),
    .mbox_sram_wdata(mbox_sram_wdata),
    .mbox_sram_rdata(mbox_sram_rdata),

    //SRAM interface for imem
    .imem_cs   (imem_cs   ),
    .imem_addr (imem_addr ),
    .imem_rdata(imem_rdata),

    // Security State
    .security_state(security_state),

    //Scan mode
    .scan_mode(scan_mode),

    // TB Controls
    .ras_test_ctrl(ras_test_ctrl),
    .cycleCnt(cycleCnt),
    .axi_complex_ctrl(axi_complex_ctrl),

    //Interrupt flags
    .int_flag(int_flag),
    .cycleCnt_smpl_en(cycleCnt_smpl_en),

    //Reset flags
    .assert_hard_rst_flag(assert_hard_rst_flag),
    .deassert_hard_rst_flag(deassert_hard_rst_flag),

    .assert_rst_flag(assert_rst_flag_from_service),
    .deassert_rst_flag(deassert_rst_flag_from_service),
    
    .cptra_uds_tb(cptra_uds_rand),
    .cptra_fe_tb(cptra_fe_rand),
    .cptra_obf_key_tb(cptra_obf_key_tb),
    .cptra_hek_tb(cptra_hek_rand),

    .axi_error_inj_en(axi_error_inj_en)

);

caliptra_top_tb_axi_complex tb_axi_complex_i (
    .core_clk           (core_clk           ),
    .cptra_rst_b        (cptra_rst_b        ),
    .m_axi_if           (m_axi_if           ),
    .recovery_data_avail(recovery_data_avail),
    .ctrl               (axi_complex_ctrl   ),
    .axi_error_inj_en   (axi_error_inj_en)
);

`ifdef FHE_WALKER
    // Stage-B' 2c-step-3: back the dedicated FHE DMA manager with a behavioral AXI
    // subordinate DRAM model that also backdoor-preloads the golden plaintext and
    // checks the recovered-slots round-trip. See src/integration/tb/fhe_axi_dram_model.sv.
    // (fhe_m_axi_if is declared with the other AXI interfaces above and wired to
    // caliptra_top's fhe_m_axi_* ports at the DUT instance.)
    fhe_axi_dram_model #(.N(`FHE_N)) fhe_dram_model_i (
        .clk   (core_clk),
        .rst_n (cptra_rst_b),
        .axi   (fhe_m_axi_if)
    );
`ifdef CALIPTRA_NO_ADAMS_BRIDGE
    // C'-1c decisive check: with the FHE KeyVault client connected (NoABR),
    // prove the keygen root seed the walker consumes came from KeyVault
    // (0xDEADBEEF_CAFEBABE, injected by tb_services opcode 0xc6) and NOT the
    // KGSEED regs. The sk-scheme round-trip cancels for any key, so recovery
    // alone can't prove the source -- this seed-value check is the real gate.
    logic fhe_kv_seed_checked = 1'b0;
    always @(posedge core_clk) begin
        if (caliptra_top_dut.fhe_inst.kv_seed_valid && !fhe_kv_seed_checked) begin
            fhe_kv_seed_checked <= 1'b1;
            if (caliptra_top_dut.fhe_inst.kv_seed !== 64'hDEADBEEF_CAFEBABE)
                $display("[FHE-KV-TB] FAIL: keygen seed 0x%016x != KeyVault 0xDEADBEEFCAFEBABE",
                         caliptra_top_dut.fhe_inst.kv_seed);
            else
                $display("[FHE-KV-TB] PASS: keygen seed 0x%016x sourced from KeyVault (kv_read[6])",
                         caliptra_top_dut.fhe_inst.kv_seed);
        end
    end
`endif
`endif

//=========================================================================-
// SVA
//=========================================================================-
caliptra_top_sva sva();

endmodule
