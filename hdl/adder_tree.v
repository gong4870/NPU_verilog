`default_nettype none

module adder_tree #(
    parameter  
        COLUMN_WIDTH = 9,                       
        DATA_WIDTH   = 16,                  
        MAC_WIDTH    = DATA_WIDTH*2,              
        OUT_WIDTH    = MAC_WIDTH + 4           
)(
    input  wire                                  clk,
    input  wire                                  reset,
    input  wire [COLUMN_WIDTH*MAC_WIDTH-1:0]     data_in,  
    output reg  [OUT_WIDTH-1:0]                  sum_out          
);

    // --------------------------
    // \B7\B9\BA\A7 1: 2\B0\B3\BE\BF \B4\F5\C7ϱ\E2
    // --------------------------
    wire signed [33:0] level1 [0:3];  
    assign level1[0] = $signed(data_in[31:0])   + $signed(data_in[63:32]);
    assign level1[1] = $signed(data_in[95:64])  + $signed(data_in[127:96]);
    assign level1[2] = $signed(data_in[159:128])+ $signed(data_in[191:160]);
    assign level1[3] = $signed(data_in[223:192])+ $signed(data_in[255:224]);
    wire signed [31:0] leftover = $signed(data_in[287:256]); 

    wire signed [34:0] level2 [0:1];
    assign level2[0] = level1[0] + level1[1];
    assign level2[1] = level1[2] + level1[3];

    always @(posedge clk or negedge reset) begin
        if(!reset)
            sum_out <= 0;
        else
            sum_out <= level2[0] + level2[1] + leftover;
    end

endmodule
