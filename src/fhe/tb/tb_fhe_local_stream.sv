// SPDX-License-Identifier: Apache-2.0
module tb_fhe_local_stream;
  logic clk=0; always #5 clk=~clk;
  logic rst_n=0, clear=0, desc_valid=0, desc_wr=0;
  logic [2:0] desc_ptr=0; logic [3:0] desc_limb=0;
  logic dma_ready,rd_valid,rd_ready=0,wr_valid=0,wr_ready;
  logic [63:0] rd_data,wr_data=0;
  logic data_read=0,data_write=0;
  logic [31:0] data_wdata=0,data_rdata,status,remaining;
  logic access_error;
  fhe_local_stream #(.N(3)) dut(.*);
  task automatic tick(); @(posedge clk); #1; @(negedge clk); endtask
  task automatic start(input bit write_dir);
    desc_wr=write_dir;desc_ptr=3;desc_limb=1;desc_valid=1;tick();desc_valid=0;
    assert(!dma_ready && remaining==3 && status[6:4]==3 && status[11:8]==1) else $fatal;
  endtask
  task automatic push(input logic [31:0] data);
    data_write=1;data_wdata=data;#1;assert(!access_error) else $fatal;tick();data_write=0;
  endtask
  task automatic pop(input logic [31:0] expected);
    data_read=1;#1;assert(!access_error && data_rdata==expected) else $fatal;tick();data_read=0;
  endtask
  initial begin
    tick();rst_n=1;tick();
    data_read=1;#1;assert(access_error && data_rdata==0) else $fatal;tick();data_read=0;
    start(0);
    push(32'habcdef01);
    assert(!rd_valid && status[12]) else $fatal;
    clear=1;tick();clear=0;
    assert(dma_ready && !rd_valid && rd_data==0 && remaining==0) else $fatal;
    start(0);
    for(int i=0;i<3;i++) begin
      push(32'(i));push(32'h87654321);
      repeat(4) begin
        assert(rd_valid && rd_data=={32'h87654321,32'(i)}) else $fatal;tick();
      end
      data_write=1;#1;assert(access_error) else $fatal;tick();data_write=0;
      rd_ready=1;tick();rd_ready=0;
    end
    assert(dma_ready && remaining==0) else $fatal;
    start(1);
    for(int i=0;i<3;i++) begin
      wr_data={32'hfedcba98,32'(i)};wr_valid=1;tick();wr_valid=0;
      repeat(4) begin assert(!wr_ready && !dma_ready) else $fatal;tick();end
      pop(32'(i));
      assert(!dma_ready && remaining==3-i && status[12]) else $fatal;
      pop(32'hfedcba98);
    end
    assert(dma_ready && remaining==0 && rd_data==0) else $fatal;
    start(1);wr_valid=1;wr_data='1;tick();wr_valid=0;pop('1);
    rst_n=0;tick();rst_n=1;tick();
    assert(dma_ready && remaining==0 && data_rdata==0 && !status[12]) else $fatal;
    $display("fhe_local_stream PASS: ordering, backpressure, illegal accesses, completion, clear/reset");
    $finish;
  end
endmodule
