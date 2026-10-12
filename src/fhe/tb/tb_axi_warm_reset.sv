// Unit regression using the real Caliptra read subordinate, reset FSM and clock gate.
module tb_axi_reset;
  timeunit 1ns/1ps;
  bit clk=0, pwrgood=0, reset_b=0;
  always #5 clk=~clk;
  wire noncore_rst_b, uc_rst_b, rdc_dis, update_window, soc_clk;
  soc_ifc_boot_fsm boot(.clk(clk), .cptra_pwrgood(pwrgood), .cptra_rst_b(reset_b),
    .scan_mode(1'b0), .fw_update_rst(1'b0), .fw_update_rst_wait_cycles(8'd0),
    .BootFSM_BrkPoint(1'b0), .BootFSM_Continue(1'b1), .ready_for_fuses(), .boot_fsm_ps(),
    .fuse_done(1'b1), .fuse_wr_done_observed(1'b1), .cptra_noncore_rst_b(noncore_rst_b),
    .cptra_uc_rst_b(uc_rst_b), .iccm_unlock(), .fw_upd_rst_executed(),
    .rdc_clk_dis(rdc_dis), .fw_update_rst_window(update_window));
  clk_gate cg(.clk(clk),.cptra_rst_b(noncore_rst_b),.psel(1'b1),.clk_gate_en(1'b0),
    .rdc_clk_dis(rdc_dis),.rdc_clk_dis_uc(update_window),.cpu_halt_status(1'b0),
    .generic_input_wires(64'd0),.cptra_error_fatal(1'b0),.cptra_in_debug_scan_mode(1'b0),
    .clk_cg(),.clk_cg_en(),.soc_ifc_clk_cg(soc_clk),.rdc_clk_cg(),.uc_clk_cg(),.cptra_dmi_reg_en_preQ(1'b0));
  axi_if #(.AW(32),.DW(32),.IW(1),.UW(1)) axi(clk, noncore_rst_b);
  axi_sub_rd #(.AW(32),.DW(32),.UW(1),.IW(1),.C_LAT(0)) dut(.clk(soc_clk),.rst_n(noncore_rst_b),
    .s_axi_if(axi),.dv(),.addr(),.user(),.id(),.size(),.last(),.hld(1'b0),.err(1'b0),.rdata(32'h12345678));
  int requests=0, responses=0;
  always @(posedge clk) begin
    if(axi.arvalid && axi.arready) requests++;
    if(axi.rvalid && axi.rready) begin
      responses++;
      $display("response t=%0t req=%0d rsp=%0d reset=%b noncore=%b rdc=%b", $time,requests,responses,reset_b,noncore_rst_b,rdc_dis);
    end
  end
  initial begin
    axi.arvalid=0;axi.rready=0;axi.araddr='h300bc;axi.arburst=0;axi.arsize=2;axi.arlen=0;axi.aruser=0;axi.arid=0;axi.arlock=0;
    repeat(5) @(negedge clk);pwrgood=1;reset_b=1;
    wait(noncore_rst_b);repeat(10) @(negedge clk);
    axi.arvalid=1;
    do @(posedge clk); while(!axi.arready);
    @(negedge clk);axi.arvalid=0;
    wait(axi.rvalid);
    if ($test$plusargs("UNCOORDINATED")) begin
      @(negedge clk);reset_b=0;
      // A buffered response is consumed while the peripheral clock is gated.
      wait(rdc_dis);@(negedge clk);axi.rready=1;
      repeat(12) @(negedge clk);
      if(responses<=requests) $fatal(1,"reset-window duplicate not reproduced");
      $display("REPRODUCED uncoordinated reset: %0d responses for %0d request",responses,requests);
    end else begin
      // Drain the accepted read, including backpressure, before reset.
      repeat(5) @(negedge clk);
      axi.rready=1;
      wait(responses == 1);
      @(negedge clk);reset_b=0;
      repeat(12) @(negedge clk);
      if(responses != requests) $fatal(1,"duplicate response after drained reset");
      reset_b=1;
      wait(noncore_rst_b);repeat(10) @(negedge clk);
      axi.arvalid=1;
      do @(posedge clk); while(!axi.arready);
      @(negedge clk);axi.arvalid=0;
      repeat(10) @(negedge clk);
      if(requests != 2 || responses != 2) $fatal(1,"read did not recover after reset");
      $display("PASS coordinated reset: exactly one response per request, including reboot");
    end
    $finish;
  end
  initial begin #10000; $fatal(1,"timeout");end
endmodule
