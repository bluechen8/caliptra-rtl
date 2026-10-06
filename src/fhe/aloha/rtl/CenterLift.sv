// SPDX-License-Identifier: Apache-2.0
// Single-limb level refresh for the frozen q0/q1 profile. Snapshot preserves
// coefficient-domain residues in the existing FFT real bank. Lift centers at
// q0/2, maps to the target prime, and adds the SAME sampled error in each limb.
// No multipliers, division, floating point, or additional vector storage.
module CenterLift #(
    parameter int LOGN = 13,
    parameter int BRAM_RD_LAT = 2
)(
    input logic clk, rst, snapshot,
    input logic [53:0] target_q,
    output logic [LOGN-1:0] rd_addr, wr_addr,
    input logic [63:0] msg0, msg1, saved,
    output logic [53:0] wr_data,
    output logic wr_en, done
);
    localparam logic [53:0] SOURCE_Q = 54'd70368593182721;
    logic issued_last;
    logic [LOGN-1:0] addr_pipe [0:BRAM_RD_LAT-1];
    logic [BRAM_RD_LAT-1:0] valid_pipe;
    logic [63:0] msg;
    logic [53:0] source, lifted;
    logic [54:0] sum;
    logic [4:0] magnitude;
    always_comb begin
        msg = addr_pipe[BRAM_RD_LAT-1][0] ? msg1 : msg0;
        source = saved[53:0];
        lifted = source > (SOURCE_Q >> 1) ? target_q - (SOURCE_Q - source) : source;
        magnitude = msg[60:56];
        // Sign-magnitude CBD sample in M's high byte; magnitude <= 31.
        if (msg[61])
            sum = lifted >= magnitude ? {1'b0,lifted} - magnitude
                                      : {1'b0,lifted} + target_q - magnitude;
        else begin
            sum = {1'b0,lifted} + magnitude;
            if (sum >= {1'b0,target_q}) sum = sum - target_q;
        end
    end
    always_ff @(posedge clk) begin
        if (rst) begin
            rd_addr <= '0;
            issued_last <= 1'b0;
            valid_pipe <= '0;
            wr_addr <= '0;
            wr_data <= '0;
            wr_en <= 1'b0;
            done <= 1'b0;
            for (int i=0; i<BRAM_RD_LAT; i++) addr_pipe[i] <= '0;
        end else begin
            if (!issued_last) begin
                if (&rd_addr) issued_last <= 1'b1;
                else rd_addr <= rd_addr + 1'b1;
            end
            addr_pipe[0] <= rd_addr;
            valid_pipe[0] <= !issued_last;
            for (int i=1; i<BRAM_RD_LAT; i++) begin
                addr_pipe[i] <= addr_pipe[i-1];
                valid_pipe[i] <= valid_pipe[i-1];
            end
            wr_addr <= addr_pipe[BRAM_RD_LAT-1];
            wr_data <= snapshot ? msg[53:0] : sum[53:0];
            wr_en <= valid_pipe[BRAM_RD_LAT-1];
            // Completion follows the last committed SRAM write.
            if (wr_en && (&wr_addr)) done <= 1'b1;
        end
    end
endmodule
