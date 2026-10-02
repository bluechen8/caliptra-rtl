`timescale 1ns/1ps
// Compare the phased 1RW model against the original two-port contract at
// logical engine edges, including intentional same-address collisions.
module tb_fhe_phase_bank;
  logic clk = 0;
  always #5 clk = ~clk;
  logic rd = 0, exec = 0, wr = 0, we = 0;
  logic [3:0] ra = 0, wa = 0;
  logic [73:0] wd = 0;
  wire engine_clk = clk & exec; // testbench: exec changes only at falling edges
  wire [73:0] phased_q [0:1], reference_q [0:1];
  for (genvar mode = 0; mode < 2; mode++) begin : banks
    fhe_phase_bank #(.W(74), .DEPTH(16), .WRITE_FIRST(mode)) phased (
      .clk(clk), .rd(rd), .exec(exec), .wr(wr), .we(we),
      .ra(ra), .wa(wa), .wd(wd), .q(phased_q[mode]));
    aloha_bram_sdp #(.W(74), .DEPTH(16), .WRITE_FIRST(mode)) reference (
      .clka(engine_clk), .clkb(engine_clk), .wea(we),
      .addrb(ra), .addra(wa), .dina(wd), .doutb(reference_q[mode]));
  end
  logic [7:0] byte_mask = 8'hff;
  wire [63:0] packed_q;
  logic [63:0] packed_reference [0:15];
  logic [63:0] packed_previous;
  fhe_shared_bank #(.W(64), .DEPTH(16), .GRAN(8),
    .FORWARD_MASK(64'hff00000000000000)) packed_bank (
    .clk(clk), .rd(rd), .exec(exec), .wr(wr), .we(we), .mask(byte_mask),
    .ra(ra), .wa(wa), .wd(wd[63:0]), .q(packed_q));
  int sample_updates=0, residue_updates=0;
  int cycles = 0, collisions = 0, distinct = 0;
  task automatic cycle(input bit write_en, input logic [3:0] read_addr,
                       input logic [3:0] write_addr, input logic [73:0] data);
    logic [63:0] packed_expected;
    @(negedge clk);
    byte_mask = cycles < 16 ? 8'hff : (cycles%2 ? 8'h80 : 8'h7f);
    packed_expected = packed_reference[read_addr];
    if (write_en && read_addr == write_addr && byte_mask[7])
      packed_expected[63:56] = data[63:56];
    if (write_en) begin
      for(int b=0;b<8;b++)
        if(byte_mask[b]) packed_reference[write_addr][b*8+:8]=data[b*8+:8];
      if(byte_mask==8'h80) sample_updates++;
      if(byte_mask==8'h7f) residue_updates++;
    end
    rd = 1; wr = 0; exec = 0;
    ra = read_addr; wa = write_addr; wd = data; we = write_en;
    @(negedge clk);
    rd = 0; exec = 1;
    @(posedge clk); #1;
    if (cycles >= 20) begin
      assert(packed_q === packed_previous)
        else $fatal(1,"packed sample/residue preservation or forwarding failed: got %h expected %h",packed_q,packed_previous);
      for (int mode = 0; mode < 2; mode++)
        assert (phased_q[mode] === reference_q[mode])
          else $fatal(1, "cycle %0d mode %0d: phased=%h reference=%h", cycles,
                      mode, phased_q[mode], reference_q[mode]);
      if (write_en && read_addr == write_addr) collisions++;
      if (write_en && read_addr != write_addr) distinct++;
    end
    packed_previous = packed_expected;
    @(negedge clk);
    exec = 0; wr = 1;
    // Deliberately change live inputs after EXECUTE. WRITE must use the saved
    // request from READ, even though core outputs change on EXECUTE in silicon.
    wd = ~data; wa = ~write_addr; we = 0; byte_mask = 0;
    cycles++;
  endtask
  initial begin
    for (int i = 0; i < 16; i++) cycle(1, 4'(i), 4'(i), 74'(i + 100));
    for (int i = 0; i < 4; i++) cycle(0, 0, 0, 0);
    for (int i = 0; i < 1000; i++) begin
      logic [3:0] a;
      a = 4'($urandom);
      cycle(i%3 != 0, a, i%2 ? a : a+1, {$urandom, $urandom, 10'($urandom)});
    end
    repeat (4) cycle(0, 0, 0, 0);
    assert (collisions > 300 && distinct > 300) else $fatal(1, "insufficient conflict coverage");
    assert(sample_updates>300 && residue_updates>300) else $fatal(1,"insufficient masked-write coverage");
    $display("PASS packed sample byte: %0d sample and %0d residue writes",sample_updates,residue_updates);
    $display("tb_fhe_phase_bank PASS: %0d logical cycles, %0d same-address and %0d distinct-address writes", cycles, collisions, distinct);
    $finish;
  end
endmodule
