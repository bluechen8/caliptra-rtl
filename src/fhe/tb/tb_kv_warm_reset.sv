// Focused regression: real KeyVault plus the security latch extracted from Caliptra RTL.
module tb_kv_warm_debug;
 import soc_ifc_pkg::*;
 import kv_defines_pkg::*;
 timeunit 1ns/1ps;
 bit clk=0, cptra_pwrgood=0, cptra_noncore_rst_b=0;
 always #5 clk=~clk;
 wire ss_dbg_manuf_enable=0, scan_mode=0, cptra_error_fatal=0;
 wire [63:0] ss_soc_dbg_unlock_level=0;
 logic unlock_caliptra_security_state;
 security_state_t security_state, cptra_security_state_Latched, cptra_security_state_Latched_d, cptra_security_state_Latched_f;
 logic cptra_scan_mode_Latched, cptra_scan_mode_Latched_d, cptra_scan_mode_Latched_f;
 logic scan_mode_switch, debug_lock_switch, device_lifecycle_switch, debug_lock_or_scan_mode_switch;
 `include "security_state_latch.svh"

 kv_read_t [KV_NUM_READ-1:0] reads;
 kv_write_t [KV_NUM_WRITE-1:0] writes;
 wire [ECC_NUM_DWORDS-1:0][31:0] key7;
 int flushes=0;
 always @(posedge clk) if (debug_lock_or_scan_mode_switch) flushes++;
 kv dut(.clk(clk),.rst_b(cptra_noncore_rst_b),.core_only_rst_b(cptra_noncore_rst_b),
 .cptra_pwrgood(cptra_pwrgood),.fw_update_rst_window(1'b0),
 .cptra_in_debug_scan_mode(!cptra_security_state_Latched.debug_locked),
 .debugUnlock_or_scan_mode_switch(debug_lock_or_scan_mode_switch),
 .haddr_i('0),.hwdata_i('0),.hsel_i(1'b0),.hwrite_i(1'b0),.hready_i(1'b1),.htrans_i('0),.hsize_i(3'd2),
 .hresp_o(),.hreadyout_o(),.hrdata_o(),.kv_read(reads),.kv_write(writes),
 .kv_rd_resp(),.kv_wr_resp(),.pcr_ecc_signing_key(key7),.pcr_mldsa_signing_key());
 initial begin
   int before_reset;
   bit locked;
   locked=$test$plusargs("LOCKED");
   security_state='{device_lifecycle:DEVICE_MANUFACTURING,debug_locked:locked};
   reads='0;writes='0;
   repeat(4) @(negedge clk); cptra_pwrgood=1; cptra_noncore_rst_b=1;
   repeat(8) @(negedge clk);
   for(int i=0;i<ECC_NUM_DWORDS;i++)begin
     writes[KV_WRITE_IDX_ECC]='{write_en:1'b1,write_entry:5'd7,write_offset:4'(i),write_data:32'h12340000+32'(i),write_dest_valid:9'(1<<KV_DEST_IDX_ECC_PKEY)};
     @(negedge clk);
   end
   writes='0;
   repeat(3) @(negedge clk);
   for(int i=0;i<ECC_NUM_DWORDS;i++) if(key7[i] !== 32'h12340000+32'(i)) $fatal(1,"seed failed word %0d",i);
   before_reset=flushes;
   cptra_noncore_rst_b=0;repeat(8) @(negedge clk);
   cptra_noncore_rst_b=1;repeat(8) @(negedge clk);
   for(int i=0;i<ECC_NUM_DWORDS;i++) begin
     if(locked && key7[i] !== 32'h12340000+32'(i)) $fatal(1,"locked warm reset lost key");
     if(!locked && key7[i] !== dut.debug_value) $fatal(1,"unlock flush not reproduced");
   end
   if(locked && flushes!=before_reset) $fatal(1,"unexpected locked flush");
   if(!locked && flushes!=before_reset+1) $fatal(1,"expected one unlock flush");
   $display("PASS locked=%b warm_reset_flushes=%0d key_retained=%b",locked,flushes-before_reset,locked);
   $finish;
 end
 initial begin #10000; $fatal(1,"timeout");end
endmodule
